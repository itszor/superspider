#!/usr/bin/env python3
"""Phase 1 (PLAN.md): census of indirect control flow.

For every PC-writing instruction other than b/bl/swi in each image's code
(shipped codemap B2 plus everything executed), walk backwards over the
static CFG (plus observed indirect edges) to find where the target value
comes from, and classify the site:

  ret-lr        mov(s) pc,lr with lr = the caller's link (live-in, or
                restored from the stack)
  ret-stack     pc popped off the stack (ldm sp!,{..pc} / ldr pc,[sp],#4)
  table         indexed jump: add pc,pc,rX,lsl #2 (branch table) or
                ldr pc,[base,rX,lsl #2] (address table) with a constant base;
                the index bound is looked for separately (local = within 4
                instructions on the straight-line path, as spider.py does)
  computed-pc   other pc-relative computed jumps (add pc,pc,rX / Duff's devices)
  const         target is a constant (possibly after a few arithmetic steps)
  mem-inline    target loaded from a pc-relative variable that is written
                at run time
  mem           target loaded through some other pointer (object/handler
                tables, structures)
  live-in       target register comes from the caller (function pointer arg)
  call-result   target register was set by a callee
  other         anything else (mixed / too deep / swi results)
A 'call:' prefix marks sites preceded by a link set-up (mov lr,pc etc.).

Each site is joined with the dynamically observed targets and with what
spider.py did there. Then every executed word that plain recursive descent
(B0_auto) misses is attributed to the edge that first entered it.

Writes data/<image>.census.json and prints a summary.
"""
import collections, importlib.util, json, os, pickle, sys

HERE = os.path.dirname(os.path.abspath(__file__))
SPIDERS = {'galdan': os.path.expanduser('~/games/galactic dan/ghidra/spider.py')}
SPIDER_DEFAULT = os.path.expanduser('~/games/lemmings/ghidra/spider.py')
PICKLES = {
    'galdan': '~/games/galactic dan/ghidra/galdan.json.pickle',
    'lemprog': '~/games/lemmings/ghidra/lemprog.json.pickle',
    'lemboot': '~/games/lemmings/ghidra/lemboot.json.pickle',
    'musmod': '~/games/lemmings/ghidra/musmod.json.pickle',
}
M32 = 0xFFFFFFFF
MAXDEPTH = 10          # nested register evaluations
MAXWALK = 400          # instructions visited per backward search


def ror(v, s):
    s &= 31
    return ((v >> s) | (v << (32 - s))) & M32 if s else v


