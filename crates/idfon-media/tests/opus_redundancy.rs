//! Opus redundancy-level measurement harness (docs/media-adaptation.md §D7).
//!
//! At induced frame loss, how much does each receiver redundancy strategy
//! recover, and at what wire cost:
//!
//! - `none`  — lost frame becomes silence (today's moq-audio stack behavior)
//! - `plc`   — Opus packet-loss concealment at the hole
//! - `fec`   — encoder in-band FEC; the frame after a hole carries an LBRR
//!             copy recovered with `opus_decode(..., decode_fec = 1)`
//! - `red`   — simulated RFC 2198: each packet carries the previous frame in
//!             full (≈2× wire bytes), recovered at full quality
//!
//! `fec`/`red` fall back to PLC at a double loss (what a real receiver does),
//! so the rows compare the redundancy mechanism itself on top of PLC.
//!
//! Fixture: `scripts/opus-loss-fixture.sh` (Phonon/ptts speech, PCM16 mono
//! 24 kHz) writes `target/opus-loss-fixture.wav`; without it a deterministic
//! speech-like signal is synthesized so CI still runs. Run the measurement:
//!
//! ```sh
//! scripts/opus-loss-fixture.sh
//! cargo test -p idfon-media --test opus_redundancy -- --nocapture
//! ```

use std::path::PathBuf;

use opusic_sys::{
    OpusDecoder, OpusEncoder, OPUS_APPLICATION_AUDIO, OPUS_OK,
    OPUS_SET_BITRATE_REQUEST, OPUS_SET_INBAND_FEC_REQUEST, OPUS_SET_PACKET_LOSS_PERC_REQUEST,
    opus_decode_float, opus_decoder_create, opus_decoder_destroy, opus_encode_float,
    opus_encoder_create, opus_encoder_ctl, opus_encoder_destroy,
};

const RATE: i32 = 24_000;
/// 20 ms at 24 kHz — the call plane's frame.
const FRAME: usize = 480;
const BITRATE: i32 = 32_000;

// --- Source audio ----------------------------------------------------

fn fixture_path() -> PathBuf {
    std::env::var("IDFON_OPUS_FIXTURE")
        .map(PathBuf::from)
        .unwrap_or_else(|_| {
            PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../target/opus-loss-fixture.wav")
        })
}

/// Minimal PCM16 WAV reader (skips unknown chunks), returned mono f32.
fn read_wav_pcm16_mono(path: &std::path::Path) -> std::io::Result<(u32, Vec<f32>)> {
    let bytes = std::fs::read(path)?;
    let err = |m: &str| std::io::Error::new(std::io::ErrorKind::InvalidData, m);
    if bytes.len() < 12 || &bytes[0..4] != b"RIFF" || &bytes[8..12] != b"WAVE" {
        return Err(err("not a RIFF/WAVE file"));
    }
    let mut pos = 12usize;
    let mut spec: Option<(u16, u32, u16)> = None;
    let mut data: Option<&[u8]> = None;
    while pos + 8 <= bytes.len() {
        let id = &bytes[pos..pos + 4];
        let size = u32::from_le_bytes(bytes[pos + 4..pos + 8].try_into().unwrap()) as usize;
        let end = (pos + 8 + size).min(bytes.len());
        let body = &bytes[pos + 8..end];
        match id {
            b"fmt " if body.len() >= 16 => {
                let channels = u16::from_le_bytes(body[2..4].try_into().unwrap());
                let rate = u32::from_le_bytes(body[4..8].try_into().unwrap());
                let bits = u16::from_le_bytes(body[14..16].try_into().unwrap());
                spec = Some((channels, rate, bits));
            }
            b"data" => data = Some(body),
            _ => {}
        }
        pos += 8 + size + (size & 1); // chunks are word-aligned
    }
    let (channels, rate, bits) = spec.ok_or_else(|| err("no fmt chunk"))?;
    let data = data.ok_or_else(|| err("no data chunk"))?;
    if bits != 16 {
        return Err(err("only PCM16 supported"));
    }
    let ch = channels.max(1) as usize;
    let mut samples = Vec::with_capacity(data.len() / 2 / ch);
    for frame in data.chunks_exact(2 * ch) {
        let mut acc = 0f32;
        for c in 0..ch {
            let v = i16::from_le_bytes(frame[c * 2..c * 2 + 2].try_into().unwrap());
            acc += v as f32 / 32768.0;
        }
        samples.push(acc / ch as f32);
    }
    Ok((rate, samples))
}

struct XorShift(u64);

impl XorShift {
    fn next_f64(&mut self) -> f64 {
        let mut x = self.0;
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        self.0 = x;
        (x >> 11) as f64 / (1u64 << 53) as f64
    }
}

