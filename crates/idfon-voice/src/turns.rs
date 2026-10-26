//! The turn rules: what one conversation's audio and the turn-taker's per-frame
//! outputs mean for the turn. Ported 1:1 from tyger-s2s
//! `app/plugins/ears/tyger/{rules,session,constants}.py` — the tier-neutral decision
//! core behind the voice loop (daemon, apps via the `idfon_voice_turn_*` C ABI in
//! iroh-c-ffi's voice.rs, tests).
//!
//! Parity: `scripts/tyger-rules-fixtures.py` runs the Python rules over scripted
//! frame streams and writes `tests/data/turns-fixtures.json`; `tests/turns_fixtures.rs`
//! asserts this port produces byte-identical events. Regenerate fixtures after any
//! semantic change on either side.
//!
//! Contract (same as rules.py): `on_frame` returns `(events, final, reset)`. `final`
//! is `(ENDPOINT event, the turn's audio)` when a turn ended (the caller fills in the
//! transcript); `reset` says the heads' context must start over. Audio is 16 kHz f32.

use serde::{Deserialize, Serialize};

// ---- nemotron audio grid (constants.py) ----
pub const SR: usize = 16000;
pub const FRAME_S: f64 = 0.08; // one encoder frame (12.5 Hz) = one decision
pub const HOP_FRAMES: usize = 4; // frames per hop (320 ms)
pub const HOP_N: usize = (HOP_FRAMES as f64 * FRAME_S * SR as f64).round() as usize; // 5120
pub const WINDOW_S: f64 = 8.0;

// ---- states (the state head's classes) ----
pub const LISTEN: i32 = 0;
pub const HOLD: i32 = 1;
pub const SPEAK: i32 = 2;
pub const BACKCHANNEL: i32 = 3;
pub const STATE_NAMES: [&str; 4] = ["LISTEN", "HOLD", "SPEAK", "BACKCHANNEL"];

// ---- turn rules ----
pub const VAD_DB: f64 = -50.0;
pub const MIN_SPEECH_MS: f64 = 350.0;
pub const WARMUP_FRAMES: i32 = 6;
pub const BARGE_PRE_S: f64 = 2.0;
pub const ONSET_GAP_FRAMES: i32 = 8;
pub const ONSET_MAX_S: f64 = 4.0;

/// Per-80 ms-frame energy in dB (rules.frame_energy). `wav` is 16 kHz f32.
pub fn frame_energy(wav: &[f32]) -> Vec<f32> {
    let hop = (FRAME_S * SR as f64).round() as usize;
    let n = wav.len() / hop;
    (0..n)
        .map(|i| {
            let seg = &wav[i * hop..(i + 1) * hop];
            let mean: f32 = seg.iter().map(|x| x * x).sum::<f32>() / seg.len() as f32;
            (20.0 * ((mean + 1e-12).sqrt() + 1e-9).log10()) as f32
        })
        .collect()
}

/// The 4-way state head's decision (rules.state_decision). Live it only names the
/// FRAME state: the endpoint, yield and backchannel heads make the real decisions.
pub fn state_decision(state_logits: [f32; 4], hazard: f64, prev: i32, theta: f64) -> i32 {
    let m = state_logits.iter().cloned().fold(f32::NEG_INFINITY, f32::max);
    let mut e = [0f32; 4];
    let mut s = 0f32;
    for (i, l) in state_logits.iter().enumerate() {
        e[i] = (l - m).exp();
        s += e[i];
    }
    let p = [e[0] / s, e[1] / s, e[2] / s, e[3] / s];
    let pmax = p.iter().cloned().fold(f32::NEG_INFINITY, f32::max);
    if (prev == LISTEN || prev == HOLD) && p[BACKCHANNEL as usize] >= 0.5 && p[BACKCHANNEL as usize] == pmax {
        return BACKCHANNEL;
    }
    if prev == LISTEN || prev == HOLD {
        if hazard >= theta {
            return SPEAK;
        }
        return if p[HOLD as usize] > p[LISTEN as usize] { HOLD } else { LISTEN };
    }
    if prev == SPEAK {
        return if p[SPEAK as usize] >= p[LISTEN as usize].max(p[HOLD as usize]) { SPEAK } else { LISTEN };
    }
    if prev == BACKCHANNEL {
        return if p[BACKCHANNEL as usize] == pmax { BACKCHANNEL } else { LISTEN };
    }
    LISTEN
}

