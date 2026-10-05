#!/usr/bin/env python3
"""Join dynamic coverage (runs/*/cov.out) with the static baselines
(data/<image>.json) - PLAN.md phase 0.

Writes data/<image>.truth.json (executed words, indirect sites and their
observed targets, return edges, read/written words) and prints a summary.

Usage: ground_truth.py [run-dir ...]     (default: every runs/*/cov.out)
"""
import collections, glob, json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
TAGS = {'G': 'galdan', 'P': 'lemprog', 'B': 'lemboot', 'M': 'musmod'}
# LemBoot runs from a copy of itself at &40000 (relocated by &38000); its
# executed addresses are reported unbiased, but data accesses to the copy
# are at the real address.
RELOC = {'lemboot': (0x40000, 0x42000, 0x38000)}


def load_runs(paths):
    ex = collections.defaultdict(collections.Counter)      # image -> addr -> hits
    seen_in = collections.defaultdict(lambda: collections.defaultdict(set))
    edges = collections.defaultdict(collections.Counter)   # image -> (src, dst) -> n
    rd = collections.defaultdict(set)
    wr = collections.defaultdict(set)
    smc = collections.defaultdict(set)
    entries = collections.defaultdict(collections.Counter)  # runtime/OS entries
    for p in paths:
        run = os.path.basename(os.path.dirname(p))
        for line in open(p):
            f = line.split()
            if not f or f[0].startswith('#'):
                continue
            img = TAGS.get(f[1])
            if img is None:
                continue
            if f[0] == 'X':
                a = int(f[2], 16)
                ex[img][a] += int(f[3])
                seen_in[img][a].add(run)
            elif f[0] == 'N':
                entries[img][int(f[3], 16)] += int(f[4])
            elif f[0] == 'E':
                edges[img][(int(f[2], 16), int(f[3], 16))] += int(f[4])
            elif f[0] in 'RWS':
                a = int(f[2], 16)
                if img in RELOC:
                    lo, hi, d = RELOC[img]
                    if lo <= a < hi:
                        a -= d
                {'R': rd, 'W': wr, 'S': smc}[f[0]][img].add(a)
    return ex, seen_in, edges, rd, wr, smc, entries


class Img:
    def __init__(self, base_json):
        d = base_json
        self.base, self.size = d['base'], d['size']
        self.data = open(d['image'], 'rb').read()

    def inside(self, a):
        return self.base <= a < self.base + self.size

    def word(self, a):
        o = a - self.base
        return int.from_bytes(self.data[o:o + 4], 'little') if 0 <= o <= self.size - 4 else None


def branch_target(a, w):
    off = w & 0xFFFFFF
    if off & 0x800000:
        off -= 0x1000000
    return (a + 8 + off * 4) & 0x3FFFFFC


def pc_kind(w):
    """How instruction w writes the PC, or None if it doesn't."""
    if w is None:
        return 'outside'
    t = (w >> 25) & 7
    if t == 5:
        return 'bl' if w & (1 << 24) else 'b'
    if t == 7 and (w >> 24) & 15 == 15:
        return 'swi'
    if t == 4 and (w >> 20) & 1 and w & (1 << 15):
        return 'ldm_pc'
    if t in (2, 3) and (w >> 20) & 1 and (w >> 12) & 15 == 15:
        return 'ldr_pc'
    if t in (0, 1) and (w & 0x0E000090) != 0x90 and (w >> 12) & 15 == 15:
        op = (w >> 21) & 15
        if 8 <= op <= 11:
            return None                          # TEQP etc.: PSR only
        if op == 13 and t == 0 and (w & 0xFF0) == 0:
            return 'mov_pc_lr' if (w & 15) == 14 else 'mov_pc_reg'
        return 'dp_pc'                           # add pc,pc,rX etc.
    return None


def is_pop(w):
    """ldr pc,[sp],#4 style: a return through the stack."""
    return (w >> 16) & 15 == 13


def return_shape(img, dst):
    """What precedes a return target: the call that set up the return."""
    w4, w8, w12 = (img.word(dst - k) if img.inside(dst - k) else None for k in (4, 8, 12))
    if w4 is not None and pc_kind(w4) == 'bl':
        return 'bl+4'
    if w8 is not None and pc_kind(w8) == 'bl':
        return 'bl+8'
    if w12 is not None and (w12 & 0x0FFFFFFF) == 0x092D8000:
        return 'push_pc+12'                     # stmdb sp!,{pc} ; NV ; b
    if w4 is not None and pc_kind(w4) in ('b', 'mov_pc_reg', 'ldr_pc', 'dp_pc'):
        return 'after-jump'                     # e.g. mov lr,pc / add r0,pc,#k ; b / mov pc,rX
    return 'other'