/// Deterministic speech-like signal: voiced harmonic stacks with a drifting
/// f0, unvoiced noise spans, and pauses. Only used when the Phonon fixture
/// is absent (CI); comparative ordering is the harness's output either way.
fn synthetic_speech(frames: usize) -> Vec<f32> {
    let mut rng = XorShift(0x5EED);
    let mut pcm = Vec::with_capacity(frames * FRAME);
    while pcm.len() < frames * FRAME {
        // Voiced span: 0.6–1.4 s.
        let voiced = ((0.6 + rng.next_f64() * 0.8) * RATE as f64) as usize;
        let f0 = 105.0f32 + (rng.next_f64() as f32) * 60.0;
        for n in 0..voiced {
            let t = n as f32 / RATE as f32;
            let f = f0 + 12.0 * (t * 1.7).sin();
            let env = ((n as f32 / voiced as f32) * std::f32::consts::PI).sin();
            let mut s = 0.0;
            for k in 1..=10 {
                s += (std::f32::consts::TAU * k as f32 * f * t).sin() / k as f32;
            }
            pcm.push(s * env * 0.28);
        }
        // Unvoiced span: 0.15–0.4 s of band-ish noise.
        let unvoiced = ((0.15 + rng.next_f64() * 0.25) * RATE as f64) as usize;
        let mut last = 0.0f32;
        for _ in 0..unvoiced {
            let noise: f32 = rng.next_f64() as f32 - 0.5;
            let hp = noise - last; // crude high-pass: fricative-ish
            last = noise;
            pcm.push(hp * 0.2);
        }
        // Pause: 0.2–0.5 s.
        let pause = ((0.2 + rng.next_f64() * 0.3) * RATE as f64) as usize;
        pcm.extend(std::iter::repeat(0.0).take(pause));
    }
    pcm.truncate(frames * FRAME);
    pcm
}

// --- Opus encode/decode ---------------------------------------------

struct Enc(*mut OpusEncoder);

impl Enc {
    fn new(fec: bool) -> Self {
        unsafe {
            let mut err = 0;
            let enc = opus_encoder_create(RATE, 1, OPUS_APPLICATION_AUDIO, &mut err);
            assert_eq!(err, OPUS_OK, "opus_encoder_create");
            let rc = opus_encoder_ctl(enc, OPUS_SET_BITRATE_REQUEST, BITRATE);
            assert_eq!(rc, OPUS_OK, "OPUS_SET_BITRATE");
            if fec {
                let rc = opus_encoder_ctl(enc, OPUS_SET_INBAND_FEC_REQUEST, 1i32);
                assert_eq!(rc, OPUS_OK, "OPUS_SET_INBAND_FEC");
                let rc = opus_encoder_ctl(enc, OPUS_SET_PACKET_LOSS_PERC_REQUEST, 10i32);
                assert_eq!(rc, OPUS_OK, "OPUS_SET_PACKET_LOSS_PERC");
            }
            Self(enc)
        }
    }

    fn encode(&mut self, pcm: &[f32]) -> Vec<Vec<u8>> {
        let mut packets = Vec::with_capacity(pcm.len() / FRAME);
        for chunk in pcm.chunks_exact(FRAME) {
            let mut buf = [0u8; 1500];
            let n = unsafe {
                opus_encode_float(
                    self.0,
                    chunk.as_ptr(),
                    FRAME as i32,
                    buf.as_mut_ptr(),
                    buf.len() as i32,
                )
            };
            assert!(n > 0, "opus_encode_float failed: {n}");
            packets.push(buf[..n as usize].to_vec());
        }
        packets
    }
}

impl Drop for Enc {
    fn drop(&mut self) {
        unsafe { opus_encoder_destroy(self.0) };
    }
}

struct Dec(*mut OpusDecoder);

impl Dec {
    fn new() -> Self {
        unsafe {
            let mut err = 0;
            let dec = opus_decoder_create(RATE, 1, &mut err);
            assert_eq!(err, OPUS_OK, "opus_decoder_create");
            Self(dec)
        }
    }

    /// One frame out per call: a packet, PLC (`None`), or an LBRR recovery
    /// of the *previous* frame from `packet` (`fec = true`).
    fn decode(&mut self, packet: Option<&[u8]>, fec: bool) -> Vec<f32> {
        let mut out = vec![0f32; FRAME];
        let n = unsafe {
            match packet {
                Some(p) => opus_decode_float(
                    self.0,
                    p.as_ptr(),
                    p.len() as i32,
                    out.as_mut_ptr(),
                    FRAME as i32,
                    fec as i32,
                ),
                None => opus_decode_float(
                    self.0,
                    std::ptr::null(),
                    0,
                    out.as_mut_ptr(),
                    FRAME as i32,
                    0,
                ),
            }
        };
        assert!(n > 0, "opus_decode_float failed: {n}");
        out
    }
}

