#!/usr/bin/env python3
"""Recipes: from a user's own copy of a game to a native executable.

A recipe is a game's recompilation repository (~/games/<name>) with a
recipe.json at its top: everything needed to rebuild the game from the
original discs, and no game data. The discs are recognised by content, so
any dump of the same release is found, whatever its file name or format:

  - the container (e.g. the TOSEC zip) by sha256: an exact match;
  - each disc image by sha256: a known dump (preferred when there are several);
  - the files on each disc by sha256 ("key_files": the ones the build
    depends on): a dump with different bytes elsewhere (another
    duplicator's copy, a played copy with a different high score file)
    still matches if its key files do. The score is the fraction found.

    weave.py identify INPUT...           which recipes the inputs match, best first
    weave.py extract RECIPE_DIR INPUT... the recipe's discs from the inputs ->
                                         RECIPE_DIR/extracted/<disc>, merged into
                                         RECIPE_DIR/game (its "game_dirs")
    weave.py build INPUT... [-o EXE]     identify, then run the best recipe's
                                         "build" steps; copy its output to EXE
    weave.py index                       every recipe's fingerprints -> recipes.json

Recipes are looked for in $WEAVE_RECIPES (directories separated by ':'),
default ~/games/*. INPUT is a .zip (its members are examined) or a disc
image or archive: .adf (ADFS D/E/F, via adf_extract.py), .hfe (an HxC
floppy image, decoded to sectors by hfe.py, then as an .adf), .jfd
(JASPP's ADFFS image, gzipped or not, decoded to sectors by jfd.py, then
as an .adf; from either, a ZFiler-protected disc's hidden files too, beside
their empty placeholders: zfiler.py), an ArcFS
archive (RISC OS filetype &DDC, recognised by its "Archive\0" header, via
arcfs.py) or a Spark archive (&DDC too, ARC's &1A header with the RISC OS
bit, via spark.py); a zip member too. A "disc" in a recipe is then the
archive's contents. (TOSEC names Spark archives ".zip", but zipfile tells
them apart.) A zip holding none of those is itself a disc, its files
plain (RISC OS zips' filetypes, the "ARC0" extra field, become ',load-exec'
suffixes; imploded members, as SparkFS wrote them, via implode.py); and
so is a directory (e.g. an emulator's HostFS copy of the
game). A plain disc's "image" fingerprint is the sha256 of its files'
paths and contents.

recipe.json:
  name, title, platform
  inputs.containers       {file name: sha256} of known containers
  discs[]                 name, title, known_images [sha256], variant_images
                          [sha256] (other known dumps), key_files {path on the
                          disc: sha256}, game_dirs [directories copied to
                          game/, merged with any of the same name from an
                          earlier disc; "$" copies the whole disc into game/],
                          optional (true: not needed), alternatives [discs:
                          other releases that serve as this one, each with
                          its own name, title, images, key_files and
                          game_dirs], raw (true: the image itself is
                          copied to extracted/<its name>.img too, for a
                          game that reads sectors no file holds; an .hfe
                          or .jfd input is copied as it is, to
                          extracted/<its name>.hfe or .jfd, keeping what a
                          flat image can't: sector sizes and CRC errors,
                          e.g. a protection track)
  (the disc or alternative matched is extracted to extracted/<its name>,
  so a build step can tell which one it has)
  build[]                 shell commands run in the recipe directory, in
                          order; "INPUTS" stands for the input files and
                          $WEAVE for this script
  output                  the executable the build makes (relative)
"""
import glob
import hashlib
import json
import os
import shlex
import shutil
import subprocess
import sys
import tempfile
import zipfile

TOOLS = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, TOOLS)
from spark import is_spark   # noqa: E402
import hfe                   # noqa: E402
import jfd                   # noqa: E402
import zfiler                # noqa: E402
from implode import read_member   # noqa: E402


