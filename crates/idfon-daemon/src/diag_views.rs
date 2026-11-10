//! Materialize `IDFON-DIAG/1` envelopes into queryable views (the MCP
//! diagnostics slice — `docs/mcp-control.md`, `docs/diag.md`).
//!
//! The shells already ship their diagnostics to the monitor over
//! `message.send`; every such envelope passes through this daemon, so the
//! events are recorded here too — cheaply, best-effort, never on the call
//! path. Two views under `<data-dir>/diag/`:
//!
//! * `<device>.jsonl` — one JSON line per event (the monitor's shape:
//!   `{ts_ms, kind, detail, device, build}`), the `diag.tail` feed.
//! * `wake-<call>.json` — the events of one call attempt grouped and sorted
//!   (`{call, device, build, stages:[…]}`), the `wake.trace` feed: the
//!   registration → ring → push → report → answer → media timeline as a
//!   queryable artifact instead of log archaeology.
//!
//! A deployment that serves `<data-dir>` over the MCP resource server exposes
//! both to approved agents; `idfon-mcp`'s `diag.tail`/`wake.trace` tools read
//! the same files.

use std::io::Write as _;
use std::path::Path;

use idfon_protocol::diag::{DiagReport, DIAG_PREFIX};

/// Record the events of one `IDFON-DIAG/1` envelope. Best-effort: any error is
/// logged and swallowed — diagnostics must never fail a send.
pub fn record(data_dir: &Path, text: &str) {
    let Some(body) = text.strip_prefix(DIAG_PREFIX) else {
        return;
    };
    let report: DiagReport = match serde_json::from_str(body.trim()) {
        Ok(report) => report,
        Err(error) => {
            tracing::debug!(target: "idfon.daemon", error = %error, "diag view: unparseable report");
            return;
        }
    };
    let dir = data_dir.join("diag");
    if let Err(error) = std::fs::create_dir_all(&dir) {
        tracing::debug!(target: "idfon.daemon", error = %error, "diag view: mkdir");
        return;
    }
    let device = sanitize(&report.device);
    // The flat feed: one line per event, the monitor's shape.
    if let Ok(mut file) = std::fs::OpenOptions::new().create(true).append(true).open(
        dir.join(format!("{device}.jsonl")),
    ) {
        for event in &report.events {
            let line = serde_json::json!({
                "ts_ms": event.ts_ms,
                "kind": event.kind,
                "detail": event.detail,
                "device": report.device,
                "build": report.build,
            });
            let _ = writeln!(file, "{line}");
        }
        let _ = file.flush();
    }
    // The per-call wake traces: events that name a call in `detail.call`.
    let mut by_call: std::collections::BTreeMap<String, Vec<serde_json::Value>> =
        std::collections::BTreeMap::new();
    for event in &report.events {
        if let Some(call) = event.detail.get("call").and_then(|call| call.as_str()) {
            by_call.entry(call.to_owned()).or_default().push(serde_json::json!({
                "ts_ms": event.ts_ms,
                "kind": event.kind,
                "detail": event.detail,
            }));
        }
    }
    for (call, mut stages) in by_call {
        let path = dir.join(format!("wake-{call}.json"));
        let mut all = read_stages(&path);
        all.append(&mut stages);
        // Older batches may arrive late; keep the timeline sorted and unique.
        all.sort_by_key(|stage| stage["ts_ms"].as_u64().unwrap_or(0));
        all.dedup_by(|a, b| a["ts_ms"] == b["ts_ms"] && a["kind"] == b["kind"] && a["detail"] == b["detail"]);
        let view = serde_json::json!({
            "call": call,
            "device": report.device,
            "build": report.build,
            "stages": all,
        });
        if let Err(error) = std::fs::write(&path, view.to_string()) {
            tracing::debug!(target: "idfon.daemon", error = %error, "diag view: wake trace write");
        }
    }
}

fn read_stages(path: &Path) -> Vec<serde_json::Value> {
    std::fs::read(path)
        .ok()
        .and_then(|bytes| serde_json::from_slice::<serde_json::Value>(&bytes).ok())
        .and_then(|view| view.get("stages").and_then(|s| s.as_array()).cloned())
        .unwrap_or_default()
}

/// File-name safety: the device label is user-visible text; only keep the
/// unreserved characters.
fn sanitize(device: &str) -> String {
    let cleaned: String = device
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '-' || c == '_' || c == '.' {
                c
            } else {
                '_'
            }
        })
        .collect();
    if cleaned.is_empty() { "device".to_owned() } else { cleaned }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_dir(name: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("idfon-diag-views-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        dir
    }

    #[test]
    fn records_the_flat_feed_and_the_wake_trace() {
        let dir = temp_dir("record");
        let batch = concat!(
            "IDFON-DIAG/1\n",
            r#"{"device":"iphone 16","build":"b23","events":[
                {"ts_ms":2,"kind":"wake","detail":{"call":"C1","outcome":"system_ring"}},
                {"ts_ms":1,"kind":"push.received","detail":{"call":"C1","must_report":true}},
                {"ts_ms":3,"kind":"push.register","detail":{"ok":true}}
            ]}"#
        );
        record(&dir, batch);
        // A later batch merges into the same trace, sorted.
        record(
            &dir,
            "IDFON-DIAG/1\n{\"device\":\"iphone 16\",\"build\":\"b23\",\"events\":[{\"ts_ms\":0,\"kind\":\"push.token_update\",\"detail\":{}}]}",
        );

        let feed = std::fs::read_to_string(dir.join("diag/iphone_16.jsonl")).expect("feed");
        assert_eq!(feed.lines().count(), 4, "every event lands in the flat feed");
        assert!(feed.contains("\"kind\":\"wake\""), "the feed keeps kinds");

        let trace: serde_json::Value =
            serde_json::from_slice(&std::fs::read(dir.join("diag/wake-C1.json")).expect("trace"))
                .expect("trace json");
        assert_eq!(trace["call"], "C1");
        let stages = trace["stages"].as_array().expect("stages");
        assert_eq!(stages.len(), 2, "only the call's events group into the trace");
        assert_eq!(stages[0]["ts_ms"], 1, "stages sort by time (late batches included)");
        assert_eq!(stages[1]["kind"], "wake");
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn ignores_everything_that_is_not_a_diag_envelope() {
        let dir = temp_dir("ignore");
        record(&dir, "IDFON-LIVE/1\naction=start");
        record(&dir, "IDFON-DIAG/1\nnot json");
        record(&dir, "hello");
        assert!(!dir.join("diag").exists() || std::fs::read_dir(dir.join("diag")).map(|d| d.count() == 0).unwrap_or(true));
        std::fs::remove_dir_all(&dir).ok();
    }
}