# ------------------------------------------------------------------ decoding
class Insn:
    __slots__ = ('a', 'w', 'cond', 'cls', 'op', 's', 'rn', 'rd', 'rm', 'rs', 'imm',
                 'sh', 'shimm', 'L', 'B', 'P', 'U', 'W', 'regs', 'target')

    def __init__(self, a, w):
        self.a, self.w = a, w
        self.cond = w >> 28
        self.rn = self.rd = self.rm = self.rs = self.imm = self.sh = self.shimm = None
        self.regs = ()
        t = (w >> 25) & 7
        if self.cond == 15:
            self.cls = 'nv'
        elif t == 5:
            self.cls = 'bl' if w & (1 << 24) else 'b'
            off = w & 0xFFFFFF
            if off & 0x800000:
                off -= 0x1000000
            self.target = (a + 8 + off * 4) & 0x3FFFFFC
        elif t == 7 and (w >> 24) & 15 == 15:
            self.cls = 'swi'
        elif t in (6, 7):
            self.cls = 'cop'
        elif t == 4:
            self.cls = 'ldm' if (w >> 20) & 1 else 'stm'
            self.rn = (w >> 16) & 15
            self.P, self.U, self.W = (w >> 24) & 1, (w >> 23) & 1, (w >> 21) & 1
            self.regs = tuple(r for r in range(16) if w >> r & 1)
        elif t in (2, 3):
            if t == 3 and w & 0x10:
                self.cls = 'undef'
                return
            self.cls = 'ldr' if (w >> 20) & 1 else 'str'
            self.rn, self.rd = (w >> 16) & 15, (w >> 12) & 15
            self.P, self.U, self.B, self.W = (w >> 24) & 1, (w >> 23) & 1, (w >> 22) & 1, (w >> 21) & 1
            if t == 2:
                self.imm = w & 0xFFF
            else:
                self.rm, self.sh, self.shimm = w & 15, (w >> 5) & 3, (w >> 7) & 31
        elif (w & 0x0FC000F0) == 0x90:
            self.cls = 'mul'
            self.rd, self.rn, self.rs, self.rm = (w >> 16) & 15, (w >> 12) & 15, (w >> 8) & 15, w & 15
        elif (w & 0x0E000090) == 0x90:
            self.cls = 'undef'                       # not ARM2 (swp is ARM3; rare)
        else:
            self.cls = 'dp'
            self.op, self.s = (w >> 21) & 15, (w >> 20) & 1
            self.rn, self.rd = (w >> 16) & 15, (w >> 12) & 15
            if t == 1:
                self.imm = ror(w & 0xFF, ((w >> 8) & 15) * 2)
            else:
                self.rm, self.sh = w & 15, (w >> 5) & 3
                if w & 0x10:
                    self.rs = (w >> 8) & 15
                else:
                    self.shimm = (w >> 7) & 31

    @property
    def always(self):
        return self.cond == 14

    def defs(self):
        c = self.cls
        if c == 'dp':
            return () if 8 <= self.op <= 11 else (self.rd,)
        if c == 'mul':
            return (self.rd,)
        if c == 'ldr':
            return (self.rd,) + ((self.rn,) if self.W or not self.P else ())
        if c == 'str':
            return (self.rn,) if self.W or not self.P else ()
        if c == 'ldm':
            return self.regs + ((self.rn,) if self.W else ())
        if c == 'stm':
            return (self.rn,) if self.W else ()
        if c == 'bl':
            return (14,)
        return ()

    def writes_pc(self):
        return 15 in self.defs() and not (self.cls == 'ldr' and self.rn == 15 and self.W)

    def simple_shift(self):
        return self.rm is not None and self.rs is None and self.shimm == 0 and self.sh == 0