/// Trait thresholds (EarsSession's constructor defaults).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(default)] // missing fields take the EarsSession defaults, like Python kwargs
pub struct Thresholds {
    pub ep_thr: f64,
    pub ep_deb: i32,
    pub barge_thr: f64,
    pub barge_deb: i32,
    pub bc_thr: f64,
    pub bc_deb: i32,
    pub theta: f64,
    pub bc_refractory: i32,
}

impl Default for Thresholds {
    fn default() -> Self {
        Thresholds {
            ep_thr: 0.9146,
            ep_deb: 2,
            barge_thr: 0.5,
            barge_deb: 2,
            bc_thr: 0.5,
            bc_deb: 2,
            theta: 0.2,
            bc_refractory: 15,
        }
    }
}

impl Thresholds {
    /// The live-tuned set (tyger-s2s `config/default.yaml`, adopted
    /// 2026-10-25): their demonstrations run these, not the bundle defaults
    /// above. `Default` stays the bundle set so the parity fixtures remain
    /// byte-comparable with their rules tests; the runtime constructs with
    /// `tuned()` (documenting any change here, per the comparison doc).
    pub fn tuned() -> Self {
        Thresholds {
            ep_thr: 0.915,
            barge_thr: 0.4,
            bc_thr: 0.4,
            ..Self::default()
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Event {
    pub kind: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub state: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub yield_prob: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub hazard: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub bc_prob: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub p_end: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub onset_s: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub partial: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub turn_s: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub segments: Option<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub by: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub transcript: Option<Option<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub seg_texts: Option<Vec<Option<String>>>,
}

impl Event {
    fn kind(kind: &str) -> Event {
        Event {
            kind: kind.to_string(),
            state: None,
            yield_prob: None,
            hazard: None,
            bc_prob: None,
            p_end: None,
            onset_s: None,
            partial: None,
            turn_s: None,
            segments: None,
            by: None,
            text: None,
            transcript: None,
            seg_texts: None,
        }
    }
}

/// Python's `round(x, n)` (ties-to-even, same as `format!`'s IEEE rounding).
fn r(x: f64, n: usize) -> f64 {
    format!("{:.*}", n, x).parse().unwrap()
}

#[derive(Clone, Debug)]
pub struct TurnSession {
    pub th: Thresholds,
    // audio bookkeeping (the caller encodes win_u/win_a each hop)
    pub win_u: Vec<f32>,
    pub win_a: Vec<f32>,
    pub turn_u: Vec<f32>,
    pub pre_u: Vec<f32>,
    pub seed_u: Option<Vec<f32>>,
    pub seg_s: f64,
    pub segs: Vec<Option<String>>,
    talk_frames: i32,
    quiet_frames: i32,
    pub prev_state: i32,
    yield_run: i32,
    pub voiced_ms: f64,
    pub in_turn: bool,
    warm: i32,
    mode: String,
    bc_run: i32,
    bc_cooldown: i32,
    ep_run: i32,
    pub partial_asr: String,
    pub words: String,
    words_sent: String,
    pub turn_gen: u64,
    pending_reset: bool,
}

impl TurnSession {
    pub fn new(th: Thresholds) -> TurnSession {
        let mut s = TurnSession {
            th,
            win_u: Vec::new(),
            win_a: Vec::new(),
            turn_u: Vec::new(),
            pre_u: Vec::new(),
            seed_u: None,
            seg_s: 0.0,
            segs: Vec::new(),
            talk_frames: 0,
            quiet_frames: 0,
            prev_state: LISTEN,
            yield_run: 0,
            voiced_ms: 0.0,
            in_turn: false,
            warm: 0,
            mode: "listen".into(),
            bc_run: 0,
            bc_cooldown: 0,
            ep_run: 0,
            partial_asr: String::new(),
            words: String::new(),
            words_sent: String::new(),
            turn_gen: 0,
            pending_reset: true,
        };
        s.clear();
        s
    }

    fn clear(&mut self) {
        self.win_u.clear();
        self.win_a.clear();
        self.turn_u.clear();
        self.seg_s = 0.0;
        self.segs.clear();
        self.pre_u.clear();
        self.seed_u = None;
        self.talk_frames = 0;
        self.quiet_frames = 0;
        self.prev_state = LISTEN;
        self.yield_run = 0;
        self.voiced_ms = 0.0;
        self.in_turn = false;
        self.warm = 0;
        self.mode = "listen".into();
        self.bc_run = 0;
        self.bc_cooldown = 0;
        self.ep_run = 0;
        self.partial_asr = String::new();
        self.words.clear();
        self.words_sent.clear();
    }

    pub fn turn_len_s(&self) -> f64 {
        self.seg_s + self.turn_u.len() as f64 / SR as f64
    }

    /// Applied by the caller's thread before the next hop.
    pub fn reset(&mut self) {
        self.pending_reset = true;
    }

    /// Before a hop's frames: pending reset, window sliding, turn audio (rules.begin_hop).
    /// True if the heads' context must start over.
    pub fn begin_hop(&mut self, user_hop: &[f32], agent_hop: &[f32], mode: &str) -> bool {
        let reset = self.pending_reset;
        if reset {
            let seed = self.seed_u.take();
            self.clear();
            self.turn_gen += 1;
            self.pending_reset = false;
            if let Some(seed) = seed {
                // a barge-in: the new turn starts with the user's speech so far (I-02)
                self.voiced_ms = frame_energy(&seed).iter().filter(|e| **e > VAD_DB as f32).count() as f64
                    * FRAME_S
                    * 1e3;
                self.in_turn = self.voiced_ms > 0.0;
                self.turn_u = seed;
            }
        }
        self.seed_u = None;
        slide(&mut self.win_u, user_hop, (WINDOW_S * SR as f64) as usize);
        slide(&mut self.win_a, agent_hop, (WINDOW_S * SR as f64) as usize);
        if mode == "listen" {
            self.turn_u.extend_from_slice(user_hop);
        } else {
            slide(&mut self.pre_u, user_hop, (BARGE_PRE_S * SR as f64) as usize);
        }
        reset
    }

    /// A change between listening and speaking: fresh decision runs (rules.switch_mode).
    pub fn switch_mode(&mut self, mode: &str) -> bool {
        if mode == self.mode {
            return false;
        }
        self.warm = 0;
        self.yield_run = 0;
        self.bc_run = 0;
        self.bc_cooldown = 0;
        self.ep_run = 0;
        self.talk_frames = 0;
        self.quiet_frames = 0;
        self.prev_state = if mode == "speaking" { SPEAK } else { LISTEN };
        self.mode = mode.to_string();
        true
    }

    /// The user's words so far (set on the ASR thread): a PARTIAL event when changed.
    pub fn words_event(&mut self, mode: &str) -> Option<Event> {
        if mode != "listen" || self.words == self.words_sent {
            return None;
        }
        self.words_sent = self.words.clone();
        let mut ev = Event::kind("PARTIAL");
        ev.text = Some(self.words.clone());
        Some(ev)
    }

    fn track_talk(&mut self, voiced: bool) {
        if self.talk_frames != 0 {
            self.talk_frames += 1;
            self.quiet_frames = if voiced { 0 } else { self.quiet_frames + 1 };
            if self.quiet_frames > ONSET_GAP_FRAMES {
                self.talk_frames = 0;
                self.quiet_frames = 0;
            }
        } else if voiced {
            self.talk_frames = 1;
            self.quiet_frames = 0;
        }
    }

    /// One frame's decision (rules.on_frame). `outputs` = the 8-vector
    /// (state logits x4, hazard, yield, bc, p_end); `left` = the hop's frames after
    /// this one (a barge's onset counts to the hop's end).
    pub fn on_frame(
        &mut self,
        mode: &str,
        outputs: [f32; 8],
        act_db: f64,
        left: usize,
    ) -> (Vec<Event>, Option<(Event, Vec<f32>)>, bool) {
        let mut events = Vec::new();
        let slog = [outputs[0], outputs[1], outputs[2], outputs[3]];
        let (haz, yp, bcp, pep) = (outputs[4] as f64, outputs[5] as f64, outputs[6] as f64, outputs[7] as f64);
        let st = state_decision(slog, haz, self.prev_state, self.th.theta);
        let voiced = act_db > VAD_DB;

        if mode == "speaking" {
            // BARGE path (yield head)
            self.warm += 1;
            self.track_talk(voiced);
            if self.warm > WARMUP_FRAMES {
                self.yield_run = if yp >= self.th.barge_thr { self.yield_run + 1 } else { 0 };
                if self.yield_run >= self.th.barge_deb {
                    let onset_s = if self.talk_frames != 0 {
                        ((self.talk_frames as f64 + left as f64) * FRAME_S).min(ONSET_MAX_S)
                    } else {
                        0.0
                    };
                    let mut ev = Event::kind("BARGE");
                    ev.yield_prob = Some(r(yp, 3));
                    ev.onset_s = Some(r(onset_s, 2));
                    events.push(ev);
                    self.yield_run = 0;
                    self.seed_u = Some(self.pre_u.clone());
                }
            }
            let mut ev = Event::kind("FRAME");
            ev.state = Some("SPEAK".into());
            ev.yield_prob = Some(r(yp, 3));
            ev.hazard = Some(r(haz, 3));
            ev.p_end = Some(r(pep, 3));
            events.push(ev);
            self.prev_state = SPEAK;
            return (events, None, false);
        }

        // LISTEN mode
        self.warm += 1;
        if voiced {
            self.voiced_ms += FRAME_S * 1e3;
            self.in_turn = true;
        }
        if self.bc_cooldown > 0 {
            self.bc_cooldown -= 1;
            self.bc_run = 0;
        } else if self.in_turn && self.voiced_ms >= MIN_SPEECH_MS && self.warm > WARMUP_FRAMES {
            self.bc_run = if bcp >= self.th.bc_thr { self.bc_run + 1 } else { 0 };
            if self.bc_run >= self.th.bc_deb {
                let mut ev = Event::kind("BACKCHANNEL");
                ev.partial = Some(self.partial_asr.clone());
                ev.bc_prob = Some(r(bcp, 3));
                ev.turn_s = Some(r(self.turn_len_s(), 2));
                events.push(ev);
                self.bc_run = 0;
                self.bc_cooldown = self.th.bc_refractory;
            }
        }
        if self.warm > WARMUP_FRAMES {
            self.ep_run = if pep >= self.th.ep_thr { self.ep_run + 1 } else { 0 };
        } else {
            self.ep_run = 0;
        }
        let spoke = self.in_turn && self.voiced_ms >= MIN_SPEECH_MS;
        if spoke && self.ep_run >= self.th.ep_deb {
            let mut ev = Event::kind("ENDPOINT");
            ev.transcript = Some(None);
            ev.turn_s = Some(self.turn_len_s());
            ev.segments = Some(self.segs.len());
            ev.seg_texts = Some(self.segs.clone());
            ev.by = Some("head".into());
            ev.p_end = Some(r(pep, 3));
            let final_audio = std::mem::take(&mut self.turn_u);
            events.push(ev.clone());
            self.voiced_ms = 0.0;
            self.in_turn = false;
            self.seg_s = 0.0;
            self.segs.clear();
            self.prev_state = LISTEN;
            self.warm = 0;
            self.bc_run = 0;
            self.bc_cooldown = 0;
            self.ep_run = 0;
            self.partial_asr.clear();
            self.turn_gen += 1;
            self.words.clear();
            self.words_sent.clear();
            let mut fr = Event::kind("FRAME");
            fr.state = Some("idle".into());
            fr.yield_prob = Some(r(yp, 3));
            fr.hazard = Some(r(haz, 3));
            fr.bc_prob = Some(r(bcp, 3));
            fr.p_end = Some(r(pep, 3));
            events.push(fr);
            return (events, Some((ev, final_audio)), true);
        }
        let disp = if self.in_turn {
            STATE_NAMES[st as usize].to_string()
        } else if !voiced {
            "idle".to_string()
        } else {
            "LISTEN".to_string()
        };
        let mut ev = Event::kind("FRAME");
        ev.state = Some(disp);
        ev.yield_prob = Some(r(yp, 3));
        ev.hazard = Some(r(haz, 3));
        ev.bc_prob = Some(r(bcp, 3));
        ev.p_end = Some(r(pep, 3));
        events.push(ev);
        self.prev_state = LISTEN; // free-run: the ep head's operating regime
        (events, None, false)
    }
}

fn slide(win: &mut Vec<f32>, hop: &[f32], cap: usize) {
    win.extend_from_slice(hop);
    if win.len() > cap {
        let drop = win.len() - cap;
        win.drain(0..drop);
    }
}
