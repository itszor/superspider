#!/usr/bin/env python3
"""JASPP's floppy images (.jfd, ADFFS's "JFDI" format) -> sector images.

A .jfd is gzipped (the JASPP archive's are; ADFFS also reads them plain).
Its header (little-endian words):

    +0   "JFDI"
    +4   the ADFFS version it needs (x100)
    +8   the uncompressed image's size
    +12  the disc's number (bits 0-15) and the set's size (bits 16-31)
    +16  the game's JASPP number (F1013401: game 10134, disc 01)
    +20  the image's version
    +24  the track table's offset    +28  the sector table's    +32  the data's
    +36  +40 +44  the same for the delta (changes written back): 0 if none
    +48  the title, 256 bytes, CR or 0 terminated

The track table has a word per track, interleaved by side (track 0 side 0,
track 0 side 1, ...), the order of an ADFS .adf. Each word is the offset of
the track's sectors in the sector table, or -1: an unformatted track. A
track's sectors are pairs of words, in the order they pass the head, ended
by -1:

    word 0  bits 0-1 N (the size: 128 << N), bit 5 a bad data CRC, bits
            8-15 R (the sector's ID), bits 16-23 the density (2: double),
            bits 24-31 where it is on the track (0-255)
    word 1  its data's offset in the data area, or -1: an ID with no data

A sector that isn't listed isn't on the disc: reading it is a "sector not
found" (copy protection checks for both that and the bad CRCs).

Usage: jfd.py IMAGE.jfd OUT.adf     (prints the geometry and the odd sectors)

is_jfd(path), load(path) and decode(path) are for weave.py.
"""
import collections
import gzip
import struct
import sys

BAD_CRC = 0x20


def load(path):
    """the image's bytes, uncompressed"""
    d = open(path, 'rb').read()
    return gzip.decompress(d) if d[:2] == b'\x1f\x8b' else d


def is_jfd(path):
    with open(path, 'rb') as f:
        head = f.read(4)
    if head[:2] == b'\x1f\x8b':
        try:
            with gzip.open(path) as g:
                head = g.read(4)
        except OSError:
            return False
    return head == b'JFDI'


def tracks(d):
    """[[(r, n, crc_ok, data or None), ...] or None for each track]"""
    if d[:4] != b'JFDI':
        raise ValueError('not a JFD image')
    w = lambda o: struct.unpack_from('<I', d, o)[0]
    tt, st, dt = w(24), w(28), w(32)
    out = []
    for o in range(tt, st, 4):
        t = w(o)
        if t == 0xFFFFFFFF:
            out.append(None)
            continue
        secs, p = [], st + t
        while w(p) != 0xFFFFFFFF:
            a, b = w(p), w(p + 4)
            p += 8
            n = a & 3
            data = None if b == 0xFFFFFFFF else d[dt + b:dt + b + (128 << n)]
            secs.append(((a >> 8) & 0xFF, n, not a & BAD_CRC, data))
        out.append(secs)
    return out


def title(d):
    return d[48:304].split(b'\0')[0].split(b'\r')[0].decode('latin-1')


def decode(path):
    """(flat image bytes, (sectors per track, sector size), odd sectors):
    80 cylinders, two sides, in the commonest layout (an .adf's); sectors
    not in it, or past it, are left out (zeros), and listed"""
    d = load(path)
    ts = tracks(d)
    layout = collections.Counter((len(t), t[0][1]) for t in ts if t)
    spt, n = max(layout, key=lambda k: (layout[k], k[0]))
    size = 128 << n
    img = bytearray(160 * spt * size)
    odd = []
    for i, t in enumerate(ts):
        for r, sn, ok, data in t or []:
            if sn != n or r >= spt or not ok or data is None or i >= 160:
                odd.append((i, r, 128 << sn, ok, data is not None))
            if data is not None and sn == n and r < spt and i < 160:
                p = (i * spt + r) * size
                img[p:p + size] = data
    return bytes(img), (spt, size), odd


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    img, (spt, size), odd = decode(sys.argv[1])
    print('%s: %d sectors of %d bytes a track' % (title(load(sys.argv[1])), spt, size))
    for i, r, sz, ok, has in odd:
        print('  track %d side %d sector %d: %d bytes%s%s' % (i // 2, i % 2, r, sz, '' if ok else ', bad CRC',
                                                              '' if has else ', no data'))
    open(sys.argv[2], 'wb').write(img)


if __name__ == '__main__':
    main()
