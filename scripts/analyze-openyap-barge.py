"""Barge/interrupt measurement on Open Yap 1K featurized shards.

Reads the label-free shards produced by `featurize.py --wavs` (teacher events +
L4 features + teacher 8-vectors) and measures, for the L4 student:

  agreement        student events vs the teacher's recorded events (aligned_count)
  barge catch      fraction of *teacher BARGE events* the student's yield head
                   crosses the threshold within +/-tol frames (the rules' own barge axis)
  barge false      student BARGE events not aligned to a teacher BARGE event
  yield@VAD        fraction of energy-VAD interrupting onsets where the student's
                   raw yield score >= barge_thr within 640 ms (the tyger-eval definition)
  teacher yield@VAD  same for the teacher's saved 8-vectors (reference)

Usage:
  .venv/bin/python scripts/analyze-openyap-barge.py --shards bench-results/openyap-shards \
      --wavs /tmp/openyap/wavs --student bench-results/student-l4-60/student.pt \
      [--barge-thrs 0.3,0.35,0.4,0.45,0.5] [--ep-thr 0.75]
"""
import argparse
import sys
from pathlib import Path

import numpy as np
import torch

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'ports/tyger-student'))

from gate import aligned_count, student_events  # noqa: E402
from model import Student  # noqa: E402
from oracle import Oracle  # noqa: E402
from registry import by_id  # noqa: E402


def frame_db(x):
    """80 ms frame energy in dB (the rules' VAD scale)."""
    n = len(x) // 1280
    rms = np.array([np.sqrt(np.mean(x[i * 1280:(i + 1) * 1280] ** 2) + 1e-12)
                    for i in range(n)], np.float32)
    return 20.0 * np.log10(rms + 1e-12)


def onsets(user_db, agent_db, thr=-50.0, quiet=-55.0, hold=5, max_gap=800):
    """Mic onsets while the agent plays: speech starts after >= hold quiet frames."""
    out = []
    quiet_run = 0
    for f in range(len(user_db)):
        if user_db[f] < quiet:
            quiet_run += 1
            continue
        if user_db[f] >= thr and quiet_run >= hold and agent_db[f] > -45.0:
            out.append(f)
        if user_db[f] >= thr:
            quiet_run = 0
    kept = []
    for f in out:
        if not kept or f - kept[-1] > max_gap // 80:
            kept.append(f)
    return kept


def catch(scores, onset_frames, barge_thr, window=8, deb=2):
    """Fraction of onsets with `deb` consecutive yield >= thr in the window."""
    hit = 0
    for f in onset_frames:
        run = 0
        for k in range(window):
            i = f + k
            if i < len(scores) and scores[i] >= barge_thr:
                run += 1
                if run >= deb:
                    hit += 1
                    break
            else:
                run = 0
    return hit / len(onset_frames) if onset_frames else float('nan')


def student_scores(model, oracle, frames, layer):
    """Per-frame 8-vector from the student (same loop as gate.student_events)."""
    from data import pick_features
    hu_all, ha_all = pick_features(frames, layer)
    sess = oracle.EarsSession(0)
    hidden = None
    rows = []
    with torch.no_grad():
        for f in range(len(frames['energy'])):
            hu = torch.from_numpy(hu_all[f:f + 1])[None]
            ha = torch.from_numpy(ha_all[f:f + 1])[None]
            act = torch.tensor([[float(frames['energy'][f])]])
            prev = torch.tensor([[int(sess.prev_state)]])
            outs, hidden = model(hu, ha, act, prev, hidden)
            out = model.eight_vector(outs)[0, 0].to(torch.float64).numpy()
            rows.append(out)
            oracle.rules.on_frame(sess, 'response', out, float(frames['energy'][f]),
                                  left=3 - (f % 4))
    return np.stack(rows)


