#!/bin/sh
set -eu

# Audio quality round trip through the live path:
#
#   macOS `say` TTS -> 48k mono WAV -> idfon send --stream (--loop) -> iroh-live
#   -> idfon get (Opus decode) -> WAV -> alignment + objective metrics
#
# Metrics (source vs decoded, time-aligned via envelope + sample-domain
# cross-correlation):
#   envelope correlation — speech-intelligibility proxy
#   segmental SNR        — waveform fidelity of the codec round trip
#   high-band energy     — fullband check (energy above 8 kHz vs total)
#
# Artifacts kept for ear checks: audio-source.wav / audio-decoded.wav /
# audio-aligned.wav, metrics in audio-quality.json.
#
# PASS: envelope corr >= 0.85 and segmental SNR >= 12 dB.
# Usage: scripts/audio-quality.sh [--voice NAME] [--seconds N]

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

voice=Albert
seconds=24
while [ $# -gt 0 ]; do
  case "$1" in
    --voice) voice=$2; shift 2 ;;
    --seconds) seconds=$2; shift 2 ;;
    *) echo "unknown arg $1" >&2; exit 1 ;;
  esac
done

for tool in say sox jq; do
  command -v "$tool" >/dev/null || { echo "missing tool: $tool" >&2; exit 1; }
done

cargo build --release -p idfond -p idfon-cli
codesign --force -s - target/release/idfond target/release/idfon

work=$(mktemp -d /tmp/idfon-audioq.XXXXXX)
pids=""
cleanup() {
  if [ -n "$pids" ]; then kill $pids 2>/dev/null || true; fi
  rm -rf "$work"
}
trap cleanup EXIT

A="$work/pub/idfond.sock"
B="$work/sub/idfond.sock"

# 1. Speech source: TTS -> 48k mono WAV (~10 s).
say -v "$voice" -o "$work/speech.aiff" \
  "The quick brown fox jumps over the lazy dog. Testing one two three, \
checking voice quality over a lossless peer to peer audio link. \
The sound of the surf and the singing kettle are easy on the ear." 2>/dev/null
sox "$work/speech.aiff" -r 48000 -c 1 "$work/speech.wav" 2>/dev/null

# 2. Two daemons, publish on A (looped), get on B.
mkdir -p "$work/pub" "$work/sub"
target/release/idfond --socket "$A" --data-dir "$work/pub" &
pids="$pids $!"
target/release/idfond --socket "$B" --data-dir "$work/sub" &
pids="$pids $!"
for _ in $(seq 1 100); do
  target/release/idfon --socket "$A" status --json >/dev/null 2>&1 \
    && target/release/idfon --socket "$B" status --json >/dev/null 2>&1 && break
  sleep 0.1
done

ticket=$(target/release/idfon --socket "$A" send --stream --file "$work/speech.wav" --loop)
sleep 2   # let the first announce land

target/release/idfon --socket "$B" get "$ticket" --out "$work/rec.wav" \
  --seconds "$seconds" --json > "$work/listen.json"
echo "recorded $(jq -r .result.duration_ms "$work/listen.json")ms, $(jq -r .result.packets "$work/listen.json") packets"

# 3. Artifacts for ear checks (also the analysis inputs).
cp "$work/speech.wav" audio-source.wav
cp "$work/rec.wav" audio-decoded.wav

# 4. Align + metrics.
python3 - audio-source.wav audio-decoded.wav <<'EOF'
import sys, wave, struct, math, json, subprocess

