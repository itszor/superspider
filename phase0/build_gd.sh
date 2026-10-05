#!/bin/sh
# Faithful Galactic Dan coverage build: mirror recomp/ and regenerate it
# WITHOUT --loops (the shipped build turns Duff's-device plotters into loops,
# which makes the recorded PC stream differ from the original program's).
set -e
B="$(dirname "$0")/build/gd"
G="$HOME/games/galactic dan"
mkdir -p "$B/recomp"
for f in Makefile game.c gen_c.py; do cp "$G/recomp/$f" "$B/recomp/"; done
for d in ghidra extracted asm; do ln -sfn "$G/$d" "$B/$d"; done
cd "$B/recomp"
python3 gen_c.py
make -j8 cov
