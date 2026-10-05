#!/usr/bin/env python3
"""Run a coverage-instrumented recompiled game (make cov) with a scripted
input session, collecting cov.out and screenshots in an output directory.

Sessions are defined in SESSIONS below as lists of (ms, action, args...).
'tap' is followed automatically by a 'release' 200ms later (the runtime's
tap only presses the button).

Usage: run_cov.py <session> [outdir] [--grid] [--build=phase6]
  --grid    also paste every screenshot into grid.png (for checking a
            session's timing by eye)
  --build=phase6   run the binaries regenerated from SuperSpider's analysis
            (../phase6/build.sh) and write to runs6/<session>
"""
import os, random, subprocess, sys

HOME = os.path.expanduser('~')
LEM = os.path.join(HOME, 'games', 'lemmings')
GD = os.path.join(HOME, 'games', 'galactic dan')
HERE = os.path.dirname(os.path.abspath(__file__))


def shots(every, until):
    return [(t, 'shot') for t in range(every, until + 1, every)]


def random_taps(seed, start, end, step, region):
    """Taps at random points of region (x0, y0, x1, y1), every step ms."""
    rnd = random.Random(seed)
    x0, y0, x1, y1 = region
    return [(t, 'tap', rnd.randrange(x0, x1), rnd.randrange(y0, y1))
            for t in range(start, end, step)]


def lem_level(level, seed, secs):
    """Start LemProg at Fun level `level` (0-based), go through the
    briefing, then click randomly over the play area and skill panel."""
    ms = secs * 1000
    ev = [(4000, 'poke', 0x19d44, level), (6000, 'tap', 50, 181),
          (12000, 'tap', 160, 150), (14000, 'tap', 160, 150)]
    # alternate: pick a skill / panel button, then click in the play area
    ev += random_taps(seed, 18000, ms - 2000, 1400, (0, 228, 320, 252))
    ev += random_taps(seed + 1000, 18700, ms - 2000, 1400, (0, 16, 320, 220))
    return ev + shots(5000, ms) + [(ms, 'quit')]


LEMPROG = dict(binary=os.path.join(LEM, 'recomp', 'lemmings-cov'),
               args=['--trace-gaps',
                     '--app=' + os.path.join(LEM, 'extracted', '!LEMMINGS'),
                     os.path.join(LEM, 'extracted_decompressed', 'LemProg.bin')])

# Built by build_gd.sh: gen_c.py *without* --loops, so Duff's-device plotters
# run as straight-line code and the recorded PC stream matches the original.
GALDAN = dict(binary=os.path.join(HERE, 'build', 'gd', 'recomp', 'galdan-cov'),
              args=['--app=' + os.path.join(GD, 'extracted', '!Galactic'),
                    os.path.join(GD, 'extracted', 'GalacticDan_8000,ff8')])


def gd_click(t, x, y):
    return [(t, 'click', x, y), (t + 150, 'release')]


def gd_play(seed, secs):
    """Skip the title, click PLAY, Space through the briefing, then steer
    with random mouse moves, buttons and the keys the game scans."""
    ms = secs * 1000
    rnd = random.Random(seed)
    ev = gd_click(3000, 140, 20) + gd_click(7000, 140, 20)
    ev += [(12000, 'type', 32), (16000, 'type', 32), (20000, 'type', 32)]
    # INKEY numbers (negated): Shift Ctrl Alt D F S L Tab Space B Insert F1-F3
    # (not P: pausing leaves the rest of the session on the pause screen)
    keys = [1, 2, 3, 51, 68, 82, 87, 97, 99, 101, 62, 114, 115, 116]
    for t in range(22000, ms - 1000, 250):
        r = rnd.random()
        if r < 0.6:
            ev.append((t, 'move', rnd.randrange(-80, 81), rnd.randrange(-80, 81)))
        elif r < 0.8:
            ev.append((t, 'buttons', rnd.choice([1, 2, 4])))
            ev.append((t + 120, 'release'))
        else:
            ev.append((t, 'key', rnd.choice(keys)))
    return ev + shots(5000, ms) + [(ms, 'quit')]