def sha256(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for b in iter(lambda: f.read(1 << 20), b''):
            h.update(b)
    return h.hexdigest()


def recipes():
    dirs = os.environ.get('WEAVE_RECIPES')
    pats = dirs.split(':') if dirs else [os.path.expanduser('~/games/*')]
    out = []
    for p in pats:
        for d in sorted(glob.glob(p)):
            f = os.path.join(d, 'recipe.json')
            if os.path.isfile(f):
                out.append((d, json.load(open(f))))
    return out


# --- the inputs: containers and disc images
def is_arcfs(path):
    with open(path, 'rb') as f:
        return f.read(8) == b'Archive\0'


def is_archive(head):
    """an ArcFS or Spark archive, from its first bytes"""
    return head == b'Archive\0' or (len(head) > 1 and head[0] == 0x1a and head[1] in (0x81, 0x82, 0x83, 0x88, 0x89, 0xff))


# RISC OS zip tools sometimes declare their "ARC0" extra field longer
# than it is, which zipfile rejects: the field is read here, so let it be.
_decode_extra = zipfile.ZipInfo._decodeExtra


def _lenient_extra(self, *a):
    try:
        _decode_extra(self, *a)
    except zipfile.BadZipFile:
        pass


zipfile.ZipInfo._decodeExtra = _lenient_extra


def riscos_suffix(info):
    """',llllllll-eeeeeeee' from a zip member's RISC OS extra field ("ARC0"), or ''"""
    x = info.extra
    while len(x) >= 4:
        tag, size = int.from_bytes(x[0:2], 'little'), int.from_bytes(x[2:4], 'little')
        body = x[4:4 + size]
        if tag == 0x4341 and body[:4] == b'ARC0' and len(body) >= 12:
            return ',%08x-%08x' % (int.from_bytes(body[4:8], 'little'), int.from_bytes(body[8:12], 'little'))
        x = x[4 + size:]
    return ''


def member_head(z, n):
    i = z.getinfo(n)
    if i.compress_type == 6:                    # imploded (SparkFS): zipfile can't open it
        return read_member(z, i)[:8]
    with z.open(i) as f:
        return f.read(8)


def unzip_plain(z, dst):
    """a zip of plain files -> dst, with RISC OS types as name suffixes"""
    for info in z.infolist():
        name = info.filename
        if not info.flag_bits & 0x800:             # not UTF-8: RISC OS names are Latin-1
            name = name.encode('cp437').decode('latin-1')
        parts = [q for q in name.split('/') if q not in ('', '.', '..')]
        if not parts:
            continue
        p = os.path.join(dst, *parts)
        if info.is_dir():
            os.makedirs(p, exist_ok=True)
            continue
        os.makedirs(os.path.dirname(p), exist_ok=True)
        suf = riscos_suffix(info)
        with open(p + (suf if ',' not in parts[-1] else ''), 'wb') as o:
            o.write(read_member(z, info))


def is_zip(path):
    """a zip file: zipfile.is_zipfile only looks for an end record, which a
    disc image may hold in its free space (Chocks Away's 2000 release has a
    zip's left over there)"""
    with open(path, 'rb') as f:
        return f.read(4) in (b'PK\3\4', b'PK\5\6') and zipfile.is_zipfile(path)


def images_in(inputs, tmp):
    """every disc image in the inputs: (name, path, container sha256 or None);
    path is a directory for a plain disc"""
    out = []
    for p in inputs:
        if os.path.isdir(p):
            out.append((os.path.basename(os.path.normpath(p)), p, None))
        elif is_zip(p):
            ch = sha256(p)
            with zipfile.ZipFile(p) as z:
                n0 = len(out)
                for n in z.namelist():
                    if n.lower().endswith(('.adf', '.hfe', '.jfd')) or (not n.endswith('/') and is_archive(member_head(z, n))):
                        d = os.path.join(tmp, 'z%d' % len(out))
                        os.makedirs(d)
                        out.append((n, z.extract(n, d), ch))
                if len(out) == n0:                  # no discs in it: the zip is one
                    d = os.path.join(tmp, 'p%d' % len(out))
                    unzip_plain(z, d)
                    out.append((os.path.basename(p), d, ch))
        else:
            out.append((os.path.basename(p), p, None))
    return out


def tree_sha(top):
    """a directory's fingerprint: its files' relative paths and contents"""
    h = hashlib.sha256()
    for d, dirs, files in sorted(os.walk(top)):
        dirs.sort()
        for f in sorted(files):
            p = os.path.join(d, f)
            h.update(os.path.relpath(p, top).encode() + b'\0' + sha256(p).encode())
    return h.hexdigest()


def find(d, name):
    """a RISC OS file in a host directory: any case, any ,load-exec suffix"""
    try:
        for f in os.listdir(d):
            if f.split(',')[0].lower() == name.lower():
                return os.path.join(d, f)
    except (FileNotFoundError, NotADirectoryError):
        pass
    return None


def find_path(tree, rel):
    d = tree
    for part in rel.split('/'):
        d = find(d, part)
        if d is None:
            return None
    return d


class Disc:
    """one input disc image, extracted"""
    def __init__(self, name, path, container, tmp):
        self.name, self.path, self.container = name, path, container
        if os.path.isdir(path):                     # a plain disc: its files
            self.sha, self.tree, self.clean, self._files = tree_sha(path), path, True, {}
            self.raw_ext = None
            return
        self.raw_ext = '.hfe' if hfe.is_hfe(path) else '.jfd' if jfd.is_jfd(path) else '.img'
        img = path
        if self.raw_ext != '.img':                  # its sectors, as a flat image
            data = (hfe.decode if self.raw_ext == '.hfe' else jfd.decode)(path)[0]
            self.sha = hashlib.sha256(data).hexdigest()
            img = os.path.join(tmp, 'h' + self.sha[:16] + '.adf')
            with open(img, 'wb') as f:
                f.write(data)
        else:
            self.sha = sha256(path)
        self.tree = os.path.join(tmp, 'x' + self.sha[:16])
        if not os.path.isdir(self.tree):
            tool = 'arcfs.py' if is_arcfs(path) else 'spark.py' if is_spark(path) else 'adf_extract.py'
            r = subprocess.run([sys.executable, '-I', os.path.join(TOOLS, tool), img, self.tree],
                               capture_output=True, text=True)
            self.clean = r.returncode == 0
            if self.raw_ext != '.img':              # a ZFiler disc's hidden files
                zfiler.reveal(zfiler.sectors_of(path), data, self.tree)
        else:
            self.clean = True
        self._files = {}

    def file_sha(self, rel):
        if rel not in self._files:
            p = find_path(self.tree, rel)
            self._files[rel] = sha256(p) if p and os.path.isfile(p) else None
        return self._files[rel]

    def score(self, disc):
        """(key files found, known image, clean extraction) for a recipe's disc"""
        kf = disc.get('key_files', {})
        n = sum(self.file_sha(rel) == h for rel, h in kf.items())
        known = self.sha in disc.get('known_images', [])
        if not kf:
            n = 1 if known or self.sha in disc.get('variant_images', []) else 0
        return (n, known, self.clean)


def forms(disc):
    """a recipe's disc and its alternatives"""
    return [disc] + disc.get('alternatives', [])


def match(recipe, discs):
    """the best input disc for each of the recipe's discs - (score, input disc,
    the form it matched: the disc or one of its alternatives) - and the
    recipe's score (0..1: the fraction of required key files found)"""
    best, want, got = {}, 0, 0
    for disc in recipe['discs']:
        cands = []
        for form in forms(disc):
            need = max(1, len(form.get('key_files', {})))
            cands += [((s[0] / need,) + s, d, form) for d in discs
                      for s in [d.score(form)] if s[0] > 0]
        if cands:
            c = max(cands, key=lambda c: c[0])
            best[disc['name']] = (c[0][1:], c[1], c[2])
        if disc.get('optional'):
            continue
        form = best[disc['name']][2] if disc['name'] in best else disc
        want += max(1, len(form.get('key_files', {})))
        got += best[disc['name']][0][0] if disc['name'] in best else 0
    return best, (got / want if want else 0)


def identify(inputs, tmp, quiet=False):
    discs = [Disc(n, p, c, tmp) for n, p, c in images_in(inputs, tmp)]
    containers = {d.container for d in discs if d.container}
    ranked = []
    for rdir, r in recipes():
        best, score = match(r, discs)
        exact = bool(containers & set(r.get('inputs', {}).get('containers', {}).values()))
        if score > 0:
            ranked.append((score, exact, rdir, r, best))
    ranked.sort(key=lambda x: (x[0], x[1]), reverse=True)
    if not quiet:
        for score, exact, rdir, r, best in ranked:
            print('%3d%%  %s  (%s)%s' % (round(score * 100), r['name'], r['title'], '  [known container]' if exact else ''))
            for disc in r['discs']:
                if disc['name'] in best:
                    (n, known, clean), d, form = best[disc['name']]
                    kf = len(form.get('key_files', {}))
                    print('        %-6s <- %s (%s%s%s%s)' % (
                        disc['name'], d.name, '' if form is disc else 'as %s: ' % form['name'],
                        '%d/%d key files' % (n, kf) if kf else 'by image',
                        ', known image' if known else '', '' if clean else ', extracted with errors'))
                elif not disc.get('optional'):
                    print('        %-6s missing: %s' % (disc['name'], disc['title']))
        if not ranked:
            print('no recipe matches these inputs')
    return ranked


def merge_tree(src, dst):
    """copy src over dst: a file replaces one of the same RISC OS name there,
    whatever their ,load-exec suffixes (a later disc's copy of a file wins)"""
    os.makedirs(dst, exist_ok=True)
    for f in os.listdir(src):
        s, base = os.path.join(src, f), f.split(',')[0].lower()
        if os.path.isdir(s):
            merge_tree(s, os.path.join(dst, f))
            continue
        for old in os.listdir(dst):
            if old.split(',')[0].lower() == base and os.path.isfile(os.path.join(dst, old)):
                os.remove(os.path.join(dst, old))
        shutil.copy2(s, os.path.join(dst, f))


def extract(rdir, inputs):
    r = json.load(open(os.path.join(rdir, 'recipe.json')))
    tmp = tempfile.mkdtemp()
    try:
        discs = [Disc(n, p, c, tmp) for n, p, c in images_in(inputs, tmp)]
        best, score = match(r, discs)
        got = {}
        for disc in r['discs']:
            for form in forms(disc):
                shutil.rmtree(os.path.join(rdir, 'extracted', form['name']), ignore_errors=True)
                for ext in ('.img', '.hfe', '.jfd'):
                    if os.path.isfile(os.path.join(rdir, 'extracted', form['name'] + ext)):
                        os.remove(os.path.join(rdir, 'extracted', form['name'] + ext))
            full = False
            if disc['name'] in best:
                (n, _, _), d, form = best[disc['name']]
                full = n >= len(form.get('key_files', {}))
            if not full:
                if disc.get('optional'):
                    continue
                sys.exit('weave: no complete dump of %s (%s) among the inputs' % (disc['name'], disc['title']))
            print('%s: %s%s' % (disc['name'], d.name, '' if form is disc else ' (as %s)' % form['name']))
            shutil.copytree(d.tree, os.path.join(rdir, 'extracted', form['name']))
            if form.get('raw') and not os.path.isdir(d.path):
                shutil.copy(d.path, os.path.join(rdir, 'extracted', form['name'] + d.raw_ext))
            got[disc['name']] = form
        game = os.path.join(rdir, 'game')
        shutil.rmtree(game, ignore_errors=True)
        os.makedirs(game)
        for disc in r['discs']:
            form = got.get(disc['name'], {})
            for gd in form.get('game_dirs', []):
                tree = os.path.join(rdir, 'extracted', form['name'])
                if gd == '$':               # the whole disc, at the top of game/
                    shutil.copytree(tree, game, dirs_exist_ok=True)
                    continue
                src = find_path(tree, gd)
                if src:                     # discs may share an application
                    merge_tree(src, os.path.join(game, os.path.basename(src)))
    finally:
        shutil.rmtree(tmp)


def build(inputs, out):
    tmp = tempfile.mkdtemp()
    try:
        ranked = identify(inputs, tmp)
    finally:
        shutil.rmtree(tmp)
    if not ranked or ranked[0][0] < 1:
        sys.exit('weave: no recipe has everything it needs in these inputs')
    _, _, rdir, r, _ = ranked[0]
    print('weaving %s in %s' % (r['name'], rdir))
    ins = ' '.join(shlex.quote(os.path.abspath(i)) for i in inputs)
    env = dict(os.environ, WEAVE=os.path.abspath(__file__))
    for step in r['build']:
        cmd = step.replace('INPUTS', ins)
        print('+', cmd)
        subprocess.run(cmd, shell=True, cwd=rdir, check=True, env=env)
    exe = os.path.join(rdir, r['output'])
    print('built %s' % exe)
    if out:
        shutil.copy(exe, out)
        print('copied to %s' % out)


def index():
    idx = {'containers': {}, 'images': {}, 'key_files': {}}
    for rdir, r in recipes():
        for n, h in r.get('inputs', {}).get('containers', {}).items():
            idx['containers'][h] = r['name']
        for disc in r['discs']:
            for form in forms(disc):
                for h in form.get('known_images', []) + form.get('variant_images', []):
                    idx['images'][h] = '%s/%s' % (r['name'], form['name'])
                for rel, h in form.get('key_files', {}).items():
                    idx['key_files'].setdefault(h, []).append('%s/%s/%s' % (r['name'], form['name'], rel))
    json.dump(idx, open('recipes.json', 'w'), indent=1, sort_keys=True)
    print('recipes.json: %d containers, %d images, %d key files' % (
        len(idx['containers']), len(idx['images']), len(idx['key_files'])))


if __name__ == '__main__':
    a = sys.argv[1:]
    if not a:
        sys.exit(__doc__)
    if a[0] == 'identify' and len(a) > 1:
        t = tempfile.mkdtemp()
        try:
            identify(a[1:], t)
        finally:
            shutil.rmtree(t)
    elif a[0] == 'extract' and len(a) > 2:
        extract(a[1], a[2:])
    elif a[0] == 'build' and len(a) > 1:
        out = None
        if '-o' in a:
            k = a.index('-o')
            out = a[k + 1]
            a = a[:k] + a[k + 2:]
        build(a[1:], out)
    elif a[0] == 'index':
        index()
    else:
        sys.exit(__doc__)
