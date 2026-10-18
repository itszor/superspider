"""BBC BASIC V's ARM assembler, for bas2c.py: a [ ... ] block becomes C that
assembles each instruction at run time, at P% (or O%, OPT 4-7), as the
interpreter would - its operands are BASIC expressions (labels are
variables, set to P% where they're defined), so a program assembling in
two passes (FOR pass=0 TO 2 STEP 2: P%=code: [OPT pass ...]: NEXT)
resolves its forward references in the second, and errors (a branch out
of range, an immediate constant that can't be encoded) are raised only
when OPT's bit 1 asks for them. The runtime's asm_*() functions
(runtime/basic_runtime.c) do the encoding that depends on the values.

ARM2's instruction set as BASIC V writes it: <op>[<cond>][S|P|B|T|<LDM
mode>]: data processing (with #imm, or a register shifted by #n or a
register, RRX), MUL/MLA, LDR/STR ([Rn], [Rn,#e]{!}, [Rn],#e, [Rn,Rm
{,shift}]{!}, [Rn],Rm, or a label: PC-relative), LDM/STM ({...}, !, ^),
B/BL, SWI (a number or a name), ADR; EQUB/EQUW/EQUD/EQUS (DCB/DCW/DCD/DCS),
ALIGN and OPT. Labels are .name. The tokeniser split mnemonics where they
begin with a keyword (MOVEQ is MOVE, Q; EORS is EOR, S), and ran an
operand into its mnemonic where there was no space (MOVR8,R5); both are
undone here from the tokens' spacing (Tok.gap).
"""
import re

COND = {'EQ': 0, 'NE': 1, 'CS': 2, 'HS': 2, 'CC': 3, 'LO': 3, 'MI': 4, 'PL': 5, 'VS': 6, 'VC': 7,
        'HI': 8, 'LS': 9, 'GE': 10, 'LT': 11, 'GT': 12, 'LE': 13, 'AL': 14, 'NV': 15}
DP = {'AND': 0, 'EOR': 1, 'SUB': 2, 'RSB': 3, 'ADD': 4, 'ADC': 5, 'SBC': 6, 'RSC': 7,
      'TST': 8, 'TEQ': 9, 'CMP': 10, 'CMN': 11, 'ORR': 12, 'MOV': 13, 'BIC': 14, 'MVN': 15}
SHIFT = {'LSL': 0, 'ASL': 0, 'LSR': 1, 'ASR': 2, 'ROR': 3}
LDM = {'IA': (0, 1), 'IB': (1, 1), 'DA': (0, 0), 'DB': (1, 0)}
STACK = {'L': {'FD': 'IA', 'ED': 'IB', 'FA': 'DA', 'EA': 'DB'},
         'S': {'FD': 'DB', 'ED': 'DA', 'FA': 'IB', 'EA': 'IA'}}
DIRECTIVE = {'EQUB': 1, 'EQUW': 2, 'EQUD': 4, 'EQUS': 0, 'DCB': 1, 'DCW': 2, 'DCD': 4, 'DCS': 0}
REG = re.compile(r'^(R(1[0-5]|[0-9])|PC)$')
Fail = Exception                 # (bas2c.py's, set when it imports this)
CONDS = '|'.join(COND)


def parse_mnemonic(m):
    """(kind, details) for a mnemonic, or None"""
    if m in DIRECTIVE or m in ('ALIGN', 'OPT'):
        return (m, None)
    r = re.match(r'^(%s)(%s)?(S|P)?$' % ('|'.join(DP), CONDS), m)
    if r:
        op, c, s = r.group(1), r.group(2), r.group(3)
        if s == 'P' and DP[op] not in (8, 9, 10, 11):
            return None
        return ('DP', (DP[op], COND[c] if c else 14, s))
    r = re.match(r'^(MUL|MLA)(%s)?(S)?$' % CONDS, m)
    if r:
        return ('MUL', (r.group(1) == 'MLA', COND[r.group(2)] if r.group(2) else 14, bool(r.group(3))))
    r = re.match(r'^(LDR|STR)(%s)?(B)?(T)?$' % CONDS, m)
    if r:
        return ('MEM', (r.group(1) == 'LDR', COND[r.group(2)] if r.group(2) else 14, bool(r.group(3)), bool(r.group(4))))
    r = re.match(r'^(LDM|STM)(%s)?(IA|IB|DA|DB|FD|ED|FA|EA)$' % CONDS, m)
    if r:
        l = r.group(1) == 'LDM'
        mode = STACK['L' if l else 'S'].get(r.group(3), r.group(3))
        return ('BLOCK', (l, COND[r.group(2)] if r.group(2) else 14, LDM[mode]))
    r = re.match(r'^SWI(%s)?$' % CONDS, m)
    if r:
        return ('SWI', COND[r.group(1)] if r.group(1) else 14)
    r = re.match(r'^ADR(%s)?$' % CONDS, m)
    if r:
        return ('ADR', COND[r.group(1)] if r.group(1) else 14)
    return None


