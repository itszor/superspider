#!/usr/bin/env python3
"""Arculator's protected disc images (.apd, "APDX0001") -> sector images.

An .apd is gzipped. After the 8-byte magic come 166 entries of three
little-endian words, one per track side, interleaved by side (track 0 side
0, track 0 side 1, ...): the lengths in bits of the track's single-density
(FM), double-density (MFM) and high-density (MFM) cell streams. Then each
track's streams, in that order, each padded to a whole byte, most
significant bit first. Most tracks have only the DD stream; a stream of 0
bits isn't there (Arculator's own .log lists what the dump found).

The DD stream is decoded with hfe.py's MFM decoder (it wants each byte
least significant bit first) and laid out as hfe.py lays out an .hfe: the
commonest geometry, tracks past the last formatted one dropped. Sectors in
any other layout (copy protection: Magic Pockets' track 79 side 0, 512-byte
sectors numbered from 240 with bad CRCs) are reported, not kept.

Usage: apd.py IMAGE.apd OUT.img      (prints the geometry and any odd sectors)

is_apd(path), tracks(path) and decode(path) are for weave.py.
"""
import collections
import gzip
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import hfe                          # noqa: E402

MAGIC = b'APDX0001'
NTRACKS = 166
REVERSE = bytes(int(format(b, '08b')[::-1], 2) for b in range(256))


def is_apd(path):
    with open(path, 'rb') as f:
        head = f.read(8)
    if head[:2] == b'\x1f\x8b':
        try:
            with gzip.open(path) as g:
                head = g.read(8)
        except OSError:
            return False
    return head == MAGIC


def load(path):
    d = open(path, 'rb').read()
    return gzip.decompress(d) if d[:2] == b'\x1f\x8b' else d


def streams(d):
    """[(sd, dd, hd)] raw bytes of each track side's streams, MSB first"""
    if d[:8] != MAGIC:
        raise ValueError('not an APD image')
    p = 8 + 12 * NTRACKS
    out = []
    for i in range(NTRACKS):
        bits = struct.unpack_from('<III', d, 8 + 12 * i)
        s = []
        for b in bits:
            n = (b + 7) // 8
            s.append(d[p:p + n])
            p += n
        out.append(tuple(s))
    return out


def tracks(path):
    """[(track, side, its sectors)] as hfe.tracks: {(C, H, R): (N, data, good)}"""
    return [(i // 2, i % 2, hfe.sectors(dd.translate(REVERSE)) if dd else {})
            for i, (_, dd, _) in enumerate(streams(load(path)))]


def decode(path):
    """(the sector image, its geometry (tracks, sides, sectors, size, first),
    [odd sectors as (track, side, sector, size, good)], [missing sectors as
    (track, side, sector)])"""
    ts = tracks(path)
    layouts = collections.Counter()
    for t, s, secs in ts:
        if secs:
            rs = sorted(r for _, _, r in secs)
            layouts[(len(rs), secs[min(secs)][0], rs[0])] += 1
    if not layouts:
        raise ValueError('%s: no MFM sectors found' % path)
    (nsec, n, first), _ = layouts.most_common(1)[0]
    size = 128 << n
    last = max(t for t, s, secs in ts if secs)
    img = bytearray()
    odd, missing = [], []
    for t, s, secs in ts:
        if t > last:
            continue
        byr = {r: v for (c, h, r), v in secs.items()}
        for r, v in sorted(byr.items()):
            if v[0] != n or not first <= r < first + nsec or not v[2]:
                odd.append((t, s, r, 128 << v[0], v[2]))
        for r in range(first, first + nsec):
            v = byr.get(r)
            if v is None or v[0] != n:
                missing.append((t, s, r))
            img += v[1] if v and v[0] == n else bytes(size)
    return bytes(img), (last + 1, 2, nsec, size, first), odd, missing


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    img, (nt, ns, nsec, size, first), odd, missing = decode(sys.argv[1])
    open(sys.argv[2], 'wb').write(img)
    print('%d tracks, %d sides, %d x %d-byte sectors from %d: %d bytes' % (nt, ns, nsec, size, first, len(img)))
    for t, s, r, sz, good in odd:
        print('odd: track %d side %d sector %d, %d bytes%s' % (t, s, r, sz, '' if good else ', bad CRC'))
    for t, s, r in missing:
        print('missing: track %d side %d sector %d' % (t, s, r))


if __name__ == '__main__':
    main()
