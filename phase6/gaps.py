#!/usr/bin/env python3
"""Summarise translation gaps of coverage runs (phase 6).

Lemmings (run with --trace-gaps): runs*/<session>/untranslated.log lists every
dispatch to an address without a translated entry; a gap's *entry* is the
first such address reached from translated code (later lines are the
interpreter stepping on). Galactic Dan (RECOMP_ISTAT=1): log.txt lists
interpreted addresses as "no-entry" (untranslated) or "smc-form" (a
self-modified instruction form the analysis didn't predict).

Usage: gaps.py RUNS_DIR [RUNS_DIR ...]"""
import collections, glob, os, re, sys


def lem_gaps(d):
    prev, entries = set(), collections.Counter()
    p = os.path.join(d, 'untranslated.log')
    if os.path.exists(p):
        for l in open(p):
            m = re.search(r'address ([0-9a-f]+) \(LR=[0-9a-f]+, from pc=([0-9a-f]+)\)', l)
            if not m:
                continue
            a, frm = int(m.group(1), 16), int(m.group(2), 16)
            if frm not in prev and a not in prev:
                entries[a] += 1
            prev.add(a)
    return prev, entries


def interp_stats(d):
    noentry, smc = {}, {}
    for l in open(os.path.join(d, 'log.txt'), errors='replace'):
        m = re.match(r'interp ([0-9a-f]+) (no-entry|smc-form) [0-9a-f]+ x(\d+)', l)
        if m:
            (noentry if m.group(2) == 'no-entry' else smc)[int(m.group(1), 16)] = int(m.group(3))
    tail = [l for l in open(os.path.join(d, 'log.txt'), errors='replace') if 'interpreted' in l]
    total = re.search(r'\((\d+) interpreted', tail[-1]).group(1) if tail else '?'
    return noentry, smc, total


def main():
    for root in sys.argv[1:]:
        print('==', root)
        for d in sorted(glob.glob(os.path.join(root, '*'))):
            if not os.path.isdir(d) or not os.path.exists(os.path.join(d, 'log.txt')):
                continue
            untr, entries = lem_gaps(d)
            noentry, smc, total = interp_stats(d)
            print('  %-14s interpreted %-10s untranslated-entry addresses %4d (gap entries %3d)  '
                  'istat no-entry %4d smc-form %3d   %s' % (
                      os.path.basename(d), total, len(untr), len(entries), len(noentry), len(smc),
                      ' '.join('%x' % a for a in sorted(entries)[:6])))


if __name__ == '__main__':
    main()
