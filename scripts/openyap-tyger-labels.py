#!/usr/bin/env python3
"""Generate Jev/System-One Tyger pseudo-labels from the public Open Yap sample.

The source tar and outputs must stay outside this checkout. This script never
uploads data and extracts only explicitly selected paired tracks.

Example:
  python3 scripts/openyap-tyger-labels.py /path/open-yap-1k-sample.tar \
    --conversation conv_f5c0b02f01e2 --duration-s 30 \
    --out /tmp/openyap-labels \
    --model 'nineninesix/tyger+TygerStepInt8@<manifest-hash>' \
    --rules-revision '<idfon-voice-rules-hash>'

Requirements: ffmpeg, Node.js, the local Tyger ONNX bundle, and its dependencies.
"""

import argparse
import hashlib
import json
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path, PurePosixPath

ROOT = Path(__file__).resolve().parents[1]
TRAINER = ROOT / "scripts/voice-agent-trainer.mjs"
EXPORTER = ROOT / "scripts/tyger-to-systemone.mjs"
DATASET = "TheAgenticDataCompany/open-yap-1k"
DATASET_REVISION = "a08b1c80e50159d462ddcbbabfdea5bf7ccfc626"


def conversation_tracks(tf: tarfile.TarFile) -> dict[str, set[str]]:
    tracks: dict[str, set[str]] = {}
    for member in tf.getmembers():
        name = PurePosixPath(member.name).name
        match = re.fullmatch(r"([A-Za-z0-9_-]+)\.([ab])\.flac", name)
        if match:
            tracks.setdefault(match.group(1), set()).add(match.group(2))
    return {key: value for key, value in tracks.items() if value == {"a", "b"}}


def write_member(tf: tarfile.TarFile, name: str, dest: Path) -> None:
    member = tf.getmember(name)
    src = tf.extractfile(member)
    if src is None:
        raise RuntimeError(f"cannot read tar member {name}")
    with src, dest.open("wb") as out:
        shutil.copyfileobj(src, out, 1 << 20)


