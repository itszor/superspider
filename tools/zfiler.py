#!/usr/bin/env python3
"""ZFiler: the Fourth Dimension's disc protection (Peter Gillett, 1991) -
its hidden files, revealed.

A ZFiler disc's directories hold empty placeholders (Chocks Away
Compendium: !Chocks.<160>.ChocksAway); the files themselves are in
sectors the free space map doesn't own, and the ZFiler module (on the disc,
RMLOADed by the loader) serves them. It claims FileV, ArgsV, BGetV, BPutV,
GBPBV and FindV, and looks a file up by its leaf name in a table it reads
from sectors no .adf keeps: sector 5, 256 bytes, of tracks 20-27, both
sides (a track's other sectors are the usual five of 1024). The module's
code is in the same kind of sector, on tracks 30-35: its init reads it over
its own body. ZFiler_Set 1 (&94701) turns it off once the loader has what it
needs.

The table (4K, little-endian words):

    +8    the number of files
    +32   a file each 32 bytes: its leaf name (12 bytes, CR terminated),
          its disc address (an offset in the .adf, sectors of 1024), load
          address, exec address, length, attributes

reveal(sectors_of(path), image, tree) writes the files into tree (adf_extract.py's
output) beside their placeholders, replacing them; weave.py calls it for a
.jfd or .hfe input, whose odd sectors survive.

Usage: zfiler.py IMAGE.jfd|.hfe OUTDIR     (OUTDIR: adf_extract.py's tree of it)
"""
import os
import struct
import sys

TOOLS = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, TOOLS)
import hfe   # noqa: E402
import jfd   # noqa: E402
import apd   # noqa: E402


def sectors_of(path):
    """{(track, side, R): data} for a .jfd, .hfe or .apd image's readable sectors"""
    out = {}
    if hfe.is_hfe(path) or apd.is_apd(path):
        for t, s, secs in (hfe if hfe.is_hfe(path) else apd).tracks(path):
            for (c, h, r), (n, data, good) in secs.items():
                if good:
                    out[(t, s, r, 128 << n)] = data
    else:
        for i, t in enumerate(jfd.tracks(jfd.load(path))):
            for r, n, ok, data in t or []:
                if ok and data is not None:
                    out[(i // 2, i % 2, r, 128 << n)] = data
    return out


def table(secs):
    """[(name, disc address, load, exec, length)], or None: not a ZFiler disc"""
    parts = [secs.get((20 + k // 2, k % 2, 5, 256)) for k in range(16)]
    if parts[0] is None:
        return None
    t = b''.join(p or bytes(256) for p in parts)
    n = struct.unpack_from('<I', t, 8)[0]
    if not 0 < n <= (len(t) - 32) // 32:
        return None
    files = []
    for k in range(n):
        o = 32 + 32 * k
        name = t[o:o + 12].split(b'\r')[0].split(b'\0')[0]
        if not name or any(c <= 32 or c == 127 for c in name):
            return None
        addr, load, exe, length = struct.unpack_from('<4I', t, o + 12)
        files.append((name.decode('latin-1'), addr, load, exe, length))
    return files


def placeholders(tree, names):
    """the directories in tree holding an empty file of one of names"""
    want = {n.lower() for n in names}
    return sorted({d for d, _, fs in os.walk(tree)
                   for f in fs if f.split(',')[0].lower() in want and os.path.getsize(os.path.join(d, f)) == 0})


def reveal(secs, image, tree):
    """the hidden files of a ZFiler disc into tree, beside their placeholders:
    [their paths], [] if it isn't one"""
    files = table(secs)
    if not files or any(a + n > len(image) for _, a, _, _, n in files):
        return []
    out = []
    for d in placeholders(tree, [f[0] for f in files]):
        for name, addr, load, exe, length in files:
            for f in os.listdir(d):
                if f.split(',')[0].lower() == name.lower() and os.path.isfile(os.path.join(d, f)):
                    os.remove(os.path.join(d, f))
            p = os.path.join(d, '%s,%08x-%08x' % (name, load, exe))
            with open(p, 'wb') as f:
                f.write(image[addr:addr + length])
            out.append(p)
    return out


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    path, tree = sys.argv[1:]
    secs = sectors_of(path)
    files = table(secs)
    if not files:
        sys.exit('%s: no ZFiler table' % path)
    for name, addr, load, exe, length in files:
        print('  %-12s &%06X  load &%08X exec &%08X  %d bytes' % (name, addr, load, exe, length))
    image = (hfe.decode if hfe.is_hfe(path) else jfd.decode)(path)[0]
    got = reveal(secs, image, tree)
    for p in got:
        print('->', os.path.relpath(p, tree))
    if not got:
        sys.exit('no placeholders for them in %s' % tree)


if __name__ == '__main__':
    main()