def branch_mnemonic(m):
    """B, BL and their conditions: BLT, BLS, BLE are B with LT, LS, LE"""
    if m.startswith('B') and m[1:] in COND:
        return ('B', (False, COND[m[1:]]))
    if m == 'BL':
        return ('B', (True, 14))
    if m.startswith('BL') and m[2:] in COND:
        return ('B', (True, COND[m[2:]]))
    if m == 'B':
        return ('B', (False, 14))
    return None


def mnemonic(m):
    m = m.upper()
    b = branch_mnemonic(m)
    return b if b else parse_mnemonic(m) if not m.startswith('B') or m.startswith('BIC') else None


class Asm:
    def __init__(self, tr):
        self.tr = tr

    def read_mnemonic(self):
        """The mnemonic at the current token: the tokens run together (no
        space between them) joined, its longest valid prefix taken; what's
        left of the last token it takes (an operand run into it: MOVR8)
        stays as a token of its own."""
        tr = self.tr
        run = []
        while True:
            t = tr.peek(len(run))
            if t.kind not in ('id', 'kw') or (run and t.gap):
                break
            run.append(str(t.val))
        joined = ''.join(run)
        for n in range(len(joined), 0, -1):
            m = mnemonic(joined[:n])
            if m:
                break
        else:
            raise self.fail('unknown mnemonic %s' % (joined or tr.peek()))
        k, pos = 0, 0
        while k < len(run) and pos + len(run[k]) <= n:
            pos += len(run[k])
            tr.next()
            k += 1
        if pos < n:
            t, tail = tr.peek(), run[k][n - pos:]
            t.kind, t.val = ('num', str(int(tail))) if tail.isdigit() else ('id', tail)
        return joined[:n].upper(), m

    def fail(self, msg):
        return Fail('line %s: assembler: %s' % (self.tr.peek().line, msg))

    def reg(self):
        """R0-R15, PC, or a number (MOV PC,14: Stunt Racer)"""
        t = self.tr.peek()
        if t.kind == 'id' and REG.match(t.val.upper()):
            self.tr.next()
            v = t.val.upper()
            return 15 if v == 'PC' else int(v[1:])
        if t.kind == 'num' and '.' not in t.val:
            self.tr.next()
            return int(t.val, 0) & 15
        raise self.fail('register expected, got %r' % t)

    def comma(self):
        self.tr.expect('op', ',')

    def value(self):
        c, t = self.tr.expr()
        return self.tr.toint(c, t)

    def shift(self):
        """after Rm: [, shift #n | shift Rs | RRX] -> (constant bits, dynamic C or None)"""
        tr = self.tr
        if not (tr.at('op', ',') and tr.peek(1).kind == 'id' and
                (str(tr.peek(1).val).upper() in SHIFT or str(tr.peek(1).val).upper() == 'RRX')):
            return 0, None
        tr.next()
        s = str(tr.next().val).upper()
        if s == 'RRX':
            return 3 << 5, None
        typ = SHIFT[s]
        if tr.accept('op', '#'):
            return typ << 5, 'asm_shift(%d, %s)' % (typ, self.value())
        return typ << 5 | 1 << 4 | self.reg() << 8, None

    def operand2(self):
        """#imm or Rm[, shift]"""
        if self.tr.accept('op', '#'):
            return 0, 'asm_imm(%s)' % self.value()
        rm = self.reg()
        bits, dyn = self.shift()
        return rm | bits, dyn

    def instruction(self, kind, d):
        tr = self.tr
        if kind == 'DP':
            op, cond, s = d
            w = cond << 28 | op << 21
            if op in (8, 9, 10, 11):                 # TST TEQ CMP CMN: flags; P: Rd = PC
                w |= 1 << 20 | (15 << 12 if s == 'P' else 0)
                w |= self.reg() << 16
                self.comma()
            else:
                if s == 'S':
                    w |= 1 << 20
                w |= self.reg() << 12
                self.comma()
                if op not in (13, 15):               # MOV MVN have no Rn
                    w |= self.reg() << 16
                    self.comma()
            bits, dyn = self.operand2()
            return self.word(w | bits, dyn)
        if kind == 'MUL':
            acc, cond, s = d
            w = cond << 28 | 0x90 | acc << 21 | s << 20
            w |= self.reg() << 16
            self.comma()
            w |= self.reg()
            self.comma()
            w |= self.reg() << 8
            if acc:
                self.comma()
                w |= self.reg() << 12
            return self.word(w, None)
        if kind == 'MEM':
            load, cond, byte, t = d
            w = cond << 28 | 1 << 26 | load << 20 | byte << 22
            w |= self.reg() << 12
            self.comma()
            if not tr.accept('op', '['):             # a label: PC-relative, pre-indexed
                return self.word(w | 1 << 24 | 15 << 16, 'asm_pcrel(%s)' % self.value())
            w |= self.reg() << 16
            if tr.accept('op', ']'):
                if tr.accept('op', ','):             # post-indexed: [Rn],#e or [Rn],Rm
                    if t:
                        w |= 1 << 21
                    bits, dyn = self.offset()
                    return self.word(w | bits, dyn)
                w |= 1 << 24 | 1 << 23               # [Rn]
                if tr.accept('op', '!'):
                    w |= 1 << 21
                return self.word(w, None)
            self.comma()
            bits, dyn = self.offset()
            tr.expect('op', ']')
            w |= 1 << 24
            if tr.accept('op', '!'):
                w |= 1 << 21
            return self.word(w | bits, dyn)
        if kind == 'BLOCK':
            load, cond, (p, u) = d
            w = cond << 28 | 4 << 25 | p << 24 | u << 23 | load << 20
            w |= self.reg() << 16
            if tr.accept('op', '!'):
                w |= 1 << 21
            self.comma()
            tr.expect('op', '{')
            while True:
                a = self.reg()
                b = a
                if tr.accept('op', '-'):
                    b = self.reg()
                for r in range(a, b + 1):
                    w |= 1 << r
                if not tr.accept('op', ','):
                    break
            tr.expect('op', '}')
            if tr.accept('op', '^'):
                w |= 1 << 22
            return self.word(w, None)
        if kind == 'B':
            link, cond = d
            return self.word(cond << 28 | 5 << 25 | link << 24, 'asm_branch(%s)' % self.value())
        if kind == 'SWI':
            c, t = tr.expr()
            if t == 's':
                return self.word(d << 28 | 0xF << 24, 'swi_number(%s.s)' % c)
            return self.word(d << 28 | 0xF << 24, '(%s & 0xFFFFFF)' % tr.toint(c, t))
        if kind == 'ADR':
            rd = self.reg()
            self.comma()
            return ['asm_adr(%d, %d, %s);' % (d, rd, self.value())]
        raise self.fail(kind)

    def offset(self):
        """#e, or [-]Rm[, shift #n]: (constant bits, dynamic C)"""
        tr = self.tr
        if tr.accept('op', '#'):
            return 0, 'asm_off12(%s)' % self.value()
        neg = bool(tr.accept('op', '-'))
        rm = self.reg()
        bits, dyn = self.shift()
        return (1 << 25 | (0 if neg else 1 << 23) | rm | bits), dyn

    def word(self, w, dyn):
        c = '0x%08X' % w
        return ['asm_w(%s);' % (c if dyn is None else '%s | %s' % (c, dyn))]

    def directive(self, m):
        tr = self.tr
        if m == 'OPT':
            return ['asm_opt(%s);' % self.value()]
        if m == 'ALIGN':
            return ['asm_align();']
        n = DIRECTIVE[m]
        c, t = tr.expr()
        if n == 0 or t == 's':
            return ['asm_s(%s);' % c]
        return ['asm_%s(%s);' % ({1: 'b', 2: 'h', 4: 'w'}[n], tr.toint(c, t))]

    def block(self):
        """after '[': statements to ']' -> C lines"""
        tr = self.tr
        out = []
        while True:
            if tr.at('nl'):
                n = tr.next().val
                if n is None:
                    raise self.fail('no ] before the end of the program')
                tr.owner[n] = tr.cur_routine
                out.append('L(%d);' % n)
                continue
            if tr.accept('op', ':'):
                continue
            if tr.accept('op', ']'):
                return out
            if tr.at('op', ';') or tr.at('op', '\\'):    # a comment, to the end of the statement
                while not (tr.at('nl') or tr.at('op', ':') or tr.at('op', ']')):
                    tr.next()
                continue
            if tr.accept('op', '.'):                       # a label
                name = tr.expect('id').val
                lv = tr.use(name)
                out.append('%s = %s;' % (lv, 'P_I' if name.endswith('%') else '(double)P_I'))
                continue
            m, (kind, d) = self.read_mnemonic()
            if kind in DIRECTIVE or kind in ('ALIGN', 'OPT'):
                out += self.directive(kind)
            else:
                out += self.instruction(kind, d)


def assemble(tr):
    return Asm(tr).block()
