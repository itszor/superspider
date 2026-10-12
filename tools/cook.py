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

    cook.py identify INPUT...           which recipes the inputs match, best first
    cook.py extract RECIPE_DIR INPUT... the recipe's discs from the inputs ->
                                        RECIPE_DIR/extracted/<disc>, merged into
                                        RECIPE_DIR/game (its "game_dirs")
    cook.py build INPUT... [-o EXE]     identify, then run the best recipe's
                                        "build" steps; copy its output to EXE
    cook.py index                       every recipe's fingerprints -> recipes.json

Recipes are looked for in $COOK_RECIPES (directories separated by ':'),
default ~/games/*. INPUT is a .zip (its members are examined) or a disc
image or archive: .adf (ADFS D/E/F, via adf_extract.py) or an ArcFS
archive (RISC OS filetype &DDC, recognised by its "Archive\0" header, via
arcfs.py; a zip member too). A "disc" in a recipe is then the archive's
contents.

recipe.json:
  name, title, platform
  inputs.containers       {file name: sha256} of known containers
  discs[]                 name, title, known_images [sha256], variant_images
                          [sha256] (other known dumps), key_files {path on the
                          disc: sha256}, game_dirs [directories copied to
                          game/], optional (true: not needed)
  build[]                 shell commands run in the recipe directory, in
                          order; "INPUTS" stands for the input files
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


def sha256(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for b in iter(lambda: f.read(1 << 20), b''):
            h.update(b)
    return h.hexdigest()


def recipes():
    dirs = os.environ.get('COOK_RECIPES')
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


def images_in(inputs, tmp):
    """every disc image in the inputs: (name, path, container sha256 or None)"""
    out = []
    for p in inputs:
        if zipfile.is_zipfile(p):
            ch = sha256(p)
            with zipfile.ZipFile(p) as z:
                for n in z.namelist():
                    if n.lower().endswith('.adf') or (not n.endswith('/') and z.open(n).read(8) == b'Archive\0'):
                        d = os.path.join(tmp, 'z%d' % len(out))
                        os.makedirs(d)
                        out.append((n, z.extract(n, d), ch))
        else:
            out.append((os.path.basename(p), p, None))
    return out


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
        self.sha = sha256(path)
        self.tree = os.path.join(tmp, 'x' + self.sha[:16])
        if not os.path.isdir(self.tree):
            tool = 'arcfs.py' if is_arcfs(path) else 'adf_extract.py'
            r = subprocess.run([sys.executable, '-I', os.path.join(TOOLS, tool), path, self.tree],
                               capture_output=True, text=True)
            self.clean = r.returncode == 0
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


def match(recipe, discs):
    """the best input disc for each of the recipe's discs, and the recipe's score
    (0..1: the fraction of required key files found)"""
    best, want, got = {}, 0, 0
    for disc in recipe['discs']:
        need = max(1, len(disc.get('key_files', {})))
        cands = [(d.score(disc), d) for d in discs]
        cands = [c for c in cands if c[0][0] > 0]
        if cands:
            s, d = max(cands, key=lambda c: c[0])
            best[disc['name']] = (s, d)
        if disc.get('optional'):
            continue
        want += need
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
                    (n, known, clean), d = best[disc['name']]
                    kf = len(disc.get('key_files', {}))
                    print('        %-6s <- %s (%s%s%s)' % (
                        disc['name'], d.name, '%d/%d key files' % (n, kf) if kf else 'by image',
                        ', known image' if known else '', '' if clean else ', extracted with errors'))
                elif not disc.get('optional'):
                    print('        %-6s missing: %s' % (disc['name'], disc['title']))
        if not ranked:
            print('no recipe matches these inputs')
    return ranked


def extract(rdir, inputs):
    r = json.load(open(os.path.join(rdir, 'recipe.json')))
    tmp = tempfile.mkdtemp()
    try:
        discs = [Disc(n, p, c, tmp) for n, p, c in images_in(inputs, tmp)]
        best, score = match(r, discs)
        for disc in r['discs']:
            full = disc['name'] in best and best[disc['name']][0][0] >= len(disc.get('key_files', {}))
            if not full:
                if disc.get('optional'):
                    continue
                sys.exit('cook: no complete dump of %s (%s) among the inputs' % (disc['name'], disc['title']))
            d = best[disc['name']][1]
            print('%s: %s' % (disc['name'], d.name))
            dst = os.path.join(rdir, 'extracted', disc['name'])
            shutil.rmtree(dst, ignore_errors=True)
            shutil.copytree(d.tree, dst)
        game = os.path.join(rdir, 'game')
        shutil.rmtree(game, ignore_errors=True)
        os.makedirs(game)
        for disc in r['discs']:
            for gd in disc.get('game_dirs', []):
                src = find_path(os.path.join(rdir, 'extracted', disc['name']), gd)
                if src:
                    shutil.copytree(src, os.path.join(game, os.path.basename(src)))
    finally:
        shutil.rmtree(tmp)


def build(inputs, out):
    tmp = tempfile.mkdtemp()
    try:
        ranked = identify(inputs, tmp)
    finally:
        shutil.rmtree(tmp)
    if not ranked or ranked[0][0] < 1:
        sys.exit('cook: no recipe has everything it needs in these inputs')
    _, _, rdir, r, _ = ranked[0]
    print('cooking %s in %s' % (r['name'], rdir))
    ins = ' '.join(shlex.quote(os.path.abspath(i)) for i in inputs)
    env = dict(os.environ, COOK=os.path.abspath(__file__))
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
            for h in disc.get('known_images', []) + disc.get('variant_images', []):
                idx['images'][h] = '%s/%s' % (r['name'], disc['name'])
            for rel, h in disc.get('key_files', {}).items():
                idx['key_files'].setdefault(h, []).append('%s/%s/%s' % (r['name'], disc['name'], rel))
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