def classify_edges(img, edges):
    """Split observed edges into direct branches, indirect sites and
    anomalies. Returns (indirect: src -> {dst: n}, returns: list, other)."""
    indirect = collections.defaultdict(collections.Counter)
    returns = collections.Counter()           # 'bl+4' / 'bl+8' / 'other' per return edge
    ret_odd = []
    other = []
    n_direct = 0
    for (src, dst), n in edges.items():
        w = img.word(src) if img.inside(src) else None
        k = pc_kind(w)
        if k in ('b', 'bl') and branch_target(src, w) == dst:
            n_direct += 1
            continue
        if k in ('b', 'bl', 'swi', None, 'outside'):
            other.append(dict(src=src, dst=dst, n=n, kind=k, word=w))
            continue
        indirect[src][dst] += n
        if k in ('mov_pc_lr', 'ldm_pc') or (k in ('ldr_pc', 'mov_pc_reg') and is_pop(w)):
            why = return_shape(img, dst)
            returns[why] += 1
            if why != 'bl+4':
                ret_odd.append(dict(src=src, dst=dst, why=why, kind=k))
    return n_direct, indirect, returns, ret_odd, other


def main():
    paths = [os.path.join(p, 'cov.out') for p in sys.argv[1:]] or \
        sorted(glob.glob(os.path.join(HERE, 'runs', '*', 'cov.out')))
    paths = [p for p in paths if os.path.exists(p)]
    ex, seen_in, edges, rd, wr, smc, entries = load_runs(paths)
    print('runs: %s\n' % ' '.join(os.path.basename(os.path.dirname(p)) for p in paths))
    for name in TAGS.values():
        bp = os.path.join(HERE, 'data', name + '.json')
        if name not in ex or not os.path.exists(bp):
            continue
        b = json.load(open(bp))
        img = Img(b)
        E = {a for a in ex[name] if img.inside(a)}
        E_out = {a for a in ex[name] if not img.inside(a)}
        R = {a for a in rd[name] if img.inside(a)}
        W = {a for a in wr[name] if img.inside(a)}
        n_direct, indirect, returns, ret_odd, other = classify_edges(img, edges[name])
        print('%s: %d words, %d executed (%.1f%%), %d executed outside image' % (
            name, img.size // 4, len(E), 100.0 * len(E) / (img.size // 4), len(E_out)))
        print('  %-8s %7s %9s %9s %12s' % ('', 'words', 'exec∩X', 'exec−X', 'X∩read−exec'))
        for k in ('B0_generic', 'B0_auto', 'B0', 'B1_generic', 'B1_auto', 'B1', 'B2'):
            if k not in b:
                continue
            X = set(b[k])
            print('  %-8s %7d %9d %9d %12d' % (k, len(X), len(E & X), len(E - X), len(X & (R - E))))
        print('  edges: %d direct, %d indirect sites (%d with >1 target), returns %s' % (
            n_direct, len(indirect), sum(len(v) > 1 for v in indirect.values()), dict(returns)))
        print('  unexplained edges: %d' % len(other))
        for o in other[:12]:
            print('    %08x -> %08x  x%d  %s %s' % (o['src'], o['dst'], o['n'], o['kind'],
                                                  '%08x' % o['word'] if o['word'] is not None else '-'))
        S = {a for a in smc[name] if img.inside(a)}
        print('  words executed after being written (SMC): %d\n' % len(S))
        out = dict(
            runs=[os.path.basename(os.path.dirname(p)) for p in paths],
            executed={'%x' % a: [ex[name][a], sorted(seen_in[name][a])] for a in sorted(E)},
            executed_outside=sorted(E_out),
            indirect={'%x' % s: {'%x' % d: n for d, n in sorted(t.items())}
                      for s, t in sorted(indirect.items())},
            indirect_kind={'%x' % s: pc_kind(img.word(s)) for s in indirect},
            returns_nonstandard=ret_odd, unexplained_edges=other,
            read=sorted(R), written=sorted(W), smc=sorted(S),
            edges=sorted([s_, d_, n_] for (s_, d_), n_ in edges[name].items()),
            entries=sorted([d_, n_] for d_, n_ in entries[name].items()))
        json.dump(out, open(os.path.join(HERE, 'data', name + '.truth.json'), 'w'), indent=0)


if __name__ == '__main__':
    main()
