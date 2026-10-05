#!/usr/bin/env python3
"""Run a SuperSpider stage on the four images and score it against the
phase 0 baselines and dynamic ground truth.

Usage: score.py [--stage=s0] [--ref=B0_generic] [--diff]
  --diff   list the first words where the stage and the reference disagree
Writes phase2/out/<image>.<stage>.json.
"""
import json, os, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SS = os.path.join(ROOT, '_build', 'default', 'bin', 'main.exe')
IMAGES = {'galdan': [], 'lemprog': [], 'lemboot': [], 'musmod': ['--module']}
KEYS = ['B0_generic', 'B0_auto', 'B0', 'B1_generic', 'B1', 'B2']


def main():
    opts = dict(a[2:].split('=', 1) if '=' in a else (a[2:], '1') for a in sys.argv[1:] if a.startswith('--'))
    stage = opts.get('stage', 's0')
    ref = opts.get('ref', 'B0_generic')
    os.makedirs(os.path.join(HERE, 'out'), exist_ok=True)
    print('%-8s %6s %8s %8s %8s %10s  %s' % ('image', 'exec', stage, 'exec∩', 'exec−', 'read−exec', 'vs ' + ref))
    for name, extra in IMAGES.items():
        b = json.load(open(os.path.join(ROOT, 'phase0', 'data', name + '.json')))
        t = json.load(open(os.path.join(ROOT, 'phase0', 'data', name + '.truth.json')))
        E = {int(a, 16) for a in t['executed']}
        R = set(t['read'])
        out = os.path.join(HERE, 'out', '%s.%s.json' % (name, stage))
        cmd = {'s0': 'spider'}.get(stage, stage)
        p = subprocess.run([SS, cmd, b['image'], '%x' % b['base']] + extra + ['-o', out],
                           capture_output=True, text=True)
        if p.returncode:
            print(name, 'FAILED', p.stderr)
            continue
        s = json.load(open(out))
        C = set(s['code'])
        X = set(b[ref]) if ref in b else set()
        print('%-8s %6d %8d %8d %8d %10d  ours-only %d, %s-only %d   (%s)' % (
            name, len(E), len(C), len(C & E), len(E - C), len(C & (R - E)) if name != 'lemboot' else -1,
            len(C - X), ref, len(X - C), p.stderr.strip()))
        if 'diff' in opts:
            for lab, d in (('ours-only', sorted(C - X)), (ref + '-only', sorted(X - C))):
                runs, prev = [], None
                for a in d:
                    if prev is not None and a == prev + 4:
                        runs[-1][1] = a
                    else:
                        runs.append([a, a])
                    prev = a
                print('   %s: %s' % (lab, ' '.join('%x-%x' % (x, y) for x, y in runs[:12])))


if __name__ == '__main__':
    main()