SESSIONS = {
    'gd-calib': dict(GALDAN, events=gd_click(3000, 140, 20) + gd_click(7000, 140, 20)
                     + [(12000, 'key', 99), (16000, 'key', 99), (20000, 'type', 32)]
                     + shots(2000, 30000) + [(31000, 'quit')]),
    'lem-calib': dict(LEMPROG, events=[(6000, 'tap', 50, 181), (12000, 'tap', 160, 150),
                                       (18000, 'tap', 160, 150)]
                      + shots(2000, 30000) + [(31000, 'quit')]),
}
# LemBoot: logos, unpacking, chain-load into LemProg, then into a level.
SESSIONS['lem-boot'] = dict(
    LEMPROG, args=LEMPROG['args'][:-1] + [
        '--boot', '--bootimg=' + os.path.join(LEM, 'extracted', '!LEMMINGS', 'LemBoot,fffff843-00000000')],
    events=[(t, 'tap', 50, 181) for t in range(20000, 60000, 4000)]
    + [(t, 'tap', 160, 150) for t in range(22000, 60000, 4000)]
    + shots(5000, 90000) + [(90000, 'quit')])
# Galactic Dan's built-in deterministic headless scenario (asm/emu.py SCENARIO).
SESSIONS['gd-headless'] = dict(GALDAN, args=GALDAN['args'] + ['--limit=5e9'], events=[])
for sd in range(3):
    SESSIONS['gd-play%d' % sd] = dict(GALDAN, events=gd_play(sd, 120))
for lv in range(0, 30, 5):
    SESSIONS['lem-level%02d' % lv] = dict(LEMPROG, events=lem_level(lv, lv, 120))


def script_string(events):
    out = [(1, 'release')]
    for e in events:
        out.append(e)
        if e[1] == 'tap':
            out.append((e[0] + 200, 'release'))
    out.sort(key=lambda e: e[0])
    return ','.join(':'.join(str(x) for x in e) for e in out)


# Phase 6: the same sessions on binaries regenerated from SuperSpider's
# analysis (../phase6/build.sh), into runs6/.
PHASE6 = {
    os.path.join(LEM, 'recomp', 'lemmings-cov'):
        os.path.join(HERE, '..', 'phase6', 'build', 'lem', 'recomp', 'lemmings-cov'),
    os.path.join(HERE, 'build', 'gd', 'recomp', 'galdan-cov'):
        os.path.join(HERE, '..', 'phase6', 'build', 'gd', 'recomp', 'galdan-cov'),
}


def main():
    name = sys.argv[1]
    phase6 = '--build=phase6' in sys.argv
    outdir = sys.argv[2] if len(sys.argv) > 2 and not sys.argv[2].startswith('--') \
        else os.path.join(HERE, 'runs6' if phase6 else 'runs', name)
    s = dict(SESSIONS[name])
    if phase6:
        s['binary'] = PHASE6[s['binary']]
    os.makedirs(outdir, exist_ok=True)
    # Lemmings' runtime RMLoads musmod2 from ../extracted/!LEMMINGS (relative
    # to the working directory, no option to change it).
    ext = os.path.join(os.path.dirname(outdir), 'extracted')
    if not os.path.exists(ext):
        os.symlink(os.path.join(LEM, 'extracted'), ext)
    for f in os.listdir(outdir):
        if f.startswith('screenshot-') or f == 'untranslated.log':   # the runtime appends to it
            os.remove(os.path.join(outdir, f))
    env = dict(os.environ, SDL_VIDEODRIVER='offscreen', SDL_AUDIODRIVER='dummy',
               RECOMP_COV=os.path.join(outdir, 'cov.out'), RECOMP_ISTAT='1')
    cmd = [s['binary']] + s['args']
    if s['events']:
        cmd.append('--script=' + script_string(s['events']))
    with open(os.path.join(outdir, 'cmd.txt'), 'w') as f:
        f.write(' '.join(cmd) + '\n')
    p = subprocess.run(cmd, cwd=outdir, env=env, stdout=subprocess.PIPE,
                       stderr=subprocess.STDOUT, text=True, errors='replace')
    with open(os.path.join(outdir, 'log.txt'), 'w') as f:
        f.write(p.stdout)
    tail = [l for l in p.stdout.splitlines() if not l.startswith('pchist')][-3:]
    print('\n'.join(tail))
    if '--grid' in sys.argv:
        from PIL import Image
        n = 1
        ims = []
        while os.path.exists(os.path.join(outdir, 'screenshot-%d.bmp' % n)):
            ims.append(Image.open(os.path.join(outdir, 'screenshot-%d.bmp' % n)))
            n += 1
        if ims:
            w, h = ims[0].size
            cols = 5
            g = Image.new('RGB', (w * cols, h * ((len(ims) + cols - 1) // cols)))
            for k, im in enumerate(ims):
                g.paste(im, ((k % cols) * w, (k // cols) * h))
            g.save(os.path.join(outdir, 'grid.png'))


if __name__ == '__main__':
    main()
