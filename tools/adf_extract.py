#!/usr/bin/env python3
"""Extract an ADFS disc image (D/E/F format .adf) into a directory, keeping
the RISC OS directory tree. Each file name gets a ',load-exec' suffix (both
eight hex digits) so the load/exec addresses - which say where an absolute
image loads and starts - survive. Uses ADFSlib (David Boddie, GPL-3).

Usage: adf_extract.py IMAGE.adf [OUT_DIR]   (OUT_DIR defaults to extracted)
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ADFSlib


def walk(files, path):
    for f in files:
        p = os.path.join(path, f.name)
        if hasattr(f, 'files'):
            os.makedirs(p, exist_ok=True)
            walk(f.files, p)
        else:
            os.makedirs(path, exist_ok=True)
            load = getattr(f, 'load_address', 0) & 0xffffffff
            exe = getattr(f, 'exec_address', 0) & 0xffffffff
            fname = p + ',%08x-%08x' % (load, exe)
            open(fname, 'wb').write(f.data)


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    img = sys.argv[1]
    out = sys.argv[2] if len(sys.argv) > 2 else 'extracted'
    disc = ADFSlib.ADFSdisc(open(img, 'rb'))
    print('disc_type', disc.disc_type, 'root', disc.root_name)
    walk(disc.files, out)
    print('extracted to', out)


if __name__ == '__main__':
    main()