def make_stereo_wav(user_flac: Path, agent_flac: Path, wav: Path, start_s: float, duration_s: float | None) -> None:
    graph = (
        "[0:a]aresample=16000,aformat=sample_fmts=s16:channel_layouts=mono[u];"
        "[1:a]aresample=16000,aformat=sample_fmts=s16:channel_layouts=mono[a];"
        "[u][a]amerge=inputs=2[out]"
    )
    cmd = ["ffmpeg", "-y", "-v", "error", "-i", str(user_flac), "-i", str(agent_flac),
           "-filter_complex", graph, "-map", "[out]", "-ss", str(start_s)]
    if duration_s is not None:
        cmd += ["-t", str(duration_s)]
    cmd += ["-shortest", "-ac", "2", "-c:a", "pcm_s16le", str(wav)]
    subprocess.run(cmd, check=True)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def completed_output(label_path: Path, config: dict) -> bool:
    meta_path = label_path.with_suffix(".meta.json")
    if not label_path.exists() and not meta_path.exists():
        return False
    if not label_path.exists() or not meta_path.exists():
        raise RuntimeError(f"incomplete prior output; remove both files or choose another output directory: {label_path}")
    meta = json.loads(meta_path.read_text())
    if meta.get("config") != config or meta.get("sha256") != sha256_file(label_path):
        raise RuntimeError(f"prior output uses a different config or failed its hash check: {label_path}")
    return True


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("tar", nargs="?", help="local Open Yap public-sample WebDataset tar")
    ap.add_argument("--conversation", action="append", help="conversation key; repeat to select more than one")
    ap.add_argument("--user-track", choices=("a", "b"), default="a", help="which source track to treat as caller/user")
    ap.add_argument("--start-s", type=float, default=0, help="clip start in source-relative seconds")
    ap.add_argument("--duration-s", type=float, help="optional clip duration; omit to label the whole conversation")
    ap.add_argument("--out", help="output directory; must be outside the repo")
    ap.add_argument("--model", help="exact Tyger teacher bundle/step identity")
    ap.add_argument("--rules-revision", help="exact idfon turn-rules revision/hash")
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()

    if args.self_test:
        import io
        with tempfile.TemporaryFile() as f:
            with tarfile.open(fileobj=f, mode="w") as tf:
                for name in ("c1.a.flac", "c1.b.flac", "c2.a.flac"):
                    info = tarfile.TarInfo(name)
                    info.size = 1
                    tf.addfile(info, io.BytesIO(b"x"))
            f.seek(0)
            with tarfile.open(fileobj=f, mode="r:") as tf:
                assert conversation_tracks(tf) == {"c1": {"a", "b"}}
        with tempfile.TemporaryDirectory() as td:
            label = Path(td) / "c1.jsonl"
            config = {"conversation_id": "c1"}
            label.write_text("{}\\n")
            label.with_suffix(".meta.json").write_text(json.dumps({"config": config, "sha256": sha256_file(label)}))
            assert completed_output(label, config)
            assert not completed_output(Path(td) / "missing.jsonl", config)
        print("openyap-tyger-labels self-test: OK")
        return

    if not all((args.tar, args.conversation, args.out, args.model, args.rules_revision)):
        ap.error("tar, --conversation, --out, --model, and --rules-revision are required")
    archive = Path(args.tar).resolve()
    out_dir = Path(args.out).resolve()
    if not archive.is_file():
        ap.error(f"sample tar not found: {archive}")
    if out_dir == ROOT or ROOT in out_dir.parents:
        ap.error("output must be outside the repository; audio and labels are local-only")
    if args.start_s < 0 or (args.duration_s is not None and args.duration_s <= 0):
        ap.error("clip start must be >= 0 and duration must be > 0")

    node = shutil.which("node")
    if not node:
        ap.error("node is required")
    out_dir.mkdir(parents=True, exist_ok=True)
    with tarfile.open(archive, mode="r:") as tf:
        available = conversation_tracks(tf)
        missing = [key for key in args.conversation if key not in available]
        if missing:
            ap.error(f"conversation(s) missing paired a/b tracks: {', '.join(missing)}")

        for key in args.conversation:
            slug = re.sub(r"[^A-Za-z0-9_-]", "_", key)
            config = {
                "dataset": DATASET,
                "revision": DATASET_REVISION,
                "conversation_id": key,
                "user_track": args.user_track,
                "start_s": args.start_s,
                "duration_s": args.duration_s,
                "model": args.model,
                "rules_revision": args.rules_revision,
                "labeler_sha256": sha256_file(Path(__file__)),
                "trainer_sha256": sha256_file(TRAINER),
                "exporter_sha256": sha256_file(EXPORTER),
            }
            run_id = hashlib.sha256(json.dumps(config, sort_keys=True).encode()).hexdigest()[:12]
            label_path = out_dir / f"{slug}-{run_id}-tyger.jsonl"
            if completed_output(label_path, config):
                print(f"skip {key}; verified existing labels {label_path}")
                continue
            meta_path = label_path.with_suffix(".meta.json")
            partial_path = label_path.with_suffix(".partial.jsonl")
            partial_path.unlink(missing_ok=True)
            user_track, agent_track = args.user_track, ("b" if args.user_track == "a" else "a")
            with tempfile.TemporaryDirectory(prefix="openyap-tyger-") as td:
                tmp = Path(td)
                user_flac, agent_flac = tmp / "user.flac", tmp / "agent.flac"
                write_member(tf, f"{key}.{user_track}.flac", user_flac)
                write_member(tf, f"{key}.{agent_track}.flac", agent_flac)
                wav, scores, source = tmp / "paired.wav", tmp / "teacher.json", tmp / "source.json"
                make_stereo_wav(user_flac, agent_flac, wav, args.start_s, args.duration_s)
                source.write_text(json.dumps({
                    "dataset": DATASET,
                    "revision": DATASET_REVISION,
                    "conversation_id": key,
                    "offset_ms": round(args.start_s * 1000),
                    "channels": {"user": f"{user_track}.flac", "agent": f"{agent_track}.flac"},
                }))
                subprocess.run(
                    [node, str(TRAINER), str(wav), "--json", str(scores), "--quiet"],
                    check=True, capture_output=True, text=True,
                )
                subprocess.run(
                    [node, str(EXPORTER), str(scores), "--source", str(source), "--out", str(partial_path),
                     "--model", args.model, "--rules-revision", args.rules_revision],
                    check=True, capture_output=True, text=True,
                )
                score_data = json.loads(scores.read_text())
                record_count = sum(1 for line in partial_path.open() if line.strip())
                if record_count != len(score_data["frames"]):
                    raise RuntimeError(f"record count mismatch for {key}: {record_count} != {len(score_data['frames'])}")
                digest = sha256_file(partial_path)
                partial_path.replace(label_path)
                meta = {"config": config, "records": record_count, "bytes": label_path.stat().st_size, "sha256": digest}
                meta_tmp = meta_path.with_suffix(".tmp")
                meta_tmp.write_text(json.dumps(meta, indent=2) + "\n")
                meta_tmp.replace(meta_path)
                print(f"labeled {key}; {record_count} records -> {label_path} (audio scratch deleted on exit)")


if __name__ == "__main__":
    main()
