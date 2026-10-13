#!/usr/bin/env python3
"""PKWARE "imploded" zip members (method 6), which Python's zipfile can't read.

RISC OS zips made with SparkFS (Saloon Cars' TOSEC zip) use it. The format is
APPNOTE.TXT section 5.3: a 4K or 8K sliding window (flag bit 1), two or three
Shannon-Fano trees (flag bit 2: with a literal tree, matches are at least 3
long, otherwise 2), the trees themselves stored as run-lengths of code lengths.

    explode(data, size, flags) -> bytes
    read_member(zipfile_object, info) -> bytes (any method; implode here, CRC checked)
"""
import struct
import zlib


class _Bits:
    def __init__(self, data):
        self.data, self.pos, self.acc, self.n = data, 0, 0, 0

    def bits(self, k):
        """k bits, least significant first (as the stream holds them)"""
        while self.n < k:
            b = self.data[self.pos] if self.pos < len(self.data) else 0
            self.pos += 1
            self.acc |= b << self.n
            self.n += 8
        v = self.acc & ((1 << k) - 1)
        self.acc >>= k
        self.n -= k
        return v


def _tree(data, at, nvalues):
    """a stored Shannon-Fano tree at data[at:] -> ({(length, code): value}, next offset)"""
    nbytes = data[at] + 1
    lengths = []
    for b in data[at + 1:at + 1 + nbytes]:
        lengths += [(b & 15) + 1] * ((b >> 4) + 1)
    if len(lengths) != nvalues:
        raise ValueError('implode: a tree of %d values, not %d' % (len(lengths), nvalues))
    order = sorted(range(nvalues), key=lambda v: lengths[v])     # stable: by value within a length
    codes, code, inc, last = {}, 0, 0, 0
    for v in reversed(order):
        code += inc
        if lengths[v] != last:
            last = lengths[v]
            inc = 1 << (16 - last)
        codes[(last, code >> (16 - last))] = v
    return codes, at + 1 + nbytes


def _decode(bits, codes):
    # the codes' bits are stored reversed: the first read is the code's top bit
    c = 0
    for n in range(1, 17):
        c = (c << 1) | bits.bits(1)
        v = codes.get((n, c))
        if v is not None:
            return v
    raise ValueError('implode: bad code')


def explode(data, size, flags):
    big = bool(flags & 2)        # 8K window: 7 low distance bits, else 6
    lit = bool(flags & 4)        # a literal tree
    at = 0
    littree = None
    if lit:
        littree, at = _tree(data, at, 256)
    lentree, at = _tree(data, at, 64)
    disttree, at = _tree(data, at, 64)
    bits = _Bits(data[at:])
    low = 7 if big else 6
    minmatch = 3 if lit else 2
    out = bytearray()
    while len(out) < size:
        if bits.bits(1):
            out.append(_decode(bits, littree) if lit else bits.bits(8))
        else:
            d = bits.bits(low)
            d |= _decode(bits, disttree) << low
            n = _decode(bits, lentree)
            if n == 63:
                n += bits.bits(8)
            n += minmatch
            src = len(out) - d - 1
            for i in range(n):
                out.append(out[src + i] if src + i >= 0 else 0)
    return bytes(out[:size])


def read_member(z, info):
    """a zip member's bytes, imploded ones too"""
    if info.compress_type != 6:
        with z.open(info) as f:
            return f.read()
    fp = z.fp
    fp.seek(info.header_offset)
    h = fp.read(30)
    if h[:4] != b'PK\3\4':
        raise ValueError('implode: no local header for ' + info.filename)
    nlen, xlen = struct.unpack('<HH', h[26:30])
    fp.seek(info.header_offset + 30 + nlen + xlen)
    out = explode(fp.read(info.compress_size), info.file_size, info.flag_bits)
    if zlib.crc32(out) != info.CRC:
        raise ValueError('implode: CRC error in ' + info.filename)
    return out


if __name__ == '__main__':
    import sys
    import zipfile
    with zipfile.ZipFile(sys.argv[1]) as z:
        for i in z.infolist():
            if not i.is_dir():
                d = read_member(z, i)
                print('%-50s %d %d' % (i.filename, i.compress_type, len(d)))
