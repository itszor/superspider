#!/usr/bin/env python3
"""HxC Floppy Emulator images (.hfe, v1 "HXCPICFE") -> sector images.

An HFE file holds each track's raw cell stream (MFM here: clock and data
bits interleaved, each byte least significant bit first), side 0 and side 1
in alternate 256-byte halves of 512-byte blocks. This decodes the IBM-style
MFM records on it - ID address marks (A1 A1 A1 FE C H R N CRC) and data
address marks (A1 A1 A1 FB/F8 data CRC) - and lays the sectors out as a
flat image, tracks interleaved by side (track 0 side 0, track 0 side 1,
track 1 side 0, ...), the order of an ADFS D/E/F .adf. The geometry
(sectors per track, sector size, first sector number) is the commonest one
on the disc; tracks past the last formatted one are dropped.

Usage: hfe.py IMAGE.hfe OUT.img      (prints the geometry and any bad sectors)

is_hfe(path) and decode(path) are for weave.py.
"""
import collections
import struct
import sys

SYNC = 0x4489                       # A1 with a missing clock bit, as cells


def is_hfe(path):
    with open(path, 'rb') as f:
        return f.read(8) == b'HXCPICFE'


def crc16(data, crc=0xFFFF):
    for b in data:
        crc ^= b << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021 if crc & 0x8000 else crc << 1) & 0xFFFF
    return crc


def cells(raw):
    """the track's cell stream as a string of '0'/'1' (LSB of each byte first)"""
    return ''.join(format(b, '08b')[::-1] for b in raw)


def read_bytes(bits, pos, n):
    """n bytes of MFM data from the cell stream at pos (each data bit is the
    second cell of a pair)"""
    out = bytearray()
    for k in range(n):
        cell = bits[pos + 16 * k: pos + 16 * k + 16]
        if len(cell) < 16:
            return None
        out.append(int(cell[1::2], 2))
    return bytes(out)


def sectors(raw):
    """the sectors on one side of a track: {(C, H, R): (N, data, good)}"""
    bits = cells(raw)
    bits += bits[:20000]            # a record may straddle the index
    syncs = format(SYNC, '016b') * 3
    out = {}
    pending = None                  # the last ID record seen: (C, H, R, N, its end)
    pos = bits.find(syncs)
    while pos >= 0:
        p = pos + 48
        mark = read_bytes(bits, p, 1)
        if mark is None:
            break
        if mark[0] == 0xFE:
            rec = read_bytes(bits, p, 7)
            if rec and crc16(b'\xa1\xa1\xa1' + rec[:5]) == struct.unpack('>H', rec[5:7])[0]:
                pending = (rec[1], rec[2], rec[3], rec[4] & 3, p + 16 * 7)
            p += 16 * 7
        elif mark[0] in (0xFB, 0xF8) and pending and p - pending[4] < 16 * 64:
            c, h, r, n = pending[:4]
            size = 128 << n
            rec = read_bytes(bits, p, 1 + size + 2)
            if rec:
                good = crc16(b'\xa1\xa1\xa1' + rec[:1 + size]) == struct.unpack('>H', rec[-2:])[0]
                if good or (c, h, r) not in out:
                    out[(c, h, r)] = (n, rec[1:1 + size], good)
                p += 16 * len(rec)
            pending = None
        else:
            p += 16
        pos = bits.find(syncs, p)
    return out


def tracks(path):
    """[(track, side, its sectors)] for every track side in the file"""
    d = open(path, 'rb').read()
    if d[:8] != b'HXCPICFE':
        raise ValueError('%s: not an HFE (v1) image' % path)
    ntracks, nsides, enc = d[9], d[10], d[11]
    if enc not in (0, 0xFF):        # ISOIBM_MFM (0xFF: unset, taken as MFM)
        raise ValueError('%s: track encoding %d is not MFM' % (path, enc))
    lut = struct.unpack('<H', d[18:20])[0] * 512
    out = []
    for t in range(ntracks):
        off, length = struct.unpack('<HH', d[lut + 4 * t: lut + 4 * t + 4])
        off *= 512
        side = [bytearray(), bytearray()]
        for b in range(0, length, 512):
            blk = d[off + b: off + b + 512]
            n = min(256, (length - b) // 2)
            side[0] += blk[:n]
            side[1] += blk[256:256 + n]
        for s in range(nsides):
            out.append((t, s, sectors(bytes(side[s]))))
    return out


def decode(path):
    """(the sector image, its geometry (tracks, sides, sectors, size, first),
    [bad or missing sectors as (track, side, sector)])"""
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
    nsides = max(s for _, s, _ in ts) + 1
    last = max(t for t, s, secs in ts if secs)
    img = bytearray()
    bad = []
    for t, s, secs in ts:
        if t > last:
            continue
        byr = {r: v for (c, h, r), v in secs.items()}
        for r in range(first, first + nsec):
            v = byr.get(r)
            if v is None or v[0] != n or not v[2]:
                bad.append((t, s, r))
            img += v[1] if v and v[0] == n else bytes(size)
    return bytes(img), (last + 1, nsides, nsec, size, first), bad


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    img, (nt, ns, nsec, size, first), bad = decode(sys.argv[1])
    open(sys.argv[2], 'wb').write(img)
    print('%d tracks, %d sides, %d x %d-byte sectors from %d: %d bytes' % (nt, ns, nsec, size, first, len(img)))
    for t, s, r in bad:
        print('bad or missing: track %d side %d sector %d' % (t, s, r))
    if bad:
        sys.exit(1)


if __name__ == '__main__':
    main()