# ------------------------------------------------------------------ program
class Prog:
    def __init__(self, name, ref='B0_auto'):
        b = json.load(open(os.path.join(HERE, 'data', name + '.json')))
        t = json.load(open(os.path.join(HERE, 'data', name + '.truth.json')))
        self.name, self.b, self.t = name, b, t
        self.base, self.size = b['base'], b['size']
        self.data = open(b['image'], 'rb').read()
        self.E = {int(a, 16) for a in t['executed']}
        self.ref = ref
        self.B0 = set(b[ref])
        self.code = set(b['B2']) | self.E
        # LemBoot's image is overwritten wholesale by the LemProg unpack, so
        # its run-time writes say nothing about variables; use static stores.
        self.written = set(t['written']) if name != 'lemboot' else set()
        # LemBoot runs from its relocated copy after the low copy is
        # overwritten, so its "executed after written" set is an artifact.
        self.smc = set(t['smc']) if name != 'lemboot' else set()
        self.edges = [tuple(e) for e in t['edges']]
        self.rt_entries = {d for d, n in t.get('entries', [])}
        self.insn = {a: Insn(a, self.word(a)) for a in self.code if self.inside(a)}
        spec = importlib.util.spec_from_file_location('spider', SPIDERS.get(name, SPIDER_DEFAULT))
        mod = importlib.util.module_from_spec(spec)
        sys.modules['spider'] = mod
        spec.loader.exec_module(mod)
        self.sp = pickle.load(open(os.path.expanduser(PICKLES[name]), 'rb'))
        self.build_cfg()

    def inside(self, a):
        return self.base <= a <= self.base + self.size - 4

    def word(self, a):
        o = a - self.base
        return int.from_bytes(self.data[o:o + 4], 'little')

    def is_thunk(self, a):
        """Lemmings' literal-load thunk: bic lr,lr,#&fc000003 ; ldr rX,[lr],#4 ; mov pc,lr"""
        return (self.inside(a) and self.inside(a + 8) and self.word(a) == 0xE3CEE3FF
                and self.word(a + 8) == 0xE1A0F00E)

    def thunk_reg(self, a):
        return (self.word(a + 4) >> 12) & 15

    def build_cfg(self):
        self.preds = collections.defaultdict(set)    # addr -> {(pred, how)}
        self.entries = set(self.b['given_seeds']) | set(self.b['hand_seeds']) | set(self.sp.funcs)
        for a, i in self.insn.items():
            if i.cls in ('b', 'bl'):
                if i.cls == 'bl':
                    self.entries.add(i.target)
                    ret = a + 8 if self.is_thunk(i.target) else a + 4
                    self.preds[ret].add((a, 'call'))
                else:
                    self.preds[i.target].add((a, 'jump'))
                if not i.always:
                    self.preds[a + 4].add((a, 'fall'))
                continue
            if i.writes_pc():
                if not i.always:
                    self.preds[a + 4].add((a, 'fall'))
                continue
            if i.cls == 'swi' and (i.w & 0xFDFFFF) == 1:  # OS_WriteS: skip the string
                continue
            self.preds[a + 4].add((a, 'fall'))
        # observed jumps (not returns) also feed the backward walk
        for s, d, n in self.edges:
            i = self.insn.get(s)
            if i is not None and i.writes_pc() and not self.is_return_shape(i):
                self.preds[d].add((s, 'ijump'))
        self.adr = collections.defaultdict(set)       # value -> sites materialising it
        for v, site in self.sp.adr_targets:
            self.adr[v & 0x3FFFFFC].add(site)
        self.literal_refs = collections.defaultdict(set)
        for o in range(0, self.size - 3, 4):
            v = int.from_bytes(self.data[o:o + 4], 'little')
            self.literal_refs[v].add(self.base + o)

    def is_return_shape(self, i):
        if i.cls == 'ldm' and i.rn == 13 and 15 in i.regs:
            return True
        if i.cls == 'ldr' and i.rd == 15 and i.rn == 13 and not i.P:
            return True
        if i.cls == 'dp' and i.op == 13 and i.rm == 14 and i.simple_shift():
            return True
        return False

    # ------------------------------------------------------------ backward walk
    def defs_reaching(self, site, reg):
        """Instructions (or boundaries) that may define reg on some path into
        site. Returns a list of ('def', insn) / ('entry', addr) /
        ('call', bl_insn) / ('swi', insn) / ('limit', None)."""
        out, seen, work, n = [], set(), [site], 0
        while work:
            x = work.pop()
            ps = self.preds.get(x, ())
            if x in self.entries:
                out.append(('entry', x))
            if not ps and x not in self.entries:
                out.append(('entry', x))               # no known predecessor
            for p, how in ps:
                if p in seen:
                    continue                           # merge or loop: stop here
                seen.add(p)
                n += 1
                if n > MAXWALK:
                    out.append(('limit', None))
                    return out
                i = self.insn.get(p)
                if i is None:
                    continue
                if how == 'call':
                    if self.is_thunk(i.target) and self.thunk_reg(i.target) == reg:
                        out.append(('thunk', i))
                        continue
                    if reg in (0, 1, 2, 3, 12, 14):
                        out.append(('call', i))
                        continue
                    work.append(p)
                    continue
                if i.cls == 'swi' and reg in (0, 1, 2, 3):
                    out.append(('swi', i))
                    continue
                if reg in i.defs() and i.cls != 'nv':
                    out.append(('def', i))
                    if i.always:
                        continue
                work.append(p)
        return out

    def eval_reg(self, site, reg, depth=0):
        """Abstract value of reg just before site: ('const', {values}) or
        (kind, detail) for the first non-constant source found."""
        if reg == 15:
            return ('const', {site + 8})
        if depth > MAXDEPTH:
            return ('other', 'deep')
        vals, syms = set(), []
        for how, x in self.defs_reaching(site, reg):
            if how == 'thunk':
                vals.add(self.word(x.a + 4))
            elif how == 'def':
                v = self.eval_def(x, reg, depth + 1)
                if v[0] == 'const':
                    vals |= v[1]
                else:
                    syms.append(v)
            elif how == 'entry':
                syms.append(('live-in', 'r%d' % reg, 0))
            elif how == 'call':
                syms.append(('call-result', '%x' % x.a))
            elif how == 'swi':
                syms.append(('other', 'swi %x' % (x.w & 0xFFFFFF)))
            else:
                syms.append(('other', how))
        if syms:
            if len(set(syms)) == 1 and not vals:
                return syms[0]
            kinds = {s_[0] for s_ in syms} | ({'const'} if vals else set())
            if len(kinds) == 1:
                return syms[0]
            return ('mixed', ','.join(sorted(kinds)))
        if vals:
            return ('const', vals)
        return ('other', 'no-def')

    def eval_def(self, i, reg, depth):
        c = i.cls
        if c == 'dp':
            if i.imm is not None:
                op2 = ('const', {i.imm})
            elif i.rm == 15:
                op2 = ('const', {i.a + 8})
            elif i.simple_shift():
                op2 = self.eval_reg(i.a, i.rm, depth)
            else:
                return ('other', 'shifted-reg')
            if i.op == 13:
                return op2
            if i.op == 15:
                return ('const', {~v & M32 for v in op2[1]}) if op2[0] == 'const' else op2
            if i.op in (0, 1, 2, 3, 4, 12, 14):
                opn = self.eval_reg(i.a, i.rn, depth)
                if opn[0] == 'live-in' and op2[0] == 'const' and len(op2[1]) == 1:
                    k = next(iter(op2[1]))
                    if i.op == 4:
                        return ('live-in', opn[1], opn[2] + k)
                    if i.op == 2:
                        return ('live-in', opn[1], opn[2] - k)
                    if i.op == 14 and k == 0xFC000003:      # strip 26-bit PSR bits
                        return opn
                if opn[0] == 'table-load' or op2[0] == 'table-load':
                    return opn if opn[0] == 'table-load' else op2   # e.g. add r1,pc,r1 (relative tables)
                if opn[0] != 'const':
                    return opn
                if op2[0] != 'const':
                    return op2
                f = {0: lambda x, y: x & y, 1: lambda x, y: x ^ y, 2: lambda x, y: x - y,
                     3: lambda x, y: y - x, 4: lambda x, y: x + y, 12: lambda x, y: x | y,
                     14: lambda x, y: x & ~y}[i.op]
                res = {f(x, y) & M32 for x in opn[1] for y in op2[1]}
                return ('const', res) if len(res) <= 64 else ('other', 'too-many')
            return ('other', 'dp-op%d' % i.op)
        if c == 'ldr':
            if i.rd != reg:                            # writeback: rn += offset
                if i.imm is None:
                    return ('other', 'writeback')
                v = self.eval_reg(i.a, i.rn, depth)
                k = i.imm if i.U else -i.imm
                if v[0] == 'live-in':
                    return ('live-in', v[1], v[2] + k)
                if v[0] == 'const':
                    return ('const', {(x + k) & M32 for x in v[1]})
                return v
            if i.imm is None:
                base = self.eval_reg(i.a, i.rn, depth)
                if base[0] == 'const':
                    return ('table-load', '%x' % i.a, i.rm)
                return ('mem', 'indexed@%x' % i.a)
            base = self.eval_reg(i.a, i.rn, depth)
            if base[0] != 'const':
                return ('mem', 'ptr@%x' % i.a) if i.rn != 13 else ('stack', '%x' % i.a)
            addrs = {(b + (i.imm if i.U else -i.imm)) if i.P else b for b in base[1]}
            out = set()
            for ad in addrs:
                if not self.inside(ad & ~3):
                    return ('mem', 'outside %x' % ad)
                if (ad & ~3) in self.written or (ad & ~3) in self.sp.writes:
                    return ('mem-inline', '%x' % ad)
                out.add(self.word(ad & ~3) if not i.B else self.data[ad - self.base])
            return ('const', out)
        if c == 'ldm':
            return ('stack', '%x' % i.a) if i.rn == 13 else ('mem', 'ldm@%x' % i.a)
        if c == 'bl':
            return ('const', {i.a + 4})                # lr = link
        return ('other', c)

    # ------------------------------------------------------------ sites
    def index_bound(self, site, rx):
        """Look backwards from site for a bound on index register rx:
        cmp rx,#n / and rx,ry,#2^k-1 / ldrb. Returns (bound, distance, how)."""
        work, seen, dist = [(site, 0)], set(), {}
        best = None
        while work:
            x, d = work.pop(0)
            for p, how in self.preds.get(x, ()):
                if p in seen or how == 'call' or d > 60:
                    continue
                seen.add(p)
                i = self.insn.get(p)
                if i is None:
                    continue
                if i.cls == 'dp' and i.op in (10, 8) and i.rn == rx and i.imm is not None:
                    return (i.imm + 1, d + 1, 'cmp' if i.op == 10 else 'tst')
                if rx in i.defs():
                    if i.cls == 'dp' and i.op == 0 and i.imm is not None and ((i.imm + 1) & i.imm) == 0:
                        return (i.imm + 1, d + 1, 'and')
                    if i.cls == 'ldr' and i.B:
                        return (256, d + 1, 'ldrb')
                    if i.cls == 'dp' and i.op == 13 and i.imm is not None:
                        return (1, d + 1, 'mov#')
                    if i.cls == 'dp' and i.op == 13 and i.rs is None and i.sh == 1 and i.shimm:
                        return (1 << (32 - i.shimm), d + 1, 'lsr')
                    best = best or (None, d + 1, 'def-unbounded')
                    if i.always:
                        continue
                work.append((p, d + 1))
        return best or (None, None, 'none')

    def straight_line(self, site, n):
        """Is the bound within n instructions on the fall-through path (what
        spider.py's 4-instruction window can see)?"""
        return n is not None and n <= 4

    def classify(self, i):
        a = i.a
        link = False
        pi = self.insn.get(a - 4)
        if pi is not None and pi.cls == 'dp' and 14 in pi.defs() and (
                (pi.op == 13 and pi.rm == 15) or (pi.op == 4 and pi.rn == 15 and pi.imm is not None)):
            link = True
        if a in self.smc:
            return 'smc', {}, link
        if self.is_return_shape(i):
            if i.cls == 'dp':                         # mov(s) pc,lr
                v = self.eval_reg(a, 14)
                if v[0] == 'live-in':
                    return ('ret-lr' if v[2] == 0 else 'ret-lr%+d' % v[2]), {'lr': list(v)}, link
                if v[0] != 'const':
                    # lr restored from the stack, or a mix / walk limit
                    # (typically a function with no known entry, where the
                    # walk runs on into its callers)
                    return 'ret-lr', {'lr': list(v)}, link
                info = {}
                return self.value_class(v, info), info, link
            return 'ret-stack', {}, link
        info = {}
        if i.cls == 'dp':
            if i.op == 13 and i.simple_shift():
                v = self.eval_reg(a, i.rm)
                if v[0] == 'table-load':
                    at, rx = int(v[1], 16), v[2]
                    b = self.index_bound(at, rx)
                    info.update(index='r%d' % rx, load_at=v[1], bound=b[0], bound_dist=b[1], bound_how=b[2],
                                table='loaded')
                    return 'table', info, link
            if i.rn == 15 and i.rm is not None and i.rs is None and i.op == 4:
                b = self.index_bound(a, i.rm)
                info.update(index='r%d' % i.rm, shift=(i.sh, i.shimm), bound=b[0], bound_dist=b[1], bound_how=b[2])
                if i.sh == 0 and i.shimm == 2:
                    return 'table', dict(info, table='branch'), link
                return 'computed-pc', info, link
            if i.op == 13 and i.simple_shift():
                return self.value_class(self.eval_reg(a, i.rm), info), info, link
            return self.value_class(self.eval_def(i, 15, 0), info), info, link
        if i.cls == 'ldr':
            if i.rm is not None:
                base = self.eval_reg(a, i.rn)
                b = self.index_bound(a, i.rm)
                info.update(index='r%d' % i.rm, bound=b[0], bound_dist=b[1], bound_how=b[2])
                if base[0] == 'const' and i.sh == 0 and i.shimm == 2:
                    info['table'] = 'address'
                    info['table_base'] = sorted(base[1])[:4]
                    return 'table', info, link
                info['base'] = base[0]
                return 'mem', info, link
            return self.value_class(self.eval_def(i, 15, 0), info), info, link
        if i.cls == 'ldm':
            return 'mem', {'ldm_base': 'r%d' % i.rn}, link
        return 'other', {'cls': i.cls}, link

    @staticmethod
    def value_class(v, info=None, prog=None):
        if info is not None:
            info['value'] = [v[0], sorted(v[1])[:8] if v[0] == 'const' else v[1]]
        if v[0] == 'live-in' and info is not None:
            info['value'] = list(v)
        if v[0] == 'const' and info is not None and info.get('outside'):
            return 'const-outside'
        return {'const': 'const', 'mem-inline': 'mem-inline', 'mem': 'mem', 'stack': 'ret-stack',
                'live-in': 'live-in', 'call-result': 'call-result',
                'table-load': 'table'}.get(v[0], 'other')

    def spider_status(self, a):
        sp = self.sp
        if any(x[0] == a for x in sp.xtables):
            return 'xtable'
        if a in getattr(sp, 'duff', ()):
            return 'duff'
        if any(x[0] == a for x in getattr(sp, 'rtjumps', ())):
            return 'rtjump'
        ov = sp.overrides.get(a)
        if ov:
            return 'override:' + ov
        return '-'

    def census(self):
        obs = collections.defaultdict(collections.Counter)
        for s, d, n in self.edges:
            obs[s][d] += n
        sites = []
        for a in sorted(self.insn):
            i = self.insn[a]
            if i.cls in ('b', 'bl', 'swi', 'nv') or not i.writes_pc():
                continue
            cls, info, link = self.classify(i)
            val = info.get('value')
            if cls == 'const' and val and val[0] == 'const' and not all(self.inside(x & 0x3FFFFFC) for x in val[1]):
                cls = 'const-outside'
            tg = sorted(obs.get(a, ()))
            sites.append(dict(
                addr=a, word=i.w, cls=('call:' if link else '') + cls, info=info,
                executed=a in self.E, targets=tg,
                targets_outside_B0=[d for d in tg if d not in self.B0],
                spider=self.spider_status(a), in_B0=a in self.B0))
        return sites

    # ------------------------------------------------------------ attribution
    def attribute_missed(self, sites):
        """Group executed words not in B0_auto into regions and attribute each
        region to how it was first entered."""
        missed = sorted(self.E - self.B0)
        site_cls = {s['addr']: s['cls'] for s in sites}
        regions = []
        for a in missed:
            if regions and regions[-1][1] == a:
                regions[-1][1] = a + 4
            else:
                regions.append([a, a + 4])
        into = collections.defaultdict(list)
        for s, d, n in self.edges:
            into[d].append(s)
        out = []
        for lo, hi in regions:
            causes = collections.Counter()
            via_calls = []
            for x in range(lo, hi, 4):
                for s in into.get(x, ()):
                    if lo <= s < hi:
                        continue
                    i = self.insn.get(s)
                    if i is None:
                        causes['from-outside-image'] += 1
                        continue
                    origin = 'B0' if s in self.B0 else 'missed'
                    if i.cls in ('b', 'bl'):
                        causes['%s:%s' % (origin, i.cls)] += 1
                    elif i.writes_pc():
                        sc = site_cls.get(s, '?')
                        if sc.startswith('ret'):
                            shape, call = self.landing_shape(x)
                            if call is not None and call not in self.B0:
                                via_calls.append(call)   # reached through the call's region
                                continue
                            sc = 'return to ' + shape
                        causes['%s:%s' % (origin, sc)] += 1
                    else:
                        causes['%s:%s' % (origin, i.cls)] += 1
            if (lo - 4) in self.E and (lo - 4) in self.B0:
                pi = self.insn.get(lo - 4)
                if pi is not None and not (pi.always and (pi.writes_pc() or pi.cls == 'b')):
                    causes['B0:fallthrough(%s)' % pi.cls] += 1
            rt = [x for x in range(lo, hi, 4) if x in self.rt_entries]
            if rt:
                refs = []
                if rt[0] in self.adr:
                    refs.append('adr')
                if self.literal_refs.get(rt[0]):
                    refs.append('literal')
                if self.base and self.literal_refs.get(rt[0] - self.base):
                    refs.append('offset-literal')
                causes['runtime/OS-called handler (%s)' % ('+'.join(refs) or 'address not seen statically')] += 1
            if not causes and not via_calls:
                refs = []
                if lo in self.adr:
                    refs.append('adr')
                if self.literal_refs.get(lo):
                    refs.append('literal')
                if self.literal_refs.get(lo - self.base) and self.base:
                    refs.append('offset-literal')
                causes['no edge: runtime/OS-called (%s)' % ('+'.join(refs) or 'address not seen statically')] += 1
            out.append(dict(lo=lo, hi=hi, words=(hi - lo) // 4, causes=dict(causes),
                            from_regions=sorted(self.region_of(regions, s) for x in range(lo, hi, 4)
                                                for s in into.get(x, ())
                                                if not lo <= s < hi and s not in self.B0
                                                and self.region_of(regions, s) is not None
                                                and not self.is_return_into(s, x))
                                         + [self.region_of(regions, c) for c in via_calls
                                            if self.region_of(regions, c) is not None]))
        return out

    def is_return_into(self, s, d):
        i = self.insn.get(s)
        return i is not None and i.writes_pc() and self.landing_shape(d)[1] is not None \
            and self.is_return_shape(i)

    def landing_shape(self, d):
        """What set up a return that lands at d."""
        def ins(a):
            return self.insn.get(a) or (Insn(a, self.word(a)) if self.inside(a) else None)
        i4, i8, i12 = ins(d - 4), ins(d - 8), ins(d - 12)
        if i4 is not None and i4.cls == 'bl':
            return 'bl+4', d - 4
        if i8 is not None and i8.cls == 'bl':
            return ('bl+8 (literal thunk)' if self.is_thunk(i8.target) else 'bl+8'), d - 8
        if i12 is not None and (i12.w & 0x0FFFFFFF) == 0x092D8000:
            return 'push_pc+12', d - 12
        for k in range(1, 8):                          # add rX,pc,#imm pointing here
            j = ins(d - 4 * k)
            if j is not None and j.cls == 'dp' and j.op == 4 and j.rn == 15 and j.imm is not None \
                    and j.a + 8 + j.imm == d:
                return 'address pushed by add rX,pc,#k', j.a
        if i4 is not None and (i4.writes_pc() or i4.cls == 'b'):
            return 'after jump (link set up by hand)', d - 4
        return 'other', None

    @staticmethod
    def region_of(regions, a):
        import bisect
        k = bisect.bisect_right([r[0] for r in regions], a) - 1
        return k if k >= 0 and regions[k][0] <= a < regions[k][1] else None