def read_wav(path):
    w = wave.open(path, 'rb')
    rate, ch, n = w.getframerate(), w.getnchannels(), w.getnframes()
    frames = w.readframes(n)
    w.close()
    assert rate == 48000 and ch == 1, path
    return struct.unpack('<%dh' % (len(frames)//2), frames)

src = read_wav(sys.argv[1])
dec = read_wav(sys.argv[2])

def env(x, win=480):  # 10ms RMS envelope
    return [math.sqrt(sum(v*v for v in x[s:s+win])/win) for s in range(0, len(x)-win, win)]

def corr(a, b):
    ma, mb = sum(a)/len(a), sum(b)/len(b)
    num = sum((x-ma)*(y-mb) for x, y in zip(a, b))
    da = math.sqrt(sum((x-ma)**2 for x in a)); db = math.sqrt(sum((y-mb)**2 for y in b))
    return num/(da*db) if da > 0 and db > 0 else 0.0

se, de = env(src), env(dec)

# coarse alignment: best envelope lag (source start inside the recording)
best_lag = max(range(max(1, len(de) - len(se))), key=lambda L: corr(se, de[L:L+len(se)]))

# fine alignment: sample-domain cross-correlation near the envelope lag.
# Decimate by 6 (8 kHz) over +-120ms, on the first second of the aligned region.
DEC = 6
src_d = src[::DEC]
off_coarse = best_lag * 480
probe = src_s = src[:48000:DEC]
best_d, best_score = None, -1e30
for delta in range(-720, 721, 2):  # +-120ms at 8kHz, 2-sample steps
    start = off_coarse//DEC + delta
    if start < 0 or start + len(probe) > len(dec)//DEC:
        continue
    seg = dec[start*DEC::DEC][:len(probe)]
    score = sum(a*b for a, b in zip(src_d, seg))
    if score > best_score:
        best_score, best_d = score, start*DEC

# sample-accurate refine at 48 kHz over +-3ms around the coarse hit
best_off, best_score = off_coarse, -1e30
probe48 = src[:24000]
for delta in range(-144, 145, 2):
    start = best_d + delta
    if start < 0 or start + len(probe48) > len(dec):
        continue
    score = sum(a*b for a, b in zip(probe48, dec[start:start+len(probe48)]))
    if score > best_score:
        best_score, best_off = score, start

print(f"alignment: source starts at {best_off/48000:.3f}s in the recording")

# aligned segment covering one full source pass
seg = dec[best_off:best_off+len(src)]
n = min(len(src), len(seg))
src_s, seg_s = src[:n], seg[:n]

# metric 1: envelope correlation on the aligned pair
ec = corr(se, de[best_lag:best_lag+len(se)])

# metric 2: segmental SNR over active speech frames (20 ms)
err_pow, sig_pow, frames_used = 0.0, 0.0, 0
for s in range(0, n - 960, 960):
    sig = sum(v*v for v in src_s[s:s+960]) / 960
    if sig > 1e6:  # active speech only (~1k+ RMS)
        err = sum((a-b)*(a-b) for a, b in zip(src_s[s:s+960], seg_s[s:s+960])) / 960
        sig_pow += sig; err_pow += err; frames_used += 1
snr = 10 * math.log10(sig_pow / err_pow) if err_pow > 0 else 99.0

# metric 3: high-band presence via sox (energy above 8 kHz vs total)
def rms_db(path, *effects):
    out = subprocess.run(['sox', path, '-n', *effects, 'stats'],
                         capture_output=True, text=True).stderr
    for line in out.splitlines():
        parts = line.split()
        if len(parts) >= 3 and parts[0] == 'RMS' and parts[1] == 'lev':
            return float(parts[-1])
    return -999.0

with wave.open('audio-aligned.wav', 'wb') as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(48000)
    w.writeframes(struct.pack('<%dh' % len(seg_s), *seg_s))

def band_ratio(path):
    return rms_db(path, 'highpass', '8000') - rms_db(path)

metrics = {'envelope_corr': round(ec, 3), 'seg_snr_db': round(snr, 1),
           'active_frames': frames_used,
           'aligned_highband_db': round(band_ratio('audio-aligned.wav'), 1),
           'decoded_highband_db': round(band_ratio('audio-decoded.wav'), 1)}
json.dump(metrics, open('audio-quality.json', 'w'))
for k, v in metrics.items():
    print(f"{k}: {v}")

ok = ec >= 0.85 and snr >= 12.0 and frames_used > 20
print("PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)
EOF
