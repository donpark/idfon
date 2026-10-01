//! Durable holder-side voice-record buffer, keyed by the 1:1 peer address.
//!
//! P0 of the voice side-channel (`docs/voice-side-channel.md`): a live call's
//! transcripts and hangup summary land here instead of triggering Eve turns.
//! The Eve extension fetches and drains them at a turn boundary as a user-role
//! dynamic instruction, so the orchestrator sees the call context without any
//! caller/agent utterance becoming a turn.
//!
//! Records are structurally encoded (a fixed `speaker` enum, escaped JSON when
//! rendered into instructions) so a transcript cannot forge a speaker label.
//! The store keeps every record (audit copy); `drain` moves a cursor, so Eve
//! history is the model's view of the append-only log.

use std::{
    collections::HashMap,
    path::PathBuf,
    sync::{Mutex, OnceLock},
    time::{SystemTime, UNIX_EPOCH},
};

use serde::{Deserialize, Serialize};

/// Cap per peer; trims the oldest records once exceeded (the drained cursor is
/// advanced past them). ponytail: bounded file, raise if long audit retention
/// is ever required.
const MAX_RECORDS_PER_PEER: usize = 2000;

/// One durable record: a final transcript line or a hangup summary.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct VoiceRecord {
    pub seq: u64,
    /// "transcript" | "call_summary".
    pub kind: String,
    /// "caller" | "agent" for transcripts.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub speaker: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub call_id: Option<String>,
    /// Duration in seconds, set on a call summary.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub duration_seconds: Option<u64>,
    /// Transcript lines in the summarized call.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub turn_count: Option<u64>,
    pub at_ms: u64,
}

impl VoiceRecord {
    pub fn transcript(call_id: &str, speaker: &str, text: &str) -> Self {
        Self {
            seq: 0,
            kind: "transcript".into(),
            speaker: Some(speaker.into()),
            text: Some(text.into()),
            call_id: Some(call_id.into()),
            duration_seconds: None,
            turn_count: None,
            at_ms: now_ms(),
        }
    }

    pub fn call_summary(call_id: &str, duration_seconds: u64, turn_count: u64) -> Self {
        Self {
            seq: 0,
            kind: "call_summary".into(),
            speaker: None,
            text: None,
            call_id: Some(call_id.into()),
            duration_seconds: Some(duration_seconds),
            turn_count: Some(turn_count),
            at_ms: now_ms(),
        }
    }
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

#[derive(Default, Serialize, Deserialize)]
struct PeerLog {
    #[serde(default)]
    next_seq: u64,
    /// First sequence number still returned by a drain.
    #[serde(default)]
    drained_upto: u64,
    /// Last turn id that drained this peer; replays return nothing.
    #[serde(default)]
    last_drained_turn: String,
    #[serde(default)]
    records: Vec<VoiceRecord>,
}

/// File-backed record buffer. One JSON file per peer.
pub struct RecordStore {
    root: PathBuf,
    peers: Mutex<HashMap<String, PeerLog>>,
}

impl RecordStore {
    pub fn open(root: PathBuf) -> Self {
        Self {
            root,
            peers: Mutex::new(HashMap::new()),
        }
    }

    fn file(&self, peer_id: &str) -> PathBuf {
        // Endpoint ids are ASCII and filesystem-safe; encode defensively.
        let safe: String = peer_id
            .chars()
            .map(|c| {
                if c.is_ascii_alphanumeric() || c == '-' || c == '_' {
                    c
                } else {
                    '_'
                }
            })
            .collect();
        self.root.join(format!("{safe}.json"))
    }

    fn with_peer<T>(&self, peer_id: &str, f: impl FnOnce(&mut PeerLog) -> T) -> T {
        let mut peers = self.peers.lock().expect("record store poisoned");
        let log = peers.entry(peer_id.to_string()).or_insert_with(|| {
            std::fs::read_to_string(self.file(peer_id))
                .ok()
                .and_then(|raw| serde_json::from_str(&raw).ok())
                .unwrap_or_default()
        });
        let result = f(log);
        if let Err(error) = self.persist(peer_id, log) {
            eprintln!("[eve-idfon] voice record persist failed peer={peer_id}: {error}");
        }
        result
    }

