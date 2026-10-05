#!/usr/bin/env python3
"""Phase 3 pass criterion: do the call/return idioms fall out of S1 with no
idiom code? For each image:
  - function exit shapes (LR, LR+4, caller-slot, ...)
  - returns derived at call sites that don't land at site+4, by kind
  - observed returns (phase 0 ground truth) whose call site S1 reached:
    how many land in S1's code
  - the explicit assumptions S1 made (hand-linked calls, stack balance)
Also runs musmod with its hand seeds (S1 can't reach the voice generators on
its own until phase 3b) to check the add r0,pc,#&c ; push return to &2f1c.
"""
import collections, json, os, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SS = os.path.join(ROOT, '_build', 'default', 'bin', 'main.exe')
IMAGES = {'galdan': [], 'lemprog': [], 'lemboot': [], 'musmod': ['--module']}


def word(img, base, a):
    o = a - base
    return int.from_bytes(img[o:o + 4], 'little') if 0 <= o <= len(img) - 4 else None


def is_return_insn(w):
    if w is None:
        return False
    t = (w >> 25) & 7
    if t == 4 and (w >> 20) & 1 and w & 0x8000 and (w >> 16) & 15 == 13:
        return True                                         # ldm sp!, {.., pc}
    if t in (0, 1) and (w >> 12) & 15 == 15 and (w >> 21) & 15 == 13 and (w & 0xFFF) == 14:
        return True                                         # mov(s) pc, lr
    if t == 2 and (w >> 20) & 1 and (w >> 12) & 15 == 15 and (w >> 16) & 15 == 13:
        return True                                         # ldr pc, [sp], #4
    return False


def run(name, extra, seeds=()):
    b = json.load(open(os.path.join(ROOT, 'phase0', 'data', name + '.json')))
    out = os.path.join(HERE, 'out', '%s.s1%s.json' % (name, '-seeded' if seeds else ''))
    args = [SS, 's1', b['image'], '%x' % b['base']] + extra
    for s in seeds:
        args += ['--entry', '%x' % s]
    p = subprocess.run(args + ['-o', out], capture_output=True, text=True, check=True)
    return b, json.load(open(out)), p.stderr.strip()


def report(name, b, s, msg, label=None):
    t = json.load(open(os.path.join(ROOT, 'phase0', 'data', name + '.truth.json')))
    img = open(b['image'], 'rb').read()
    base = b['base']
    C = set(s['code'])
    shapes = collections.Counter(x.split(' ')[0] for _, ex in s['summaries'] for x in ex)
    shapes['(no exit)'] = sum(1 for _, ex in s['summaries'] if not ex)
    odd = collections.Counter()
    for site, targets in s['returns']:
        for tg in targets:
            if tg != site + 4:
                odd['+%d' % (tg - site) if 0 < tg - site < 64 else 'elsewhere'] += 1
    # observed returns whose call site S1 reached
    seen = found = 0
    missing = []
    for src, dst, n in t['edges']:
        if src == 0xFFFFFFFF or not is_return_insn(word(img, base, src)):
            continue
        # call site: the bl / push / link set-up that precedes dst
        calls = [dst - k for k in (4, 8, 12) if (dst - k) in C]
        if not calls:
            continue
        seen += 1
        if dst in C:
            found += 1
        else:
            missing.append((src, dst))
    print('== %s: %s' % (label or name, msg))
    print('   exit shapes:', dict(shapes.most_common()))
    print('   derived returns not at +4:', dict(odd))
    print('   observed returns with call site in S1 code: %d, landing in S1 code: %d' % (seen, found))
    for src, dst in missing[:5]:
        print('     missing: return %x -> %x' % (src, dst))


def main():
    for name, extra in IMAGES.items():
        b, s, msg = run(name, extra)
        report(name, b, s, msg)
    b = json.load(open(os.path.join(ROOT, 'phase0', 'data', 'musmod.json')))
    b, s, msg = run('musmod', ['--module'], seeds=b['hand_seeds'])
    print()
    report('musmod', b, s, msg, label='musmod with hand seeds')
    rs = {a: ts for a, ts in s['returns']}
    hits = [(hex(a), [hex(x) for x in ts]) for a, ts in rs.items() if 0x1802f1c in ts]
    print('   &2f1c derived as a return target at:', hits or 'nowhere')
    sm = dict(s['summaries'])
    for f in (0x1802ed0, 0x1802f60):
        print('   summary of %x: %s' % (f, sm.get(f)))


if __name__ == '__main__':
    main()
