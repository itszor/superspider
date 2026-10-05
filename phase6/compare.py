#!/usr/bin/env python3
"""Phase 6 comparison of the same sessions on the shipped-analysis builds
(phase0/runs) and the SuperSpider-built ones (phase0/runs6):
  - gd-headless is deterministic (instruction-count interrupts): its event
    log, VDU output, screen and final registers must be byte-identical
  - per session: instructions executed, interpreted, and executed words /
    edges recorded (wall-clock sessions differ run to run, so these are a
    sanity check, not an equality)"""
import filecmp, os, re

HERE = os.path.dirname(os.path.abspath(__file__))
P0 = os.path.join(os.path.dirname(HERE), 'phase0')


def stats(d):
    log = open(os.path.join(d, 'log.txt'), errors='replace').read()
    m = re.findall(r'after (\d+) instructions \((\d+) interpreted', log)
    ex = sum(1 for l in open(os.path.join(d, 'cov.out')) if l.startswith('X '))
    return (m[-1] if m else ('?', '?')), ex


print('gd-headless (deterministic) outputs:')
for f in ('recomp.events', 'recomp.vdu', 'recomp.screen', 'recomp.regs'):
    a, b = os.path.join(P0, 'runs', 'gd-headless', f), os.path.join(P0, 'runs6', 'gd-headless', f)
    same = os.path.exists(a) and os.path.exists(b) and filecmp.cmp(a, b, shallow=False)
    print('  %-14s %s' % (f, 'identical' if same else 'DIFFERENT'))
print()
print('%-13s %15s %12s %8s | %15s %12s %8s' % ('session', 'insns', 'interpreted', 'X words',
                                              'insns (SS)', 'interp (SS)', 'X (SS)'))
for s in sorted(os.listdir(os.path.join(P0, 'runs6'))):
    d0, d6 = os.path.join(P0, 'runs', s), os.path.join(P0, 'runs6', s)
    if not os.path.isdir(d6) or not os.path.exists(os.path.join(d6, 'log.txt')):
        continue
    (i0, n0), x0 = stats(d0)
    (i6, n6), x6 = stats(d6)
    print('%-13s %15s %12s %8d | %15s %12s %8d' % (s, i0, n0, x0, i6, n6, x6))