    fn persist(&self, peer_id: &str, log: &PeerLog) -> std::io::Result<()> {
        std::fs::create_dir_all(&self.root)?;
        let bytes = serde_json::to_vec(log)?;
        std::fs::write(self.file(peer_id), bytes)
    }

    /// Append a record, assigning its sequence number.
    pub fn append(&self, peer_id: &str, mut record: VoiceRecord) {
        self.with_peer(peer_id, |log| {
            record.seq = log.next_seq;
            log.next_seq += 1;
            log.records.push(record);
            if log.records.len() > MAX_RECORDS_PER_PEER {
                let drop = log.records.len() - MAX_RECORDS_PER_PEER;
                log.records.drain(..drop);
                log.drained_upto = log
                    .drained_upto
                    .max(log.records.first().map(|r| r.seq).unwrap_or(0));
            }
        });
    }

    /// Return records appended since the last drain and advance the cursor.
    /// Idempotent per `turn_id`: replaying the same turn yields nothing.
    pub fn drain(&self, peer_id: &str, turn_id: &str) -> Vec<VoiceRecord> {
        self.with_peer(peer_id, |log| {
            if !turn_id.is_empty() && log.last_drained_turn == turn_id {
                return Vec::new();
            }
            let drained: Vec<VoiceRecord> = log
                .records
                .iter()
                .filter(|record| record.seq >= log.drained_upto)
                .cloned()
                .collect();
            log.drained_upto = log.next_seq;
            log.last_drained_turn = turn_id.to_string();
            drained
        })
    }
}

/// The process-wide store used by the holder runtime.
pub fn store() -> &'static RecordStore {
    static STORE: OnceLock<RecordStore> = OnceLock::new();
    STORE.get_or_init(|| RecordStore::open(default_root()))
}

fn default_root() -> PathBuf {
    if let Some(root) = std::env::var_os("IDFON_VOICE_RECORDS_DIR") {
        return PathBuf::from(root);
    }
    if let Some(home) = std::env::var_os("EVE_VOICE_HOME") {
        return PathBuf::from(home).join("voice-records");
    }
    if let Some(home) = std::env::var_os("HOME") {
        return PathBuf::from(home).join(".idfon").join("eve-voice-records");
    }
    std::env::temp_dir().join("idfon-eve-voice-records")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_store() -> (RecordStore, PathBuf) {
        static COUNTER: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        let dir = std::env::temp_dir().join(format!(
            "idfon-records-test-{}-{}-{}",
            std::process::id(),
            now_ms(),
            COUNTER.fetch_add(1, std::sync::atomic::Ordering::Relaxed),
        ));
        (RecordStore::open(dir.clone()), dir)
    }

    #[test]
    fn drain_is_idempotent_per_turn_and_persists() {
        let (store, dir) = temp_store();
        store.append("peer-a", VoiceRecord::transcript("call-1", "caller", "hi"));
        store.append(
            "peer-a",
            VoiceRecord::transcript("call-1", "agent", "hello"),
        );
        store.append("peer-a", VoiceRecord::call_summary("call-1", 12, 2));

        let first = store.drain("peer-a", "turn-1");
        assert_eq!(first.len(), 3);
        assert_eq!(first[0].speaker.as_deref(), Some("caller"));
        assert_eq!(first[2].kind, "call_summary");
        // Replaying the same turn must not re-emit records.
        assert!(store.drain("peer-a", "turn-1").is_empty());

        // Records survive a restart; a new turn drains what was appended after.
        store.append(
            "peer-a",
            VoiceRecord::transcript("call-2", "caller", "again"),
        );
        drop(store);
        let reopened = RecordStore::open(dir.clone());
        let second = reopened.drain("peer-a", "turn-2");
        assert_eq!(second.len(), 1);
        assert_eq!(second[0].text.as_deref(), Some("again"));
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn empty_turn_id_never_dedupes() {
        let (store, dir) = temp_store();
        store.append("peer-b", VoiceRecord::transcript("call-1", "caller", "one"));
        assert_eq!(store.drain("peer-b", "").len(), 1);
        store.append("peer-b", VoiceRecord::transcript("call-1", "agent", "two"));
        assert_eq!(store.drain("peer-b", "").len(), 1);
        let _ = std::fs::remove_dir_all(dir);
    }
}
