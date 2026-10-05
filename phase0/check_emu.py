#!/usr/bin/env python3
"""Cross-check the coverage recorder against Galactic Dan's independent
Python emulator trace (asm/executed.json: addresses executed by asm/emu.py's
SCENARIO on the *original* binary, 20M instructions). gd-headless replays
the same scenario in the recompiled runtime, so the original trace should
be a subset of its executed set."""
import json, os
GD = os.path.expanduser('~/games/galactic dan')
HERE = os.path.dirname(os.path.abspath(__file__))
ref = set(json.load(open(os.path.join(GD, 'asm', 'executed.json'))))
ours = set()
for line in open(os.path.join(HERE, 'runs', 'gd-headless', 'cov.out')):
    f = line.split()
    if f and f[0] == 'X' and f[1] == 'G':
        ours.add(int(f[2], 16))
missing = sorted(ref - ours)
print('emu.py executed %d, gd-headless executed %d, emu-only %d' % (len(ref), len(ours), len(missing)))
for a in missing[:20]:
    print('  %08x' % a)
