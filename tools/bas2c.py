#!/usr/bin/env python3
"""Translate a tokenised BBC BASIC V program to C, for a recompiled game
whose program is (partly) BASIC. The C calls a small runtime (bas.h: VDU,
SWIs, CALL into translated code, strings, files) - see Stunt Racer 2000's
recomp/bas.c for one.

Usage: bas2c.py PROGRAM OUT.c

Semantics kept from BASIC:
- PROC/FN parameters and LOCAL variables are dynamically scoped globals,
  saved on an undo stack on entry and restored on exit (and on errors).
- FOR/NEXT and REPEAT/UNTIL are labels and gotos, matched in program order,
  so a NEXT in each branch of a block IF works as it does in BASIC.
- ON ERROR [LOCAL] handlers are setjmp points; an error longjmps to the
  current handler, which runs the rest of its line and carries on.
- Every line sets bas_line (ERL, and for debugging).
Names: x% -> x_I, x -> x_R, x$ -> x_S; arrays x%() -> x_AI, x() -> x_AR,
x$() -> x_AS; PROCx -> PROC_x, FNx -> FN_x; a backtick becomes _Q_.
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import detok  # noqa: E402  (its keyword tables)

KW = dict((k, v) for k, v in detok.T.items() if v)
KW[0x7F] = 'OTHERWISE'
EXT = {0xC6: detok.C6, 0xC7: detok.C7, 0xC8: detok.C8}
CTYPE = {'i': 'int32_t', 'r': 'double', 's': 'S', 'v': 'V'}   # v: an FN returning both strings and numbers
ZERO = {'i': '0', 'r': '0.0', 's': 's_("")', 'v': '(V){0}'}
NAMECH = re.compile(rb'[A-Za-z0-9_`]')


class Tok:
    def __init__(self, kind, val, line):
        self.kind, self.val, self.line = kind, val, line   # kw, id, num, str, op, nl, star, data

    def __repr__(self):
        return '%s:%r' % (self.kind, self.val)


def lex(data):
    toks, p = [], 0
    while data[p + 1] != 0xFF:
        num, ln = data[p + 1] << 8 | data[p + 2], data[p + 3]
        b, i = data[p + 4:p + ln], 0
        toks.append(Tok('nl', num, num))
        while i < len(b):
            c = b[i]
            if c == 0x20:
                i += 1
            elif c == ord('*') and (toks[-1].kind == 'nl' or toks[-1].val in (':', 'THEN', 'ELSE')):
                toks.append(Tok('star', b[i + 1:].decode('latin-1').rstrip(), num))
                break
            elif c == 0x22:
                j, s = i + 1, ''
                while j < len(b):
                    if b[j] == 0x22:
                        if j + 1 < len(b) and b[j + 1] == 0x22:
                            s += '"'
                            j += 2
                            continue
                        break
                    s += chr(b[j])
                    j += 1
                toks.append(Tok('str', s, num))
                i = j + 1
            elif c in EXT:
                toks.append(Tok('kw', EXT[c].get(b[i + 1], '?'), num))
                i += 2
            elif c >= 0x7F:
                w = KW.get(c, '?%02x' % c)
                if w in ('PROC', 'FN'):
                    j = i + 1
                    while j < len(b) and NAMECH.match(bytes([b[j]])):
                        j += 1
                    toks.append(Tok('kw', w, num))
                    toks.append(Tok('id', b[i + 1:j].decode('latin-1'), num))
                    i = j
                    continue
                if w == 'DATA':
                    toks.append(Tok('data', b[i + 1:].decode('latin-1'), num))
                    break
                if w == 'REM':
                    break
                toks.append(Tok('kw', w, num))
                i += 1
            elif chr(c).isdigit() or (c == ord('.') and i + 1 < len(b) and chr(b[i + 1]).isdigit()):
                m = re.match(rb'[0-9]*\.?[0-9]*(E[-+]?[0-9]+)?', b[i:])
                toks.append(Tok('num', m.group(0).decode(), num))
                i += len(m.group(0))
            elif c == ord('&'):
                m = re.match(rb'&[0-9A-Fa-f]+', b[i:])
                toks.append(Tok('num', '0x' + m.group(0)[1:].decode(), num))
                i += len(m.group(0))
            elif c == ord('%') and i + 1 < len(b) and b[i + 1] in b'01':
                m = re.match(rb'%[01]+', b[i:])
                toks.append(Tok('num', str(int(m.group(0)[1:], 2)), num))
                i += len(m.group(0))
            elif NAMECH.match(bytes([c])):
                j = i
                while j < len(b) and NAMECH.match(bytes([b[j]])):
                    j += 1
                if j < len(b) and b[j] in b'%$':
                    j += 1
                toks.append(Tok('id', b[i:j].decode('latin-1'), num))
                i = j
            else:
                for op in ('>>>', '<=', '>=', '<>', '<<', '>>', '+=', '-=', '*=', '/='):
                    if b[i:i + len(op)] == op.encode():
                        toks.append(Tok('op', op, num))
                        i += len(op)
                        break
                else:
                    toks.append(Tok('op', chr(c), num))
                    i += 1
        p += ln
    toks.append(Tok('nl', None, None))
    return toks


def vtype(name):
    return 's' if name.endswith('$') else 'i' if name.endswith('%') else 'r'


def cname(name, arr=False):
    """x% -> x_I, x -> x_R, x$ -> x_S, arrays x_AI...; a backtick -> _Q_"""
    return name.rstrip('%$').replace('`', '_Q_') + ('_A' if arr else '_') + vtype(name).upper()


def fname(kind, name):
    return '%s_%s' % (kind, name.replace('`', '_Q_'))


class Fail(Exception):
    pass


class Trans:
    def __init__(self, toks, fntypes, lenient=False):
        self.lenient = lenient
        self.t, self.p = toks, 0
        self.vars, self.arrays = set(), set()
        self.fntypes, self.found_fn = fntypes, {}
        self.label = 0
        self.data = []
        self.funcs = []           # (name, kind, params, body lines, nlocals)
        self.calls = {}           # proc/fn name -> param types (from DEFs)

    # --- token helpers
    def peek(self, k=0):
        return self.t[self.p + k]

    def next(self):
        tok = self.t[self.p]
        self.p += 1
        return tok

    def at(self, kind, val=None, k=0):
        tok = self.t[self.p + k]
        return tok.kind == kind and (val is None or tok.val == val)

    def accept(self, kind, val=None):
        if self.at(kind, val):
            return self.next()
        return None

    def expect(self, kind, val=None):
        tok = self.accept(kind, val)
        if not tok:
            raise Fail('line %s: expected %s %s, got %r' % (self.peek().line, kind, val, self.peek()))
        return tok

    def stmt_end(self):
        return self.at('nl') or self.at('op', ':') or self.at('kw', 'ELSE')

    def newlabel(self):
        self.label += 1
        return self.label

    def use(self, name):
        self.vars.add(name)
        return cname(name)

    # --- expressions: (C code, type)
    def expr(self):
        return self.e_or()

    def binop(self, sub, ops):
        a, at = sub()
        while True:
            tok = self.peek()
            if not ((tok.kind == 'kw' and tok.val in ops) or (tok.kind == 'op' and tok.val in ops)):
                return a, at
            self.next()
            b, bt = sub()
            a, at = self.combine(tok.val, a, at, b, bt)

    def e_or(self):
        return self.binop(self.e_and, ('OR', 'EOR'))

    def e_and(self):
        return self.binop(self.e_cmp, ('AND',))

    def e_cmp(self):
        return self.binop(self.e_add, ('=', '<>', '<', '>', '<=', '>=', '<<', '>>', '>>>'))

    def e_add(self):
        return self.binop(self.e_mul, ('+', '-'))

    def e_mul(self):
        return self.binop(self.e_pow, ('*', '/', 'MOD', 'DIV'))

    def e_pow(self):
        return self.binop(self.factor, ('^',))

    def toint(self, c, t):
        if t == 'v':
            return '((int32_t)(%s).n)' % c
        if t == 's' and self.lenient:
            return '0'
        if t == 's':
            raise Fail('line %s: string where a number is needed' % self.peek().line)
        return c if t == 'i' else '((int32_t)(%s))' % c

    def combine(self, op, a, at, b, bt):
        if at == 'v':
            a, at = ('%s.s' % a, 's') if bt == 's' else ('%s.n' % a, 'r')
        if bt == 'v':
            b, bt = ('%s.s' % b, 's') if at == 's' else ('%s.n' % b, 'r')
        if op in ('OR', 'EOR', 'AND'):
            return '(%s %s %s)' % (self.toint(a, at), {'OR': '|', 'EOR': '^', 'AND': '&'}[op], self.toint(b, bt)), 'i'
        if op in ('=', '<>', '<', '>', '<=', '>='):
            cop = {'=': '==', '<>': '!='}.get(op, op)
            if at == 's':
                return '(-(strcmp(%s.s, %s.s) %s 0))' % (a, b, cop), 'i'
            return '(-((%s) %s (%s)))' % (a, cop, b), 'i'
        if op in ('<<', '>>'):
            return '((int32_t)(%s) %s (%s))' % (self.toint(a, at), op, self.toint(b, bt)), 'i'
        if op == '>>>':
            return '((int32_t)((uint32_t)(%s) >> (%s)))' % (self.toint(a, at), self.toint(b, bt)), 'i'
        if op == '+' and at == 's':
            return 'cat(%s, %s)' % (a, b), 's'
        if op in ('DIV', 'MOD'):
            return '(%s %s %s)' % (self.toint(a, at), '/' if op == 'DIV' else '%', self.toint(b, bt)), 'i'
        if op == '/':
            return '((double)(%s) / (%s))' % (a, b), 'r'
        if op == '^':
            return 'pow(%s, %s)' % (a, b), 'r'
        t = 'i' if at == bt == 'i' else 'r'
        return '(%s %s %s)' % (a, op, b), t

    def args(self):
        out = []
        if self.accept('op', '('):
            if not self.accept('op', ')'):
                while True:
                    out.append(self.expr())
                    if self.accept('op', ')'):
                        break
                    self.expect('op', ',')
        return out

    def array_ref(self, name):
        self.arrays.add(name)
        idx = self.args()
        return '(*el_%s(&%s, %s))' % (vtype(name), cname(name, True),
                                      ', '.join(self.toint(c, t) for c, t in idx) + (', -1' if len(idx) == 1 else ''))

    def factor(self):
        a, t = self.unary()
        while self.at('op', '!') or self.at('op', '?'):
            op = self.next().val
            b, bt = self.unary()
            a, t = '%s(%s + %s)' % ('PK' if op == '!' else 'PB', self.toint(a, t), self.toint(b, bt)), 'i'
        return a, t

    def unary(self):
        tok = self.next()
        k, v = tok.kind, tok.val
        if k == 'op' and v == '-':
            a, t = self.unary()
            return '(-%s)' % a, t
        if k == 'op' and v == '+':
            return self.unary()
        if k == 'op' and v == '(':
            a, t = self.expr()
            self.expect('op', ')')
            return '(%s)' % a, t
        if k == 'op' and v in '!?':
            a, t = self.factor_noind()
            return '%s(%s)' % ('PK' if v == '!' else 'PB', self.toint(a, t)), 'i'
        if k == 'op' and v == '$':
            a, t = self.factor_noind()
            return 'get_s(%s)' % self.toint(a, t), 's'
        if k == 'num':
            if '.' in v or 'E' in v:
                return v, 'r'
            n = int(v, 16) if v.startswith('0x') else int(v)
            return ('%d' % n if n < 2 ** 31 else '(int32_t)0x%x' % n), 'i'
        if k == 'str':
            return 's_(%s)' % cstr(v), 's'
        if k == 'id':
            if self.at('op', '('):
                return self.array_ref(v), vtype(v)
            return self.use(v), vtype(v)
        if k == 'kw':
            return self.kwfunc(v, tok)
        raise Fail('line %s: unexpected %r in expression' % (tok.line, tok))

    def factor_noind(self):
        """The operand of unary ! ? $: a variable, array element, number or bracket."""
        return self.unary()

    def kwfunc(self, v, tok):
        num1 = {'ABS': 'fabs', 'SIN': 'sin', 'COS': 'cos', 'SQR': 'sqrt', 'RAD': 'RADf', 'INT': 'floor',
                'SGN': 'SGNf', 'TAN': 'tan', 'ATN': 'atan', 'EXP': 'exp', 'LN': 'log', 'DEG': 'DEGf'}
        if v == 'TRUE':
            return 'TRUE', 'i'
        if v == 'FALSE':
            return 'FALSE', 'i'
        if v == 'NOT':
            a, t = self.unary()
            return '(~%s)' % self.toint(a, t), 'i'
        if v in num1:
            a, t = self.unary()
            if v == 'ABS' and t == 'i':
                return 'abs(%s)' % a, 'i'
            if v == 'INT':
                return '((int32_t)floor(%s))' % a, 'i'
            if v == 'SGN':
                return '(%s > 0 ? 1 : (%s) < 0 ? -1 : 0)' % (a, a), 'i'
            return '%s(%s)' % (num1[v], a), 'r'
        if v == 'FN':
            name = self.next().val
            args = self.args()
            rt = self.fntypes.get(name, 'i')
            return '%s(%s)' % (fname('FN', name), self.callargs('FN', name, args)), rt
        if v in ('LEN', 'ASC', 'VAL'):
            a, t = self.unary()
            return '%s(%s)' % (v.lower(), a + '.s' if t == 'v' else a), 'r' if v == 'VAL' else 'i'
        if v == 'CHR$':
            a, t = self.unary()
            return 'chr(%s)' % self.toint(a, t), 's'
        if v == 'STR$':
            if self.accept('op', '~'):
                a, t = self.unary()
                return 'strx(%s)' % self.toint(a, t), 's'
            a, t = self.unary()
            return 'str(%s)' % (a + '.n' if t == 'v' else a), 's'
        if v in ('MID$(', 'LEFT$(', 'RIGHT$(', 'STRING$(', 'INSTR('):
            args = []
            while True:
                args.append(self.expr())
                if self.accept('op', ')'):
                    break
                self.expect('op', ',')
            a = [c + '.s' if t == 'v' else c for c, t in args]
            if v == 'MID$(':
                return 'mid(%s, %s, %s)' % (a[0], a[1], a[2] if len(a) > 2 else '-1'), 's'
            if v == 'LEFT$(':
                return ('left(%s, %s)' % (a[0], a[1])) if len(a) > 1 else 'left(%s, len(%s) - 1)' % (a[0], a[0]), 's'
            if v == 'RIGHT$(':
                return 'right(%s, %s)' % (a[0], a[1] if len(a) > 1 else '1'), 's'
            if v == 'STRING$(':
                return 'string_n(%s, %s)' % (a[0], a[1]), 's'
            return 'instr(%s, %s, %s)' % (a[0], a[1], a[2] if len(a) > 2 else '1'), 'i'
        if v == 'RND':
            if self.at('op', '('):
                self.next()
                a, t = self.expr()
                self.expect('op', ')')
                return ('rnd1()', 'r') if a == '1' else ('rnd(%s)' % self.toint(a, t), 'i')
            return 'rnd32()', 'i'
        if v == 'INKEY':
            a, t = self.unary()
            return 'inkey(%s)' % self.toint(a, t), 'i'
        if v == 'INKEY$':
            a, t = self.unary()
            return 'inkey_s(%s)' % self.toint(a, t), 's'
        if v == 'GET':
            return 'get()', 'i'
        if v == 'GET$':
            return 'chr(get())', 's'
        if v == 'TIME':
            if self.accept('op', '$'):
                return 'time_s()', 's'
            return 'time_get()', 'i'
        if v == 'TIME$':
            return 'time_s()', 's'
        if v == 'ERR':
            return 'bas_err', 'i'
        if v == 'ERL':
            return 'bas_erl', 'i'
        if v == 'REPORT$':
            return 'bas_report', 's'
        if v == 'REPORT':
            self.expect('op', '$')
            return 'bas_report', 's'
        if v == 'PAGE':
            return 'bas_page', 'i'
        if v == 'MODE':
            return 'bas_mode()', 'i'
        if v in ('OPENIN', 'OPENOUT', 'OPENUP'):
            a, t = self.unary()
            return 'bas_open(%d, %s)' % ({'OPENIN': 0x40, 'OPENOUT': 0x80, 'OPENUP': 0xC0}[v], a), 'i'
        if v == 'USR':
            a, t = self.unary()
            return 'usr(%s)' % self.toint(a, t), 'i'
        if v == 'EOF':
            self.expect('op', '#')
            a, t = self.unary()
            return 'bas_eof(%s)' % self.toint(a, t), 'i'
        if v == 'BGET':
            self.expect('op', '#')
            a, t = self.unary()
            return 'bas_bget(%s)' % self.toint(a, t), 'i'
        if v == 'TINT':
            raise Fail('TINT')
        raise Fail('line %s: keyword %s in expression' % (tok.line, v))

    def callargs(self, kind, name, args):
        types = self.calls.get((kind, name))
        out = []
        for k, (c, t) in enumerate(args):
            want = types[k] if types and k < len(types) else t
            out.append(self.conv(c, t, want))
        return ', '.join(out)

    def conv(self, c, t, want):
        if want == t:
            return c
        if t == 'v':
            return '%s.%s' % (c, 's' if want == 's' else 'n')
        if want == 'i':
            return self.toint(c, t)
        if want == 'r':
            return '((double)%s)' % c
        if self.lenient:
            return c
        raise Fail('line %s: number where a string is needed' % self.peek().line)

    # --- statements
    def block(self, stops, inline=False):
        """Statements until a statement-start token in stops (left unread),
        or, inline, the end of the line or ELSE."""
        out = []
        while True:
            if self.at('nl'):
                if inline or self.peek().val is None or self.at('kw', 'DEF', 1):
                    return out
                out.append('L(%d);' % self.next().val)
                continue
            if self.accept('op', ':'):
                continue
            tok = self.peek()
            if tok.kind == 'kw' and tok.val in stops:
                return out
            if inline and self.at('kw', 'ELSE'):
                return out
            out += self.statement()

    def statement(self):
        tok = self.peek()
        if tok.kind == 'kw':
            m = getattr(self, 's_' + re.sub(r'\W', '', tok.val), None)
            if m:
                self.next()
                return m()
            if tok.val in ('TIME',):
                self.next()
                self.expect('op', '=')
                c, t = self.expr()
                return ['time_set(%s);' % self.toint(c, t)]
            raise Fail('line %s: statement %s' % (tok.line, tok.val))
        if tok.kind == 'star':
            self.next()
            return ['oscli_c(%s);' % cstr(tok.val)]
        if tok.kind == 'op' and tok.val == '[':   # the assembler: the game's bas_asm() does it
            self.next()
            text = []
            while not self.at('op', ']'):
                tok = self.next()
                text.append(':' if tok.kind == 'nl' else str(tok.val))
            self.next()
            return ['bas_asm(%s);' % cstr(' '.join(text))]
        if tok.kind == 'data':
            self.next()
            return []
        return self.assignment()

    def lvalue(self):
        tok = self.next()
        if tok.kind == 'op' and tok.val in '!?$':
            a, t = self.unary()
            a = self.toint(a, t)
            return ({'!': 'PK(%s)', '?': 'PB(%s)', '$': 'STRAT(%s)'}[tok.val] % a), 's' if tok.val == '$' else 'i'
        if tok.kind != 'id':
            raise Fail('line %s: not a variable: %r' % (tok.line, tok))
        name = tok.val
        if self.at('op', '(') and self.at('op', ')', 1):
            self.p += 2
            return 'ALL(%s)' % cname(name, True), vtype(name)
        if self.at('op', '('):
            base, t = self.array_ref(name), vtype(name)
        else:
            base, t = self.use(name), vtype(name)
        if self.at('op', '!') or self.at('op', '?'):
            op = self.next().val
            b, bt = self.unary()
            return '%s(%s + %s)' % ('PK' if op == '!' else 'PB', self.toint(base, t), self.toint(b, bt)), 'i'
        return base, t

    def assignment(self):
        lv, t = self.lvalue()
        op = self.next()
        if op.kind != 'op' or op.val not in ('=', '+=', '-=', '*=', '/='):
            raise Fail('line %s: expected =, got %r' % (op.line, op))
        c, ct = self.expr()
        if lv.startswith('ALL('):
            return ['all_%s(&%s, %s);' % (t, lv[4:-1], self.conv(c, ct, t))]
        if lv.startswith('STRAT('):
            return ['put_s(%s, %s);' % (lv[6:-1], c)]
        if t == 's':
            return ['%s = %s;' % (lv, c if op.val == '=' else 'cat(%s, %s)' % (lv, c))]
        return ['%s %s %s;' % (lv, op.val, self.conv(c, ct, t))]

    def s_PROC(self):
        name = self.next().val
        args = self.args()
        return ['%s(%s);' % (fname('PROC', name), self.callargs('PROC', name, args))]

    def s_IF(self):
        c, t = self.expr()
        then_kw = self.accept('kw', 'THEN')
        cond = 'if (%s)' % c
        # each branch starts with the loops open at the IF; a NEXT or UNTIL
        # may close one in either (or both)
        before = list(self.loops)
        block = bool(then_kw) and self.at('nl')    # (a crunched 'IF cond' alone does nothing)
        then = self.block(('ELSE', 'ENDIF')) if block else self.block((), inline=True)
        after_then, self.loops, els = self.loops, list(before), []
        if self.accept('kw', 'ELSE'):
            els = self.block(('ENDIF',)) if block else self.block((), inline=True)
        if block:
            self.expect('kw', 'ENDIF')
        if after_then != before:                 # (IF c THEN REPEAT ... IF c THEN UNTIL x: Stunt Racer)
            self.loops = after_then
        out = [cond + ' {'] + ['    ' + x for x in then]
        if els:
            out += ['} else {'] + ['    ' + x for x in els]
        return out + ['}']

    def s_CASE(self):
        c, t = self.expr()
        self.expect('kw', 'OF')
        v = 'case_%d' % self.newlabel()
        self.locals.append('%s %s;' % (CTYPE[t], v))
        out = ['%s = %s;' % (v, c)]
        first = True
        self.block(('WHEN', 'OTHERWISE', 'ENDCASE'))
        while True:
            if self.accept('kw', 'WHEN'):
                conds = []
                while True:
                    e, et = self.expr()
                    conds.append(('!strcmp(%s.s, %s.s)' if t == 's' else '%s == %s') % (v, e))
                    if not self.accept('op', ','):
                        break
                body = self.block(('WHEN', 'OTHERWISE', 'ENDCASE'))
                out += ['%sif (%s) {' % ('' if first else '} else ', ' || '.join(conds))] + ['    ' + x for x in body]
                first = False
            elif self.accept('kw', 'OTHERWISE'):
                body = self.block(('ENDCASE',))
                out += ['{' if first else '} else {'] + ['    ' + x for x in body]
                first = False
            else:
                if not (self.at('nl') and (self.peek().val is None or self.at('kw', 'DEF', 1))):
                    self.expect('kw', 'ENDCASE')    # (an FN may end inside its CASE)
                break
        return out + ([] if first else ['}'])

    def s_FOR(self):
        var = self.expect('id').val
        t = vtype(var)
        self.expect('op', '=')
        a, at = self.expr()
        self.expect('kw', 'TO')
        b, bt = self.expr()
        s, st = '1', 'i'
        if self.accept('kw', 'STEP'):
            s, st = self.expr()
        n = self.newlabel()
        self.locals.append('volatile %s lim_%d, stp_%d;' % (CTYPE[t], n, n))
        self.loops.append(('FOR', n, cname(var)))
        self.vars.add(var)
        return ['%s = %s; lim_%d = %s; stp_%d = %s;' % (cname(var), self.conv(a, at, t), n, self.conv(b, bt, t),
                                                       n, self.conv(s, st, t)), 'for_%d:;' % n]

    def s_NEXT(self):
        if self.at('id'):
            self.next()
            while self.accept('op', ','):
                self.next()
        if not self.loops:
            raise Fail('line %s: NEXT without FOR' % self.peek().line)
        kind, n, v = self.loops.pop()
        if kind != 'FOR':
            raise Fail('NEXT without FOR at %s' % self.peek().line)
        return ['%s += stp_%d; if (stp_%d >= 0 ? %s <= lim_%d : %s >= lim_%d) goto for_%d;' % (v, n, n, v, n, v, n, n)]

    def s_REPEAT(self):
        n = self.newlabel()
        self.loops.append(('REPEAT', n, None))
        return ['rep_%d:;' % n]

    def s_UNTIL(self):
        c, t = self.expr()
        if not self.loops:
            raise Fail('line %s: UNTIL without REPEAT' % self.peek().line)
        kind, n, _ = self.loops.pop()
        if kind != 'REPEAT':
            raise Fail('UNTIL without REPEAT at %s' % self.peek().line)
        return ['if (!(%s)) goto rep_%d;' % (c, n)]

    def s_ENDPROC(self):
        return ['goto out;']

    def s_END(self):
        return ['quit();']

    def s_QUIT(self):
        return ['quit();']

    def s_LOCAL(self):
        if self.accept('kw', 'ERROR'):
            self.has_handlers = True
            return []
        out = []
        while True:
            name = self.expect('id').val
            self.vars.add(name)
            self.saves.add(name)
            out.append('%s = %s;' % (cname(name), ZERO[vtype(name)]))
            if not self.accept('op', ','):
                return out

    def s_ON(self):
        if self.accept('kw', 'ERROR'):
            local = bool(self.accept('kw', 'LOCAL'))
            if local:
                self.has_handlers = True
            n = self.newlabel()
            saved = list(self.loops)
            body = self.block((), inline=True)
            self.loops = saved
            h = 'h_%d' % n if local else 'bas_global'
            if local:
                self.locals.append('HND h_%d;' % n)
            return ['if (setjmp(%s.jb)) {' % h] + ['    ' + x for x in body] + \
                   ['} else { %s.undo = undo_mark(); bas_h = &%s; }' % (h, h)]
        c, t = self.expr()                       # ON n PROCa, PROCb, ...
        out, k = ['switch (%s) {' % self.toint(c, t)], 1
        while True:
            self.expect('kw', 'PROC')
            self.p -= 1
            self.next()
            out.append('case %d: %s break;' % (k, self.s_PROC()[0]))
            k += 1
            if not self.accept('op', ','):
                return out + ['}']

    def s_CALL(self):
        c, t = self.expr()
        return ['call(%s);' % self.toint(c, t)]

    def s_OSCLI(self):
        c, t = self.expr()
        return ['oscli(%s);' % c]

    def s_DIM(self):
        out = []
        while True:
            name = self.expect('id').val
            if self.at('op', '('):
                dims = [self.toint(c, t) for c, t in self.args()]
                self.arrays.add(name)
                out.append('dim_%s(&%s, %s);' % (vtype(name), cname(name, True),
                                                 ', '.join(dims) + (', -1' if len(dims) == 1 else '')))
            else:
                c, t = self.expr()
                self.vars.add(name)
                out.append('%s = dim(%s + 1);' % (cname(name), self.toint(c, t)))
            if not self.accept('op', ','):
                return out

    def s_READ(self):
        out = []
        while True:
            lv, t = self.lvalue()
            out.append('%s = read_%s();' % (lv, t))
            if not self.accept('op', ','):
                return out

    def s_RESTORE(self):
        return ['data_p = 0;']

    def s_SWAP(self):
        a, t = self.lvalue()
        self.expect('op', ',')
        b, _ = self.lvalue()
        return ['{ %s _t = %s; %s = %s; %s = _t; }' % (CTYPE[t], a, a, b, b)]

    def s_SYS(self):
        swi = self.expr()
        ins = []
        while self.accept('op', ','):
            if self.at('op', ',') or self.stmt_end() or self.at('kw', 'TO'):
                ins.append(('0', 'i'))
                continue
            ins.append(self.expr())
        outs = []
        if self.accept('kw', 'TO'):
            while True:
                if self.at('op', ',') or self.stmt_end() or self.at('op', ';'):
                    outs.append(None)
                else:
                    outs.append(self.lvalue())
                if not self.accept('op', ','):
                    break
            if self.accept('op', ';'):
                outs.append(None)                # the flags: not used
                self.lvalue()
        c, t = swi
        n = self.newlabel()
        if t == 's':
            num = 'swi_%d' % n
            self.globals_extra.append('static uint32_t swi_%d;' % n)
            pre = 'if (!swi_%d) swi_%d = swi_number(%s.s);' % (n, n, c)
        else:
            num, pre = self.toint(c, t), ''
        regs = []
        for k, (ic, it) in enumerate(ins):
            regs.append('R[%d] = %s;' % (k, 'roger_scratch_n(%d, (%s).s)' % (k, ic) if it == 's' else
                                         '(uint32_t)%s' % self.toint(ic, it)))
        res = []
        for k, o in enumerate(outs):
            if o:
                lv, lt = o
                res.append(('%s = get_s0(rs[%d]);' if lt == 's' else '%s = (int32_t)rs[%d];') % (lv, k))
        return ([pre] if pre else []) + ['{ uint32_t rs[10]; %s sys_call(%s, rs);' % (' '.join(regs), num)] + \
            ['    ' + x for x in res] + ['}']

    def s_PRINT(self):
        out, last = [], None
        fh = None
        if self.accept('op', '#'):
            c, t = self.unary()
            fh = self.toint(c, t)
            while self.accept('op', ','):
                e, et = self.expr()
                out.append('bas_print_%s(%s, %s);' % (et, fh, e))
            return out
        while not self.stmt_end():
            if self.accept('op', ';'):
                last = ';'
                continue
            if self.accept('op', ','):
                last = ','
                continue
            if self.accept('op', "'"):
                out.append('vdu(13, 10, -1);')
                last = "'"
                continue
            if self.accept('kw', 'TAB('):
                a = [self.expr()]
                while self.accept('op', ','):
                    a.append(self.expr())
                self.expect('op', ')')
                out.append('print_tab(%s);' % ', '.join(self.toint(c, t) for c, t in a) if len(a) == 2
                           else 'print_tab(%s, -1);' % self.toint(*a[0]))
                last = 'tab'
                continue
            if self.accept('kw', 'SPC'):
                c, t = self.unary()
                out.append('print_s(string_n(%s, s_(" ")));' % self.toint(c, t))
                last = 'tab'
                continue
            c, t = self.expr()
            out.append('print_s(%s);' % (c if t == 's' else 'str(%s)' % c if last == ';' else 'print_num(%s)' % c))
            last = 'x'
        if last not in (';', 'tab') or last is None:
            if last != ';':
                out.append('vdu(13, 10, -1);')
        return out

    def s_VDU(self):
        out = []
        while not self.stmt_end():
            c, t = self.expr()
            if self.accept('op', ';'):
                out.append('vduw(%s);' % self.toint(c, t))
            elif self.accept('op', '|'):
                out.append('vdu(%s, -1); vdu(0, 0, 0, 0, 0, 0, 0, 0, 0, -1);' % self.toint(c, t))
            else:
                self.accept('op', ',')
                out.append('vdu(%s, -1);' % self.toint(c, t))
        return out

    def nums(self, n):
        out = []
        for k in range(n):
            if k:
                self.expect('op', ',')
            c, t = self.expr()
            out.append(self.toint(c, t))
        return out

    def s_MOVE(self):
        return ['plot(4, %s, %s);' % tuple(self.nums(2))]

    def s_DRAW(self):
        return ['plot(5, %s, %s);' % tuple(self.nums(2))]

    def s_PLOT(self):
        return ['plot(%s, %s, %s);' % tuple(self.nums(3))]

    def s_LINE(self):
        return ['line(%s, %s, %s, %s);' % tuple(self.nums(4))]

    def s_RECTANGLE(self):
        fill = bool(self.accept('kw', 'FILL'))
        a = self.nums(3)
        if self.accept('op', ','):
            a += self.nums(1)
        else:
            a.append(a[2])
        if self.accept('kw', 'TO'):              # block copy (move, with FILL)
            return ['rectangle_copy(%d, %s, %s, %s, %s, %s, %s);' % (fill, *a, *self.nums(2))]
        return ['rectangle%s(%s, %s, %s, %s);' % ('_fill' if fill else '', *a)]

    def s_GCOL(self):
        a = self.nums(1)
        if self.accept('op', ','):
            a += self.nums(1)
        else:
            a = ['0'] + a
        out = ['gcol(%s, %s);' % tuple(a)]
        if self.accept('kw', 'TINT'):
            out.append('tint(%s, %s);' % ('(%s & 128 ? 3 : 2)' % a[1], self.nums(1)[0]))
        return out

    def s_COLOUR(self):
        a = self.nums(1)
        if self.accept('op', ','):
            a += self.nums(1)
            if self.accept('op', ','):
                a += self.nums(2)
                return ['colour_rgb(%s, %s, %s, %s);' % tuple(a)]
            return ['vdu(19, %s, %s, 0, 0, 0, -1);' % tuple(a)]
        out = ['colour(%s);' % a[0]]
        if self.accept('kw', 'TINT'):
            out.append('tint(%s, %s);' % ('(%s & 128 ? 1 : 0)' % a[0], self.nums(1)[0]))
        return out

    def s_TINT(self):
        return ['tint(%s, %s);' % tuple(self.nums(2))]

    def s_CLS(self):
        return ['cls();']

    def s_CLG(self):
        return ['vdu(16, -1);']

    def s_MODE(self):
        return ['mode(%s);' % self.nums(1)[0]]

    def s_ORIGIN(self):
        return ['origin(%s, %s);' % tuple(self.nums(2))]

    def s_OFF(self):
        return ['off();']

    def s_WAIT(self):
        return ['wait_();']

    def s_VOICES(self):
        return ['voices(%s);' % self.nums(1)[0]]

    def s_SOUND(self):
        if self.accept('kw', 'ON'):
            return ['sound_on(1);']
        if self.accept('kw', 'OFF'):
            return ['sound_on(0);']
        return ['sound(%s, %s, %s, %s);' % tuple(self.nums(4))]

    def s_MOUSE(self):
        if self.accept('kw', 'TO'):
            return ['mouse_to(%s, %s);' % tuple(self.nums(2))]
        if self.accept('kw', 'STEP'):
            a = self.nums(1)
            if self.accept('op', ','):
                a += self.nums(1)
            return ['mouse_step(%s);' % a[0]]
        if self.accept('kw', 'RECTANGLE'):
            return ['mouse_rect(%s, %s, %s, %s);' % tuple(self.nums(4))]
        if self.accept('kw', 'COLOUR'):
            return ['vdu(19, %s, 25, %s, %s, %s, -1);' % tuple(self.nums(4))]
        if self.accept('kw', 'ON') or self.accept('kw', 'OFF'):
            if not self.stmt_end():
                self.expr()
            return []
        lv = [self.lvalue()]
        while self.accept('op', ','):
            lv.append(self.lvalue())
        out = ['{ int32_t mx, my, mb; mouse(&mx, &my, &mb);']
        for (c, t), v in zip(lv, ('mx', 'my', 'mb')):
            out.append('    %s = %s;' % (c, v))
        return out + ['}']

    def s_CLOSE(self):
        self.expect('op', '#')
        c, t = self.unary()
        return ['bas_close(%s);' % self.toint(c, t)]

    def s_INPUT(self):
        self.expect('op', '#')
        c, t = self.unary()
        out = []
        while self.accept('op', ','):
            lv, lt = self.lvalue()
            out.append('%s = bas_input_%s(%s);' % (lv, lt, self.toint(c, t)))
        return out

    def s_ERROR(self):
        n = self.nums(1)[0]
        self.expect('op', ',')
        c, t = self.expr()
        return ['bas_error(%s, %s.s);' % (n, c)]

    def s_RETURN(self):
        raise Fail('RETURN')

    # --- the program
    def program(self):
        defs = []
        self.globals_extra = []
        self.start_func()
        main = self.block(())
        self.funcs.append(('main', 'main', [], main, self.locals, self.saves, self.has_handlers, 'i'))
        while self.at('nl') and self.peek().val is not None:
            line = self.next().val
            self.expect('kw', 'DEF')
            kind = self.next().val
            name = self.next().val
            params = []
            self.start_func()
            if self.accept('op', '('):            # formal parameters: variables or array elements
                while True:
                    pname = self.peek().val
                    lv, t = self.lvalue()
                    params.append((lv, t, pname))
                    if self.accept('op', ')'):
                        break
                    self.expect('op', ',')
            self.ret_types, self.cur_fn = set(), name if kind == 'FN' else None
            body = ['L(%d);' % line] + self.block(())
            rts = self.ret_types
            rt = 'v' if 's' in rts and rts - {'s'} else 's' if 's' in rts else 'r' if 'r' in rts else 'i'
            if kind == 'FN':
                self.found_fn[name] = rt
            self.funcs.append((name, kind, params, body, self.locals, self.saves, self.has_handlers, rt))
        return defs

    def start_func(self):
        self.locals, self.saves, self.has_handlers, self.loops = [], set(), False, []

    def s_DEF(self):
        raise Fail('DEF inside a body at line %s' % self.peek().line)

    def s_ELSE(self):
        raise Fail('stray ELSE at line %s' % self.peek().line)

    def s_ENDCASE(self):
        return []                                 # executed outside its CASE: BASIC skips it

    def s_ENDIF(self):
        return []                                 # an ENDIF of a single-line IF


def cstr(s):
    return '"%s"' % ''.join(c if 32 <= ord(c) < 127 and c not in '"\\?' else '\\%03o' % ord(c) for c in s)


def fn_eq(tr):
    """'=expr' in an FN body: the return."""


def generate(data):
    toks = lex(data)
    fntypes, settled = {}, False
    for _ in range(6):
        tr = Trans(toks, fntypes, lenient=not settled)
        tr.calls = scan_defs(toks)
        orig_statement = tr.statement

        def statement(tr=tr, orig=orig_statement):
            if tr.at('op', '='):
                tr.next()
                c, t = tr.expr()
                tr.ret_types.add(t)
                if tr.fntypes.get(tr.cur_fn) == 'v':
                    c = '(V){.s = %s}' % c if t == 's' else '(V){.n = %s}' % c
                return ['{ ret = %s; goto out; }' % c]
            return orig()
        tr.statement = statement
        tr.program()
        if settled:
            break
        settled = tr.found_fn == fntypes
        fntypes = dict(tr.found_fn)
    return emit(tr, toks)


def scan_defs(toks):
    calls = {}
    for k in range(len(toks) - 3):
        if toks[k].kind == 'kw' and toks[k].val == 'DEF':
            name, params = (toks[k + 1].val, toks[k + 2].val), []
            j = k + 3
            if toks[j].kind == 'op' and toks[j].val == '(':
                j, depth = j + 1, 0
                while depth or not (toks[j].kind == 'op' and toks[j].val == ')'):
                    if toks[j].kind == 'op' and toks[j].val in '()':
                        depth += 1 if toks[j].val == '(' else -1
                    elif toks[j].kind == 'id' and not depth:
                        params.append(vtype(toks[j].val))
                    j += 1
            calls[name] = params
    return calls


def emit(tr, toks):
    out = ['/* generated by bas2c.py - do not edit */', '#include <math.h>', '#include <stdlib.h>',
           '#include "bas.h"', '']
    data = []
    for t in toks:
        if t.kind == 'data':
            data += split_data(t.val)
    out.append('const char *const bas_data[] = {%s, 0};' % ', '.join(cstr(d) for d in data))
    out.append('')
    for v in sorted(tr.vars):
        c = cname(v)
        if c in ('A_I', 'B_I', 'C_I', 'D_I', 'E_I', 'F_I', 'G_I', 'H_I'):
            continue
        resident = re.match(r'[A-Z]_I$', c)          # A%-Z%: visible to the game's own C
        out.append('%s%s %s;' % ('' if resident else 'static ', CTYPE[vtype(v)], c))
    for a in sorted(tr.arrays):
        out.append('static ARR_%s %s;' % (vtype(a), cname(a, True)))
    out += tr.globals_extra
    rtype = CTYPE
    for name, kind, params, body, locs, saves, hh, rt in tr.funcs:
        if kind == 'main':
            continue
        out.append('static %s %s(%s);' % ('void' if kind == 'PROC' else rtype[rt], fname(kind, name),
                                             ', '.join('%s a%d' % (CTYPE[p[1]], k) for k, p in enumerate(params)) or 'void'))
    out.append('')
    for name, kind, params, body, locs, saves, hh, rt in tr.funcs:
        if kind == 'main':
            out.append('void bas_main(void)')
        else:
            out.append('static %s %s(%s)' % ('void' if kind == 'PROC' else rtype[rt], fname(kind, name),
                                                ', '.join('%s a%d' % (CTYPE[p[1]], k) for k, p in enumerate(params)) or 'void'))
        out.append('{')
        out.append('    int mark = undo_mark();')
        if hh:
            out.append('    HND *h_saved = bas_h;')
        if kind == 'FN':
            out.append('    %s ret = %s;' % (rtype[rt], ZERO[rt]))
        for l in locs:
            out.append('    ' + l)
        for k, p in enumerate(params):
            out.append('    save_%s(&%s); %s = a%d;' % (p[1], p[0], p[0], k))
        for s in sorted(saves):
            out.append('    save_%s(&%s);' % (vtype(s), cname(s)))
        out += ['    ' + x for x in body]
        out.append('out:')
        if hh:
            out.append('    bas_h = h_saved;')
        out.append('    undo_to(mark);')
        if kind == 'FN':
            out.append('    return ret;')
        out.append('}')
        out.append('')
    return '\n'.join(out) + '\n'


def split_data(s):
    items, cur, q = [], '', False
    for ch in s:
        if ch == '"':
            q = not q
            continue
        if ch == ',' and not q:
            items.append(cur.strip() if not cur.startswith(' "') else cur)
            cur = ''
            continue
        cur += ch
    items.append(cur.strip())
    return items


if __name__ == '__main__':
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    try:
        c = generate(open(sys.argv[1], 'rb').read())
    except Fail as e:
        sys.exit('bas2c: %s' % e)
    open(sys.argv[2], 'w').write(c)
