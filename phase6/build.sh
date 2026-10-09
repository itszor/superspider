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
mkdir -p "$D/recomp"
for f in Makefile game.c; do cp "$G/recomp/$f" "$D/recomp/"; done
ln -sfn "$G/extracted" "$D/extracted"
IMG="$G/extracted/GalacticDan_8000,ff8"
# no roots: SuperSpider's analysis alone. --leaders=dispatch: dispatch
# leaders from the analysis only (the dynamic facts recorded by running the
# original are not used).
"$SS" analyse "$IMG" 8000 --full -o "$D/galdan.json"
(cd "$D/recomp" && rm -rf gen && "$SS" gen "$IMG" 8000 ../galdan.json --c gen --leaders=dispatch --header=galdan \
    --covtag=G && make -j8 cov)

# --- Lemmings (LemProg, LemBoot, musmod2) ---------------------------------
L="$HOME/games/lemmings"
D="$B/lem"
mkdir -p "$D/recomp"
for f in Makefile game.c; do cp "$L/recomp/$f" "$D/recomp/"; done
ln -sfn "$L/extracted" "$D/extracted"
ln -sfn "$L/extracted_decompressed" "$D/extracted_decompressed"
run() {   # name image base [--module]
  "$SS" analyse "$2" "$3" ${4:+$4} --full -o "$D/$1.json"
}
run lemprog "$L/extracted_decompressed/LemProg.bin" 8000
run lemboot "$L/extracted/!LEMMINGS/LemBoot,fffff843-00000000" 8000
run musmod "$L/extracted/!LEMMINGS/musmod2,fffffa43-00000000" 1800000 --module
gen() {   # name image base out [C options]
  local n=$1 i=$2 b=$3 o=$4; shift 4
  (cd "$D/recomp" && "$SS" gen "$i" "$b" ../$n.json --c $o --leaders=dispatch "$@")
}
(cd "$D/recomp" && rm -rf gen genboot genmus)
gen lemprog "$L/extracted_decompressed/LemProg.bin" 8000 gen
gen lemboot "$L/extracted/!LEMMINGS/LemBoot,fffff843-00000000" 8000 genboot \
    --prefix=B --tabprefix=recompB --pcbias --files=2 --covtag=B
gen musmod "$L/extracted/!LEMMINGS/musmod2,fffffa43-00000000" 1800000 genmus \
    --prefix=M --tabprefix=recompM --files=2
(cd "$D/recomp" && make -j8 cov)
echo "built: $B/gd/recomp/galdan-cov $B/lem/recomp/lemmings-cov"
