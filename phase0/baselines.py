#!/usr/bin/env python3
"""Static baselines for SuperSpider's evaluation (PLAN.md, phase 0).

For each image, writes data/<name>.json with word-address sets:

  B0_generic  Galactic Dan's spider.py (no Lemmings idiom patches), descent
            only, given entries only
  B0_auto   project spider.py, recursive descent only (no speculation), seeded
            only with what a tool is legitimately given: the load address, or
            the module header's entry points
  B0        as B0_auto plus the hand-found seed entries the projects use
  B1_auto   B0_auto + spider.py's speculative gap pass       (--spec only; slow)
  B1_generic  B0_generic + speculation                     (--spec only; slow)
  B1        the shipped spider pickle: B0 + speculation (firm + spec words)
  B1_spec   the speculative part of B1
  B1_data   words the spider classified as data (literals, tables, strings)
  B2        what actually shipped: the recompiler's codemap (B1 + Ghidra-only
            code + gen_c.py extensions + dynamic additions)

plus the seeds (split into given vs hand-found) and image metadata.

Usage: baselines.py [--spec] [name ...]
"""
import importlib.util, json, os, pickle, re, sys, time

HOME = os.path.expanduser('~')
GD = os.path.join(HOME, 'games', 'galactic dan')
LEM = os.path.join(HOME, 'games', 'lemmings')
HERE = os.path.dirname(os.path.abspath(__file__))

MODBASE = 0x1800000
IMAGES = {
    'galdan': dict(img=os.path.join(GD, 'extracted', 'GalacticDan_8000,ff8'), base=0x8000,
                   spider=os.path.join(GD, 'ghidra', 'spider.py'),
                   pickle=os.path.join(GD, 'ghidra', 'galdan.json.pickle'),
                   entries=os.path.join(GD, 'recomp', 'gen', 'entries.c'), prefix='recomp',
                   given=[0x8000], hand=[]),
    'lemprog': dict(img=os.path.join(LEM, 'extracted_decompressed', 'LemProg.bin'), base=0x8000,
                    spider=os.path.join(LEM, 'ghidra', 'spider.py'),
                    pickle=os.path.join(LEM, 'ghidra', 'lemprog.json.pickle'),
                    entries=os.path.join(LEM, 'recomp', 'gen', 'entries.c'), prefix='recomp',
                    given=[0x8000], hand=[0x19388]),
    'lemboot': dict(img=os.path.join(LEM, 'extracted', '!LEMMINGS', 'LemBoot,fffff843-00000000'),
                    base=0x8000,
                    spider=os.path.join(LEM, 'ghidra', 'spider.py'),
                    pickle=os.path.join(LEM, 'ghidra', 'lemboot.json.pickle'),
                    entries=os.path.join(LEM, 'recomp', 'genboot', 'entries.c'), prefix='recompB',
                    given=[0x8000], hand=[0x82c0]),
    # Module header: init &684, final &9d4, service &4f4, SWI handler &570 are
    # given; the rest are run_ghidra_musmod.sh's hand-found seeds.
    'musmod': dict(img=os.path.join(LEM, 'extracted', '!LEMMINGS', 'musmod2,fffffa43-00000000'),
                   base=MODBASE,
                   spider=os.path.join(LEM, 'ghidra', 'spider.py'),
                   pickle=os.path.join(LEM, 'ghidra', 'musmod.json.pickle'),
                   entries=os.path.join(LEM, 'recomp', 'genmus', 'entries.c'), prefix='recompM',
                   given=[MODBASE + o for o in (0x684, 0x9d4, 0x4f4, 0x570)],
                   hand=[MODBASE + o for o in (0x970, 0x99c, 0x9ac, 0x8f4, 0x89c, 0x920, 0x938,
                                               0x950, 0x2ed0, 0x2f60, 0x2f1c, 0x2444, 0x2608,
                                               0x27cc, 0x2990)]),
}


