#!/usr/bin/env python3
"""Phase 3b evaluation: address-taken entry points.

Runs `superspider s1b` on the four images and, for every candidate, prints
its evidence (SWI argument / stored), the verdict, and whether phase 0 saw it
execute (executed = true positive if accepted; 'not run' = unknown: may be
code our sessions didn't reach, or data). Then scores S1b like score.py.

Usage: eval_s1b.py [--quiet]
"""
import json, os, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SS = os.path.join(ROOT, '_build', 'default', 'bin', 'main.exe')
IMAGES = {'galdan': [], 'lemprog': [], 'lemboot': [], 'musmod': ['--module']}


def run(name, extra):
    b = json.load(open(os.path.join(ROOT, 'phase0', 'data', name + '.json')))
    out = os.path.join(ROOT, 'phase2', 'out', '%s.s1b.json' % name)
    p = subprocess.run([SS, 's1b', b['image'], '%x' % b['base']] + extra + ['-o', out],
                       capture_output=True, text=True, check=True)
    text = open(out).read()
    main, _, verdicts = text.rpartition('{"address_taken"')
    return b, json.loads(main), json.loads('{"address_taken"' + verdicts)['address_taken'], p.stderr.strip()


def main():
    quiet = '--quiet' in sys.argv
    print('%-8s %6s %10s %8s %8s %10s  accepted: executed / not run   rejected: executed' % (
        'image', 'exec', 'S1b code', 'exec∩', 'exec−', 'read−exec'))
    for name, extra in IMAGES.items():
        b, s, verdicts, msg = run(name, extra)
        t = json.load(open(os.path.join(ROOT, 'phase0', 'data', name + '.truth.json')))
        E = {int(a, 16) for a in t['executed']}
        R = set(t['read'])
        C = set(s['code'])
        ev = {c: e for c, e in s['candidates']}
        acc = [c for c, v in verdicts if v == 'accepted']
        rej = [c for c, v in verdicts if v != 'accepted']
        print('%-8s %6d %10d %8d %8d %10s  %d / %d   %d     (%s)' % (
            name, len(E), len(C), len(C & E), len(E - C),
            len(C & (R - E)) if name != 'lemboot' else '-',
            sum(c in E for c in acc), sum(c not in E for c in acc), sum(c in E for c in rej), msg))
        if not quiet:
            for c, v in verdicts:
                how = sorted({h for _, h in ev.get(c, [])})
                print('   %08x  %-9s %-40s %s' % (c, 'EXECUTED' if c in E else 'not run', v[:40], ', '.join(how)[:60]))


if __name__ == '__main__':
    main()
