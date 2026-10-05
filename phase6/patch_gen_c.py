#!/usr/bin/env python3
"""Patch a *copy* of a project's gen_c.py (phase 6 mirror builds only):
dispatch leaders come from SuperSpider's analysis ("ss_dispatch" in the
export JSON) instead of every classified code word (Lemmings) or nothing
beyond direct references (Galactic Dan), and Galactic Dan's dynamic facts
(asm/dyn_*.json, recorded by running the original) are not used.

Usage: patch_gen_c.py GEN_C_PY"""
import sys

p = sys.argv[1]
s = open(p).read()
n = 0
for old in ("        L = set(self.code)\n", "        L = set()\n"):
    if old in s:
        s = s.replace(old, "        L = set(self.j.get('ss_dispatch', []))   # phase 6: SuperSpider's leaders\n", 1)
        n += 1
assert n == 1, 'leader initialisation not found'
old = "    g.dyn = [os.path.join(HERE, '..', 'asm', f) for f in ('dyn_menu.json', 'dyn_game.json')]\n"
if old in s:
    s = s.replace(old, "    g.dyn = []                       # phase 6: no dynamic facts\n")
open(p, 'w').write(s)
print('patched', p)
