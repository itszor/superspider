#!/usr/bin/env python3
"""Hand-review helper: disassemble around addresses of an image.
Usage: show.py <image> <addr>[:before[:after]] ...   (marks: C=B2 code, x=executed, 0=B0_auto)"""
import json, os, sys, capstone
HERE = os.path.dirname(os.path.abspath(__file__))
name = sys.argv[1]
b = json.load(open(os.path.join(HERE, 'data', name + '.json')))
t = json.load(open(os.path.join(HERE, 'data', name + '.truth.json')))
E = {int(a, 16) for a in t['executed']}; B0 = set(b['B0_auto']); B2 = set(b['B2'])
data = open(b['image'], 'rb').read(); base = b['base']
md = capstone.Cs(capstone.CS_ARCH_ARM, capstone.CS_MODE_ARM)
for arg in sys.argv[2:]:
    f = arg.split(':'); a = int(f[0], 16)
    bef = int(f[1]) if len(f) > 1 else 6; aft = int(f[2]) if len(f) > 2 else 3
    for x in range(a - 4 * bef, a + 4 * (aft + 1), 4):
        o = x - base
        if not 0 <= o <= len(data) - 4: continue
        w = int.from_bytes(data[o:o + 4], 'little')
        d = list(md.disasm(data[o:o + 4], x))
        txt = '%s %s' % (d[0].mnemonic, d[0].op_str) if d else '.word'
        if w >> 28 == 15: txt = '(NV) ' + txt
        m = ('C' if x in B2 else '.') + ('x' if x in E else '.') + ('0' if x in B0 else '.')
        print('%s %08x %s %08x  %s' % ('>' if x == a else ' ', x, m, w, txt))
    print()