def direct_causes(r):
    cs = r['causes']
    b0 = sorted(k[3:] for k in cs if k.startswith('B0:'))
    if b0:
        return b0
    return sorted(k for k in cs if k.startswith('no edge') or k.startswith('runtime/OS') or k == 'from-outside-image')


def root_cause(regions):
    """Attribute each missed region's words to the way control left B0 code
    to reach it, following chains of missed regions (via observed edges and
    fall-through) back to B0. A region reached several ways counts under the
    first cause in sorted order; 'mixed' marks those."""
    tally = collections.Counter()
    for k, r in enumerate(regions):
        seen, work, roots = {k}, [k], set()
        while work:
            x = work.pop()
            dc = direct_causes(regions[x])
            if dc:
                roots.update(dc)
            for y in regions[x]['from_regions']:
                if y not in seen:
                    seen.add(y)
                    work.append(y)
            if x - 1 >= 0 and regions[x - 1]['hi'] == regions[x]['lo'] and x - 1 not in seen:
                seen.add(x - 1); work.append(x - 1)
        r['root_causes'] = sorted(roots)
        for key in (roots or {'unknown'}):
            tally[key] += r['words']
    return tally


def main():
    names = sys.argv[1:] or ['galdan', 'lemprog', 'lemboot', 'musmod']
    for name in names:
        p = Prog(name)
        sites = p.census()
        regions = p.attribute_missed(sites)
        rc = root_cause(regions)
        pg = Prog(name, 'B0_generic') if name != 'galdan' else None
        if pg is not None:
            rg_regions = pg.attribute_missed(pg.census())
            rcg = root_cause(rg_regions)
        json.dump(dict(sites=sites, missed_regions=regions,
                       missed_regions_generic=rg_regions if pg is not None else None),
                  open(os.path.join(HERE, 'data', name + '.census.json'), 'w'), indent=0,
                  default=lambda o: sorted(o) if isinstance(o, set) else str(o))
        ex = [s for s in sites if s['executed']]
        print('== %s: %d PC-writing sites (%d executed)' % (name, len(sites), len(ex)))
        by = collections.Counter(s['cls'] for s in sites)
        byx = collections.Counter(s['cls'] for s in ex)
        multi = collections.Counter(s['cls'] for s in ex if len(s['targets']) > 1)
        newt = collections.Counter(s['cls'] for s in ex if s['targets_outside_B0'])
        print('  %-22s %6s %6s %8s %14s' % ('class', 'sites', 'exec', '>1 tgt', 'tgt outside B0'))
        for k, n in by.most_common():
            print('  %-22s %6d %6d %8d %14d' % (k, n, byx[k], multi[k], newt[k]))
        tab = [s for s in sites if s['cls'].endswith('table') or s['cls'].endswith('computed-pc')]
        if tab:
            print('  tables / computed-pc: bound how:', dict(collections.Counter(
                s['info'].get('bound_how') for s in tab)),
                ' local(<=4):', sum(1 for s in tab if (s['info'].get('bound_dist') or 99) <= 4),
                ' spider:', dict(collections.Counter(s['spider'] for s in tab)))
        tot = sum(rc.values())
        tot = sum(r['words'] for r in regions)
        print('  executed words missed by B0_auto: %d in %d regions; words reachable from B0 via '
              '(a region reachable several ways counts under each):' % (tot, len(regions)))
        for k, n in rc.most_common():
            print('    %-60s %6d words' % (k, n))
        if pg is not None:
            print('  vs B0_generic (no Lemmings idiom patches): %d missed words; reachable via:'
                  % sum(r['words'] for r in rg_regions))
            for k, n in rcg.most_common():
                print('    %-60s %6d words' % (k, n))
        print()


if __name__ == '__main__':
    main()
