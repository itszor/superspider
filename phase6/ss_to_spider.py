#!/usr/bin/env python3
"""Phase 6: turn SuperSpider's analysis (superspider s1b JSON) into the
artifacts the recompilation projects' tooling reads, so that their
export_ghidra.py and gen_c.py run unchanged on it:

  <out>.json.pickle   a spider.Spider object filled from SuperSpider's
                      results (code ownership, functions, data, call
                      overrides, Duff's-device sites, self-modification)
  <out>.json          written by the project's own export_ghidra.py from
                      that pickle, plus "ss_dispatch": every address
                      SuperSpider knows control can arrive at through an
                      indirect transfer (function entries, resolved return
                      sites and jump targets, address-taken entries), used
                      by the patched gen_c.py as its dispatch leaders
  <tsvdir>/functions.tsv   function list (gen_c only reads entry addresses)

No Ghidra, no hand-found seeds, no speculative gap filling and no dynamic
facts (asm/dyn_*.json) are used.

Usage: ss_to_spider.py SS_JSON IMAGE BASE OUT_JSON TSVDIR GHIDRA_DIR [--module]
  GHIDRA_DIR: directory with the project's spider.py / export_ghidra.py
"""
import collections, json, os, pickle, subprocess, sys, time


def load_ss(path):
    text = open(path).read()
    main, _, _ = text.rpartition('{"address_taken"')
    return json.loads(main if main.strip() else text)


def main():
    ss_path, image, base, out_json, tsvdir, gh = sys.argv[1:7]
    module = '--module' in sys.argv
    base = int(base, 16)
    sys.path.insert(0, gh)
    import spider
    s = load_ss(ss_path)
    data = open(image, 'rb').read()

    sp = spider.Spider(spider.Image(data, base))
    owner = {a: f for a, f in s['owner']}
    code = set(s['code'])
    sp.code = {a: owner.get(a, a) for a in code}
    sp.spec = set()
    sp.funcs = set(s['funcs'])
    sp.firm_funcs = set(s['funcs'])
    sp.data = {}
    for a in s['data']:
        if a not in code:
            sp.data[a] = 'literal'
    # OS_WriteS strings: export_ghidra finds them from the SWIs itself
    sp.writes = {}
    sp.var_vals = collections.defaultdict(set)
    smc_vals = {w: v for w, v in s.get('smc_values', [])}
    for w, sites in s['smc']:
        sp.writes[w] = min(sites)
        sp.var_vals[w].update(smc_vals.get(w, []))
    sp.rtjumps = []
    sp.duff = sorted(s['follow'])
    sp.overrides = {a: 'CALL' for a in s['linked']}
    sp.calls = collections.defaultdict(set)
    sp.adr_targets = set()
    sp.xtables = []
    sp.problems = []
    sp.pc_vars = set()
    sp.img = None

    os.makedirs(os.path.dirname(os.path.abspath(out_json)), exist_ok=True)
    pickle.dump(sp, open(out_json + '.pickle', 'wb'))
    # export_ghidra.py uses the pickle as its cache only if it is newer than
    # spider.py
    now = time.time() + 1
    os.utime(out_json + '.pickle', (now, now))

    args = [sys.executable, os.path.join(gh, 'export_ghidra.py'), image, '%x' % base, out_json]
    if module:
        args.append('nobase')
    p = subprocess.run(args, capture_output=True, text=True)
    sys.stdout.write(p.stdout)
    if p.returncode:
        sys.stderr.write(p.stderr)
        sys.exit(p.returncode)

    j = json.load(open(out_json))
    dispatch = set(s['funcs']) | set(s['entries'])
    for site, targets in s['returns']:
        dispatch.update(targets)
    for site, targets in s['const_jumps']:
        dispatch.update(targets)
    dispatch.update(a + 8 for a in s['follow'])
    # gen_c puts each word in its owner's C function and leaves a function
    # through the dispatcher when the next word belongs to another one: those
    # words need entries too (a+8 covers the push-pc idiom's NV filler)
    for a in code:
        for nxt in (a + 4, a + 8):
            if nxt in code and owner.get(nxt, nxt) != owner.get(a, a):
                dispatch.add(nxt)
    j['ss_dispatch'] = sorted(a for a in dispatch if a in code)
    json.dump(j, open(out_json, 'w'), indent=0)

    os.makedirs(tsvdir, exist_ok=True)
    with open(os.path.join(tsvdir, 'functions.tsv'), 'w') as f:
        f.write('entry\tname\n')
        for a in sorted(s['funcs']):
            f.write('%08x\tsub_%x\n' % (a, a))
    print('superspider -> %s: %d code words, %d functions, %d data words, %d CALL overrides, '
          '%d duff sites, %d self-modified, %d dispatch leaders' % (
              out_json, len(code), len(sp.funcs), len(sp.data), len(sp.overrides), len(sp.duff),
              len(sp.writes), len(j['ss_dispatch'])))


if __name__ == '__main__':
    main()