impl Drop for Dec {
    fn drop(&mut self) {
        unsafe { opus_decoder_destroy(self.0) };
    }
}

// --- Loss injection --------------------------------------------------

fn loss_mask(frames: usize, profile: &str) -> Vec<bool> {
    let mut rng = XorShift(0xC0FFEE);
    let mut lost = vec![false; frames];
    match profile {
        "2% random" | "5% random" | "10% random" => {
            let p = match profile {
                "2% random" => 0.02,
                "5% random" => 0.05,
                _ => 0.10,
            };
            for slot in &mut lost {
                *slot = rng.next_f64() < p;
            }
        }
        "burst 3%" => {
            // 3-frame bursts; ~3% of frames lost overall.
            let mut i = 0;
            while i < frames {
                if rng.next_f64() < 0.01 {
                    for slot in lost.iter_mut().take(frames).skip(i).take(3) {
                        *slot = true;
                    }
                    i += 3;
                } else {
                    i += 1;
                }
            }
        }
        "blackhole" => {
            // 240 ms dead every 3 s = a Wi-Fi→cellular handover shape.
            let mut i = 0;
            while i < frames {
                for slot in lost.iter_mut().take(frames).skip(i).take(12) {
                    *slot = true;
                }
                i += 162;
            }
        }
        _ => {}
    }
    lost
}

// --- Strategies -----------------------------------------------------

/// Decode a plain (non-RED) stream under `lost` with the given recovery.
/// `fec` packets must be encoded with in-band FEC for `Strategy::Fec`.
fn decode_plain(packets: &[Vec<u8>], lost: &[bool], fec_recovery: bool) -> Vec<f32> {
    let mut dec = Dec::new();
    let mut out = Vec::with_capacity(packets.len() * FRAME);
    for (i, packet) in packets.iter().enumerate() {
        let mut frame = if !lost[i] {
            dec.decode(Some(packet), false)
        } else if fec_recovery && packets.get(i + 1).is_some() && !lost[i + 1] {
            // LBRR copy of frame i rides in packet i+1.
            dec.decode(Some(&packets[i + 1]), true)
        } else {
            if fec_recovery {
                dec.decode(None, false) // PLC fallback at a double loss
            } else {
                vec![0f32; FRAME] // none: silence hole (today's stack)
            }
        };
        out.append(&mut frame);
    }
    out
}

fn decode_plc(packets: &[Vec<u8>], lost: &[bool]) -> Vec<f32> {
    let mut dec = Dec::new();
    let mut out = Vec::with_capacity(packets.len() * FRAME);
    for (i, packet) in packets.iter().enumerate() {
        let mut frame = if lost[i] {
            dec.decode(None, false)
        } else {
            dec.decode(Some(packet), false)
        };
        out.append(&mut frame);
    }
    out
}

/// Simulated RED: wire packet i = len(frame i-1) ++ frame i-1 ++ frame i.
fn red_wire(packets: &[Vec<u8>]) -> Vec<Vec<u8>> {
    packets
        .iter()
        .enumerate()
        .map(|(i, cur)| {
            let prev = if i == 0 { &[][..] } else { &packets[i - 1][..] };
            let mut wire = Vec::with_capacity(2 + prev.len() + cur.len());
            wire.extend_from_slice(&(prev.len() as u16).to_le_bytes());
            wire.extend_from_slice(prev);
            wire.extend_from_slice(cur);
            wire
        })
        .collect()
}

fn red_split(wire: &[u8]) -> (&[u8], &[u8]) {
    let prev_len = u16::from_le_bytes(wire[0..2].try_into().unwrap()) as usize;
    (&wire[2..2 + prev_len], &wire[2 + prev_len..])
}

/// RED receiver: a hole is filled from the next packet's copy of the previous
/// frame (full quality); a double loss falls back to PLC.
fn decode_red(wires: &[Vec<u8>], lost: &[bool]) -> Vec<f32> {
    let mut dec = Dec::new();
    let mut out = Vec::with_capacity(wires.len() * FRAME);
    for (i, wire) in wires.iter().enumerate() {
        let mut frame = if !lost[i] {
            let (_, cur) = red_split(wire);
            dec.decode(Some(cur), false)
        } else if wires.get(i + 1).is_some() && !lost[i + 1] {
            let (prev, _) = red_split(&wires[i + 1]);
            dec.decode(Some(prev), false)
        } else {
            dec.decode(None, false)
        };
        out.append(&mut frame);
    }
    out
}

// --- Metrics --------------------------------------------------------

