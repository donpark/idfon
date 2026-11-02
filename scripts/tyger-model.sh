#!/usr/bin/env bash
# Benchmark, build, or clean the distilled student decision model
# (ports/tyger-student; docs/voice-decision-model.md).
#
#   pnpm tyger bench    the numbers: selfcheck + product metrics + decision gate
#   pnpm tyger build    train the student + export ONNX / CoreML / Core AI tiers
#   pnpm tyger clean    remove bench-results/ (gitignored scratch; insights live in docs/)
#
# bench-results/ is fully regenerable: build reproduces the student byte-exact
# (seeded training) and ships the tracked traits, so clean is always safe.
# Featurizing shards is deliberately NOT here — hours of MPS work, see
# ports/tyger-student/README.md.
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"
action=${1:-}

S=$root/ports/tyger-student
PY=$S/.venv/bin/python
SHARDS=$root/bench-results/student-shards
STUDENT=$root/bench-results/student
export TYGER_S2S=${TYGER_S2S:-$HOME/dev/github/tyger-s2s}
export TYGER_BUNDLE=${TYGER_BUNDLE:-$HOME/.cache/huggingface/hub/models--nineninesix--tyger/snapshots/a5d4d73bb74fa4a7082dcd4387e44a1e5ac151b6}

case "$action" in
bench)
    [ -x "$PY" ] || { echo "missing venv: ports/tyger-student/.venv (see ports/tyger-student/README.md)"; exit 1; }
    echo "== selfcheck (synthetic smoke)"
    "$PY" "$S/train.py" --selfcheck
    [ -f "$STUDENT/student.pt" ] || { echo "no student at bench-results/student — run pnpm tyger build"; exit 1; }
    echo
    echo "== product metrics: teacher vs student at the shipped traits (0.85/0.4/0.4 — ep live-calibrated 2026-11-01)"
    "$PY" "$S/harness.py" --shards "$SHARDS/val" --student "$STUDENT/student.pt" \
        --ep-thr 0.85 --barge-thr 0.4 --bc-thr 0.4
    echo
    echo "== decision agreement vs recorded teacher events (bundle defaults; 99% is the same-weights bar, not the student's)"
    "$PY" "$S/gate.py" --shards "$SHARDS/val" --student "$STUDENT/student.pt" || true
    ;;
build)
    [ -x "$PY" ] || { echo "missing venv: ports/tyger-student/.venv (see ports/tyger-student/README.md)"; exit 1; }
    [ -d "$SHARDS/train" ] || { echo "no shards — featurize first (ports/tyger-student/README.md)"; exit 1; }
    echo "== train (seeded; exit 1 = a gated head missed its bar — the table is the verdict)"
    "$PY" "$S/train.py" --shards "$SHARDS/train" --val "$SHARDS/val" --feature-layer 15 \
        --epochs 20 --seed 0 --out "$STUDENT" || true
    cp "$S/student.traits.json" "$STUDENT/student.traits.json"
    echo
    echo "== export ONNX (fp32 shipping default + int8 shelf variant)"
    "$PY" "$S/export.py" --student "$STUDENT/student.pt" --shards "$SHARDS/val"
    echo "== export Core ML (apps pre-27)"
    "$PY" "$S/export_coreml.py" --student "$STUDENT/student.pt" --shards "$SHARDS/val"
    echo "== export Core AI (apps OS-27, + AOT container)"
    "$PY" "$S/export_coreai.py" --student "$STUDENT/student.pt" --shards "$SHARDS/val"
    echo
    echo "== stage the student tiers beside the teacher's (loaders prefer the student; packers read these dirs)"
    mkdir -p "$root/bench-results/onnx" "$root/bench-results/coreml" "$root/bench-results/coreai"
    for pair in "bench-results/student-coreai/student_step_float32.aimodel:bench-results/coreai" \
                "bench-results/student-coreai/student_step_float32.compiled.aimodel:bench-results/coreai" \
                "bench-results/student-coreml/StudentStep.mlpackage:bench-results/coreml"; do
        src=${pair%%:*}; dest=${pair##*:}
        rm -rf "$root/$dest/$(basename "$src")" # a stale per-arch .aimodelc must not survive
        cp -R "$root/$src" "$root/$dest/"
    done
    cp "$root/bench-results/student-onnx/StudentStep.onnx" "$root/bench-results/onnx/"
    # Per-model rules knobs travel with the step (the apps apply them; the
    # teacher's triple is not the student's — bench-results/live-calibration.md)
    cp "$S/student.traits.json" "$root/bench-results/coreai/"
    cp "$S/student.traits.json" "$root/bench-results/coreml/"
    ;;
clean)
    du -sh "$root/bench-results" 2>/dev/null || true
    rm -rf "$root/bench-results"
    echo "bench-results/ removed — gitignored scratch; the insights live in docs/ and the reports are regenerable"
    ;;
*)
    echo "usage: pnpm tyger {bench|build|clean}" >&2
    exit 2
    ;;
esac
