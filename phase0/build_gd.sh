#!/bin/sh
# Faithful Galactic Dan coverage build: mirror recomp/ and regenerate it
# WITHOUT --loops (the shipped build turns Duff's-device plotters into loops,
# which makes the recorded PC stream differ from the original program's).
set -e
B="$(dirname "$0")/build/gd"
G="$HOME/games/galactic dan"
mkdir -p "$B/recomp"
for f in Makefile game.c; do cp "$G/recomp/$f" "$B/recomp/"; done
for d in ghidra extracted asm; do ln -sfn "$G/$d" "$B/$d"; done
cd "$B/recomp"
python3 "$HOME/stuff/superspider/tools/gen_c.py" --img=../extracted/GalacticDan_8000,ff8 \
    --leaders=ss --header=galdan --covtag=G --json=../ghidra/galdan.json --tsvdir=../ghidra/out \
    --dyn=../asm/dyn_menu.json,../asm/dyn_game.json
make -j8 cov
