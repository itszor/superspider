#!/bin/bash
# Phase 6 mirror builds: both recompilations regenerated from SuperSpider's
# analysis instead of the projects' spider + Ghidra + hand seeds. Everything
# is written under phase6/build/; the game repositories are only read. The
# builds link libroger (~/stuff/libroger, or $ROGER), as the projects do.
set -e
P6="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$P6")"
SS="$ROOT/_build/default/bin/main.exe"
B="$P6/build"
(cd "$ROOT" && dune build)

# --- Galactic Dan --------------------------------------------------------
G="$HOME/games/galactic dan"
D="$B/gd"
mkdir -p "$D/recomp" "$D/ghidra/out"
for f in Makefile game.c gen_c.py; do cp "$G/recomp/$f" "$D/recomp/"; done
cp "$G"/ghidra/*.py "$D/ghidra/"
ln -sfn "$G/extracted" "$D/extracted"
: > "$D/ghidra/out/ghidra_only_code.txt"
python3 "$P6/patch_gen_c.py" "$D/recomp/gen_c.py"
IMG="$G/extracted/GalacticDan_8000,ff8"
"$SS" s1b "$IMG" 8000 -o "$D/ss.json"
python3 "$P6/ss_to_spider.py" "$D/ss.json" "$IMG" 8000 "$D/ghidra/galdan.json" "$D/ghidra/out" "$D/ghidra"
(cd "$D/recomp" && rm -rf gen && python3 gen_c.py && make -j8 cov)

# --- Lemmings (LemProg, LemBoot, musmod2) ---------------------------------
L="$HOME/games/lemmings"
D="$B/lem"
mkdir -p "$D/recomp" "$D/ghidra/out"
for f in Makefile game.c gen_c.py; do cp "$L/recomp/$f" "$D/recomp/"; done
cp "$L"/ghidra/*.py "$D/ghidra/"
ln -sfn "$L/extracted" "$D/extracted"
ln -sfn "$L/extracted_decompressed" "$D/extracted_decompressed"
python3 "$P6/patch_gen_c.py" "$D/recomp/gen_c.py"
run() {   # name image base [--module]
  "$SS" s1b "$2" "$3" ${4:+$4} -o "$D/ss_$1.json"
  python3 "$P6/ss_to_spider.py" "$D/ss_$1.json" "$2" "$3" "$D/ghidra/$1.json" "$D/ghidra/out/$1" "$D/ghidra" $4
}
run lemprog "$L/extracted_decompressed/LemProg.bin" 8000
run lemboot "$L/extracted/!LEMMINGS/LemBoot,fffff843-00000000" 8000
run musmod "$L/extracted/!LEMMINGS/musmod2,fffffa43-00000000" 1800000 --module
(cd "$D/recomp" && rm -rf gen genboot genmus && make regen && make -j8 cov)
echo "built: $B/gd/recomp/galdan-cov $B/lem/recomp/lemmings-cov"
