#!/usr/bin/env python3
"""Extract an ArcFS archive (RISC OS filetype &DDC, "Archive\\0" header)
into a directory, with ',load-exec' name suffixes like adf_extract.py's.

Usage: arcfs.py ARCHIVE OUT_DIR

Methods: &82 stored, &83 packed (RLE, &90 escape), &88 crunched (LZW,
Unix compress-style codes from 9 bits up to the entry's maximum, then RLE;
the last group's padding decodes as a few extra bytes, so the output stops
at the recorded length).
The CRC (ARC's CRC-16) is checked where the archive records one (it's 0
for ArcFS's crunched files).
"""
import os
import struct
import sys


def crc16(data):
    crc = 0
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = (crc >> 1) ^ 0xA001 if crc & 1 else crc >> 1
    return crc


def unrle(data, limit=None):
    out = bytearray()
    i = 0
    while i < len(data) and (limit is None or len(out) < limit):
        b = data[i]
        i += 1
        if b != 0x90:
            out.append(b)
            continue
        if i == len(data):
            break
        n = data[i]
        i += 1
        if n == 0:
            out.append(0x90)
        else:
            out.extend(out[-1:] * (n - 1))
    return bytes(out[:limit])


def unlzw(data, maxbits):
    """compress(1)-style LZW: codes LSB first, read n_bits bytes at a time;
    a width change or a clear code discards the rest of that group."""
    CLEAR = 256
    out = bytearray()
    prefix = [0] * (1 << maxbits)
    suffix = list(range(256)) + [0] * ((1 << maxbits) - 256)
    nbits = 9
    free = 257
    maxcode = (1 << nbits) - 1
    pos = 0                 # byte position of the current group
    bitoff = 0              # bit offset within it
    glen = 0                # its length in bits
    old = -1
    fin = 0

    def stringof(code):
        s = bytearray()
        while code >= 256:
            s.append(suffix[code])
            code = prefix[code]
        s.append(code)
        s.reverse()
        return s

    while True:
        if bitoff >= glen or free > maxcode:
            if free > maxcode and nbits < maxbits:
                nbits += 1
                maxcode = (1 << nbits) - 1 if nbits < maxbits else (1 << maxbits)
            pos += (glen + 7) // 8 if glen else 0
            if pos >= len(data):
                break
            group = data[pos:pos + nbits]
            glen = len(group) * 8
            glen -= glen % nbits
            bitoff = 0
            if glen < nbits:
                break
            gval = int.from_bytes(group, 'little')
        code = (gval >> bitoff) & ((1 << nbits) - 1)
        bitoff += nbits
        if code == CLEAR:
            prefix[:] = [0] * len(prefix)
            free = 257
            nbits = 9
            maxcode = (1 << nbits) - 1
            bitoff = glen       # next group, at the new width
            old = -1
            continue
        if old < 0:
            out.append(code)
            old = fin = code
            continue
        if code < free:
            s = stringof(code)
        else:                   # KwKwK
            s = stringof(old) + bytes([fin])
        out.extend(s)
        fin = s[0]
        if free < (1 << maxbits):
            prefix[free] = old
            suffix[free] = fin
            free += 1
        old = code
    return bytes(out)


def extract(path, outdir):
    d = open(path, 'rb').read()
    if d[:8] != b'Archive\0':
        raise SystemExit('not an ArcFS archive')
    hlen, dstart = struct.unpack_from('<2I', d, 8)
    o = 0x60
    stack = [outdir]
    ok = bad = 0
    while o < 0x60 + hlen:
        t = d[o]
        name = d[o + 1:o + 12].split(b'\0')[0].split(b'\r')[0].decode('latin1')
        ln, load, exe, attr, clen, info = struct.unpack_from('<6I', d, o + 12)
        o += 36
        if t == 0:
            stack.pop()
            continue
        if t == 1:
            continue
        p = os.path.join(stack[-1], name)
        if info >> 31:
            os.makedirs(p, exist_ok=True)
            stack.append(p)
            continue
        raw = d[dstart + info:dstart + info + clen]
        if t == 0x82:
            data = raw
        elif t == 0x83:
            data = unrle(raw)
        elif t == 0x88:
            data = unrle(unlzw(raw, (attr >> 8) & 0xff), ln)
        else:
            raise SystemExit('%s: method &%02x not supported' % (p, t))
        crc = attr >> 16
        good = len(data) == ln and (crc == 0 or crc16(data) == crc)
        if good:
            ok += 1
        else:
            bad += 1
            print('BAD %s: method &%02x length %d/%d crc %04x/%04x'
                  % (p, t, len(data), ln, crc16(data), crc))
        os.makedirs(stack[-1], exist_ok=True)
        open(p + ',%08x-%08x' % (load, exe), 'wb').write(data)
    print('%d files extracted, %d bad' % (ok, bad))
    return bad


if __name__ == '__main__':
    sys.exit(1 if extract(sys.argv[1], sys.argv[2]) else 0)