def wav_for_sid(wavs_dir, sid):
    """sid is 'live-<stem>'; the wav is <wavs_dir>/<stem>.wav."""
    stem = sid[5:] if sid.startswith('live-') else sid
    return Path(wavs_dir) / f'{stem}.wav'


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--shards', required=True)
    ap.add_argument('--wavs', default=None, help='raw wav dir for the VAD onsets (optional)')
    ap.add_argument('--student', required=True)
    ap.add_argument('--layer', type=int, default=4)
    ap.add_argument('--ep-thr', type=float, default=0.75)
    ap.add_argument('--bc-thr', type=float, default=0.5)
    ap.add_argument('--barge-thrs', default='0.3,0.35,0.4,0.45,0.5')
    ap.add_argument('--tol', type=int, default=2)
    args = ap.parse_args()

    ck = torch.load(args.student, map_location='cpu')
    model = Student([by_id(i) for i in ck['heads']], width=ck['width'], layers=ck['layers'])
    model.load_state_dict(ck['state_dict'])
    model.eval()
    oracle = Oracle(device='cpu')

    barge_thrs = [float(x) for x in args.barge_thrs.split(',')]
    shards = sorted(Path(args.shards).glob('*.npz'))
    if not shards:
        sys.exit(f'no shards in {args.shards}')

    per_shard = []
    for p in shards:
        z = np.load(p, allow_pickle=True)
        frames = {k: z[k] for k in z.keys() if k in ('hu', 'ha', 'hu_l4', 'ha_l4', 'energy', 'prev_state', 'teacher')}
        teacher_events = list(zip(z['ev_frames'].tolist(), z['ev_kinds'].tolist()))
        sid = str(z['meta']) if 'meta' in z else p.stem
        try:
            import json
            sid = json.loads(sid).get('session_id', p.stem)
        except Exception:
            sid = p.stem

        thr = (args.ep_thr, 0.5, args.bc_thr)
        student_ev = student_events(model, oracle, frames, args.layer, thr)

        # agreement
        al, only_t, only_s = aligned_count(teacher_events, student_ev, args.tol)
        total = max(len(teacher_events), len(student_ev))
        agree = al / total if total else 1.0

        # per-kind counts
        def counts(evs):
            d = {}
            for _, k in evs:
                d[k] = d.get(k, 0) + 1
            return d
        tk, sk = counts(teacher_events), counts(student_ev)

        # barge on teacher BARGE events (aligned) — student yield head crossing
        sv = student_scores(model, oracle, frames, args.layer)
        tv = frames['teacher']
        t_barge = [f for f, k in teacher_events if k == 'BARGE']
        s_barge = [f for f, k in student_ev if k == 'BARGE']

        row = dict(sid=sid, frames=len(frames['energy']), agree=agree,
                   t_ev=len(teacher_events), s_ev=len(student_ev),
                   t_barge=len(t_barge), s_barge=len(s_barge),
                   tk=tk, sk=sk)
        # VAD onsets from the raw wav
        if args.wavs:
            wpath = wav_for_sid(args.wavs, sid)
            if wpath.exists():
                import soundfile as sf
                wav, sr = sf.read(str(wpath), dtype='float32', always_2d=True)
                if sr != 16000:
                    import soxr
                    wav = soxr.resample(wav, sr, 16000, quality='HQ')
                n = len(frames['energy'])
                user_db = frame_db(wav[:, 0])[:n]
                agent_db = frame_db(wav[:, 1])[:n]
                ons = onsets(user_db, agent_db)
                row['onsets'] = len(ons)
                row['sv_catch'] = {t: catch(sv[:, 5], ons, t) for t in barge_thrs}
                row['tv_catch'] = {t: catch(tv[:, 5], ons, t) for t in barge_thrs}
            else:
                row['onsets'] = None
        per_shard.append(row)

        print(f"\n=== {sid} ({row['frames']} frames) ===")
        print(f"  agreement {agree:.2%} ({al}/{total})  teacher events {len(teacher_events)} {tk}")
        print(f"  student events {len(student_ev)} {sk}")
        print(f"  teacher BARGE {len(t_barge)}  student BARGE {len(s_barge)}")
        if row.get('onsets') is not None:
            print(f"  VAD interrupting onsets {row['onsets']}")
            print('  yield catch @thr  student / teacher')
            for t in barge_thrs:
                print(f"    {t:<4}  {row['sv_catch'][t]:.2f} / {row['tv_catch'][t]:.2f}")

    # pooled
    print('\n=== POOLED ===')
    tot_frames = sum(r['frames'] for r in per_shard)
    tot_agree = sum(r['agree'] * max(r['t_ev'], r['s_ev']) for r in per_shard) / max(tot_frames, 1)
    print(f'shards {len(per_shard)}, frames {tot_frames}, pooled agreement {tot_agree:.2%}')
    for kind in ('BARGE', 'ENDPOINT', 'BACKCHANNEL'):
        t = sum(r['tk'].get(kind, 0) for r in per_shard)
        s = sum(r['sk'].get(kind, 0) for r in per_shard)
        print(f'  {kind}: teacher {t}, student {s}')
    ons = [r['onsets'] for r in per_shard if r.get('onsets') is not None]
    if ons:
        total_ons = sum(ons)
        print(f'  VAD onsets total {total_ons}')
        for t in barge_thrs:
            sc = sum((r['sv_catch'][t] or 0) * (r['onsets'] or 0) for r in per_shard if r.get('onsets') is not None)
            tc = sum((r['tv_catch'][t] or 0) * (r['onsets'] or 0) for r in per_shard if r.get('onsets') is not None)
            print(f'    thr {t:<4} student {sc:.2f}/{total_ons} ({sc/max(total_ons,1):.2%})  teacher {tc:.2f}/{total_ons} ({tc/max(total_ons,1):.2%})')


if __name__ == '__main__':
    main()