/// Segmental SNR of `out` against `ref` over active 20 ms frames, clamped
/// to [-10, 45] dB (standard clamp so silence-vs-silence cannot dominate).
fn seg_snr(reference: &[f32], out: &[f32]) -> f64 {
    let mut acc = 0.0;
    let mut n = 0;
    for (r, o) in reference.chunks_exact(FRAME).zip(out.chunks_exact(FRAME)) {
        let energy: f64 = r.iter().map(|s| (*s as f64).powi(2)).sum();
        if (energy / FRAME as f64).sqrt() < 0.01 {
            continue; // inactive frame
        }
        let noise: f64 = r
            .iter()
            .zip(o)
            .map(|(a, b)| (*a as f64 - *b as f64).powi(2))
            .sum();
        let snr = if noise <= 0.0 {
            45.0
        } else {
            (10.0 * (energy / noise).log10()).clamp(-10.0, 45.0)
        };
        acc += snr;
        n += 1;
    }
    if n == 0 {
        0.0
    } else {
        acc / n as f64
    }
}

/// Milliseconds of active reference audio dropped entirely (silent output).
fn hole_ms(reference: &[f32], out: &[f32]) -> f64 {
    let mut ms = 0.0;
    for (r, o) in reference.chunks_exact(FRAME).zip(out.chunks_exact(FRAME)) {
        let energy: f64 = r.iter().map(|s| (*s as f64).powi(2)).sum();
        let silent = o.iter().all(|s| s.abs() < 1e-9);
        if (energy / FRAME as f64).sqrt() >= 0.01 && silent {
            ms += 20.0;
        }
    }
    ms
}

// --- The measurement ------------------------------------------------

#[test]
fn redundancy_levels_under_loss() {
    let frames = 15 * RATE as usize / FRAME; // ~15 s
    let (pcm, source) = match read_wav_pcm16_mono(&fixture_path()) {
        Ok((rate, samples)) => {
            assert_eq!(rate, RATE as u32, "fixture must be 24 kHz");
            (samples, "phonon fixture".to_string())
        }
        Err(_) => (
            synthetic_speech(frames),
            "synthetic (run scripts/opus-loss-fixture.sh for speech)".to_string(),
        ),
    };
    println!("source: {source}");

    let plain = Enc::new(false).encode(&pcm);
    let fec_packets = Enc::new(true).encode(&pcm);
    let wires = red_wire(&plain);
    let n = plain.len();
    let plain_bytes: usize = plain.iter().map(|p| p.len()).sum();
    let fec_bytes: usize = fec_packets.iter().map(|p| p.len()).sum();
    let red_bytes: usize = wires.iter().map(|w| w.len()).sum();
    let wire_x = |bytes: usize| bytes as f64 / plain_bytes as f64;

    let ref_plain: Vec<f32> = {
        let mut dec = Dec::new();
        plain
            .iter()
            .flat_map(|p| dec.decode(Some(p), false))
            .collect()
    };
    let ref_fec: Vec<f32> = {
        let mut dec = Dec::new();
        fec_packets
            .iter()
            .flat_map(|p| dec.decode(Some(p), false))
            .collect()
    };

    println!(
        "{:<12} {:<8} {:>8} {:>9} {:>10}",
        "profile", "strategy", "segSNR", "hole_ms", "wire x"
    );
    for profile in ["clean", "2% random", "5% random", "10% random", "burst 3%", "blackhole"] {
        let lost = loss_mask(n, profile);
        let rows: [((&str, f64), Vec<f32>); 4] = [
            (("none", 1.0), decode_plain(&plain, &lost, false)),
            (("plc", 1.0), decode_plc(&plain, &lost)),
            (("fec", wire_x(fec_bytes)), decode_plain(&fec_packets, &lost, true)),
            (("red", wire_x(red_bytes)), decode_red(&wires, &lost)),
        ];
        for ((name, wire_x), out) in &rows {
            let reference = if *name == "fec" { &ref_fec } else { &ref_plain };
            println!(
                "{:<12} {:<8} {:>8.1} {:>9.1} {:>10}",
                profile,
                name,
                seg_snr(reference, out),
                hole_ms(reference, out),
                format!("{wire_x:.1}x"),
            );
        }
    }

    // Harness sanity: clean pass reproduces its reference; a 5% loss shows
    // holes for `none` and none for the recovery strategies.
    let clean_lost = vec![false; n];
    let clean_none = decode_plain(&plain, &clean_lost, false);
    assert_eq!(seg_snr(&ref_plain, &clean_none), 45.0, "clean decode must match");
    let lost5 = loss_mask(n, "5% random");
    assert!(lost5.iter().any(|l| *l), "5% profile must lose something");
    assert!(hole_ms(&ref_plain, &decode_plain(&plain, &lost5, false)) > 0.0);
    assert_eq!(hole_ms(&ref_plain, &decode_plc(&plain, &lost5)), 0.0);
}
