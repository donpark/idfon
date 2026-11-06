//! Barge audibility gate and refractory (`docs/voice-decision-model.md`, the
//! 2026-11-06 barge event spec): the two conditions are off by default so the
//! parity fixtures keep asserting tyger-s2s's behaviour, and traits enable them
//! once the TS port carries them too.

use idfon_voice::turns::{Thresholds, TurnSession, HOP_FRAMES, HOP_N};

/// 8-vector with a loud yield head and a neutral state head.
fn frame_out(yield_prob: f32) -> [f32; 8] {
    [0.0, 0.0, 2.0, 0.0, 0.0, yield_prob, 0.0, 0.0]
}

fn hop(user_rms: f32, agent_rms: f32) -> (Vec<f32>, Vec<f32>) {
    (vec![user_rms; HOP_N], vec![agent_rms; HOP_N])
}

/// Drive `hops` hops of `frames_per_hop` frames in `mode`, returning every BARGE frame index.
fn drive(sess: &mut TurnSession, mode: &str, hops: usize, frames_per_hop: usize,
         user_rms: f32, agent_rms: f32, yield_prob: f32) -> Vec<usize> {
    let mut fired = Vec::new();
    let mut n = 0;
    for _ in 0..hops {
        let (u, a) = hop(user_rms, agent_rms);
        sess.begin_hop(&u, &a, mode);
        for i in 0..frames_per_hop {
            let left = (frames_per_hop - 1 - i) as usize;
            let (events, _final, _reset) = sess.on_frame(mode, frame_out(yield_prob), -20.0, left);
            if events.iter().any(|e| e.kind == "BARGE") {
                fired.push(n);
            }
            n += 1;
        }
    }
    fired
}

#[test]
fn default_thresholds_keep_the_pre_gate_behaviour() {
    // gate off, refractory off: the yield run alone fires, agent channel silent or not
    let mut silent = TurnSession::new(Thresholds::default());
    silent.switch_mode("speaking");
    assert!(!drive(&mut silent, "speaking", 3, HOP_FRAMES, 0.1, 0.0, 0.9).is_empty());
}

#[test]
fn audibility_gate_blocks_the_release_tail() {
    let th = Thresholds { barge_gate_db: Some(-50.0), ..Thresholds::default() };
    // agent silent throughout (the 1.92 s release tail): nothing to stop, no barge
    let mut tail = TurnSession::new(th.clone());
    tail.switch_mode("speaking");
    assert!(drive(&mut tail, "speaking", 3, HOP_FRAMES, 0.1, 0.0, 0.9).is_empty(),
            "a silent agent channel must not produce a barge");
    // agent audible: the same yield run fires
    let mut live = TurnSession::new(th);
    live.switch_mode("speaking");
    assert!(!drive(&mut live, "speaking", 3, HOP_FRAMES, 0.1, 0.1, 0.9).is_empty());
}

#[test]
fn refractory_allows_one_barge_per_speaking_episode() {
    let th = Thresholds { barge_refractory: 1, ..Thresholds::default() };
    let mut sess = TurnSession::new(th);
    sess.switch_mode("speaking");
    let fired = drive(&mut sess, "speaking", 4, HOP_FRAMES, 0.1, 0.1, 0.9);
    assert_eq!(fired.len(), 1, "one decision per episode, got {fired:?}");
    // leaving and re-entering speaking is a new episode
    sess.switch_mode("listen");
    drive(&mut sess, "listen", 1, HOP_FRAMES, 0.0, 0.0, 0.0);
    sess.switch_mode("speaking");
    assert_eq!(drive(&mut sess, "speaking", 3, HOP_FRAMES, 0.1, 0.1, 0.9).len(), 1);
}

#[test]
fn gate_does_not_fire_below_the_yield_threshold() {
    let th = Thresholds { barge_gate_db: Some(-50.0), ..Thresholds::default() };
    let mut sess = TurnSession::new(th);
    sess.switch_mode("speaking");
    assert!(drive(&mut sess, "speaking", 3, HOP_FRAMES, 0.1, 0.1, 0.1).is_empty());
}
