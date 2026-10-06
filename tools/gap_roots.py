#!/usr/bin/env python3
"""Merge the gap entries a recompiled program's run found into a roots file
for the next analysis (superspider ... --roots FILE), so that coverage
improves run by run where the static analysis alone falls short.

LOG is libroger's untranslated.log (run with --trace-gaps): one line per
untranslated address, the first time it's reached,

  <icount>: branch to untranslated address <a> (LR=<lr>, from pc=<from>) img=<base>-<end>

A gap address reached from the gap word just before it is the interpreter
stepping on; any other is an entry - control arriving at code the analysis
didn't find or didn't make a dispatch leader - and becomes a root. Only the
addresses inside IMAGE (loaded at BASE) are taken; lines from logs without
the img= tag are taken by address range alone (ambiguous when two images
are translated for the same address).

The roots file keeps its existing lines and comments; new roots are
appended in address order, each with where it was seen from.

Usage: gap_roots.py IMAGE BASE ROOTS_FILE LOG [LOG ...]"""
import os, re, sys

LINE = re.compile(r'address ([0-9a-f]+) \(LR=([0-9a-f]+), from pc=([0-9a-f]+)\)(?: img=(none|[0-9a-f]+-[0-9a-f]+))?')


def read_roots(path):
    roots = set()
    if os.path.exists(path):
        for l in open(path):
            t = l.split('#', 1)[0].split()
            if t:
                roots.add(int(t[0].lstrip('&').removeprefix('0x'), 16))
    return roots


def gap_entries(logs, base, end):
    lines = []
    for p in logs:
        for l in open(p, errors='replace'):
            m = LINE.search(l)
            if m:
                lines.append((int(m.group(1), 16), int(m.group(2), 16), int(m.group(3), 16), m.group(4)))
    logged = {a for a, _, _, _ in lines}
    tag = '%08x-%08x' % (base, end)
    entries = {}
    for a, lr, frm, img in lines:
        if img is not None and img != tag or not base <= a < end:
            continue
        if frm == a - 4 and frm in logged:
            continue                    # the interpreter stepping on
        entries.setdefault(a, (frm, lr))
    return entries


def main():
    if len(sys.argv) < 5:
        sys.exit(__doc__)
    image, base, roots_path = sys.argv[1], int(sys.argv[2].lstrip('&'), 16), sys.argv[3]
    end = base + os.path.getsize(image)
    have = read_roots(roots_path)
    new = {a: v for a, v in gap_entries(sys.argv[4:], base, end).items() if a not in have}
    if new:
        with open(roots_path, 'a') as f:
            for a in sorted(new):
                frm, lr = new[a]
                f.write('&%x\t# gap entry, from pc=&%x LR=&%x\n' % (a, frm, lr))
    print('%s: %d new roots%s (%d in all)' % (
        roots_path, len(new), (': ' + ' '.join('&%x' % a for a in sorted(new)[:12])
                               + (' ...' if len(new) > 12 else '')) if new else '',
        len(have) + len(new)))


if __name__ == '__main__':
    main()