def load_spider(path):
    """Import a project's spider.py as module 'spider' (the pickles refer to
    classes by that name; the two projects' copies differ)."""
    spec = importlib.util.spec_from_file_location('spider', path)
    mod = importlib.util.module_from_spec(spec)
    sys.modules['spider'] = mod
    spec.loader.exec_module(mod)
    return mod


def run_spider(sp_mod, img, seeds, spec=False):
    sp = sp_mod.Spider(img)
    for a in seeds:
        sp.add_func(a)
    sp.run()
    if spec:
        sp_mod.speculate(sp)
    return sp


def codemap(path, prefix):
    src = open(path).read()
    m = re.search(r'%s_codemap\[\] = \{(.*?)\};' % re.escape(prefix), src, re.S)
    bs = [int(x, 0) for x in re.findall(r'(?:0x)?[0-9a-fA-F]+', m.group(1))]
    base = int(re.search(r'%s_img_base = (0x[0-9a-f]+)u' % re.escape(prefix), src).group(1), 16) \
        if '%s_img_base' % prefix in src else 0x8000
    return sorted(base + 4 * (8 * i + k) for i, b in enumerate(bs) for k in range(8) if b >> k & 1)


def main():
    do_spec = '--spec' in sys.argv
    names = [a for a in sys.argv[1:] if not a.startswith('--')] or list(IMAGES)
    os.makedirs(os.path.join(HERE, 'data'), exist_ok=True)
    for name in names:
        d = IMAGES[name]
        sp_mod = load_spider(d['spider'])
        data = open(d['img'], 'rb').read()
        img = sp_mod.Image(data, d['base'])
        out = dict(name=name, image=d['img'], base=d['base'], size=len(data),
                   given_seeds=d['given'], hand_seeds=d['hand'])
        t = time.time()
        out['B0_auto'] = sorted(run_spider(sp_mod, img, d['given']).code)
        out['B0'] = sorted(run_spider(sp_mod, img, d['given'] + d['hand']).code)
        # Galactic Dan's spider: none of Lemmings' idiom patches (literal
        # thunks, push-pc + NV filler) - what a generic tool would get.
        gd_mod = load_spider(IMAGES['galdan']['spider'])
        out['B0_generic'] = sorted(run_spider(gd_mod, gd_mod.Image(data, d['base']), d['given']).code)
        sp_mod = load_spider(d['spider'])
        if do_spec:
            out['B1_auto'] = sorted(run_spider(sp_mod, img, d['given'], spec=True).code)
            if name != 'galdan':
                gd_mod = load_spider(IMAGES['galdan']['spider'])
                out['B1_generic'] = sorted(run_spider(gd_mod, gd_mod.Image(data, d['base']), d['given'],
                                                      spec=True).code)
                sp_mod = load_spider(d['spider'])
        sp = pickle.load(open(d['pickle'], 'rb'))
        out['B1'] = sorted(sp.code)
        out['B1_spec'] = sorted(sp.spec)
        out['B1_data'] = sorted(set(sp.data) | set(sp.writes))
        out['B2'] = codemap(d['entries'], d['prefix'])
        dt = time.time() - t
        path = os.path.join(HERE, 'data', name + '.json')
        if do_spec is False and os.path.exists(path):      # keep an earlier B1_auto
            old = json.load(open(path))
            for k in ('B1_auto', 'B1_generic'):
                if k in old:
                    out[k] = old[k]
        json.dump(out, open(path, 'w'))
        words = len(data) // 4
        print('%-8s %6d words  ' % (name, words) + '  '.join(
            '%s=%d' % (k, len(out[k])) for k in
            ('B0_generic', 'B0_auto', 'B0', 'B1_generic', 'B1_auto', 'B1', 'B1_spec', 'B1_data', 'B2') if k in out)
            + '  (%.0fs)' % dt)


if __name__ == '__main__':
    main()
