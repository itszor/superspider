#!/usr/bin/env python3
"""Detokenise an Acorn BBC BASIC V program (filetype &FFB) to text.

Inline assembler is stored as plain text with BASIC keywords tokenised
(AND, EOR, OR, ...), so it comes out as written."""
import sys

T = {}
base = ("AND DIV EOR MOD OR ERROR LINE OFF STEP SPC TAB( ELSE THEN _ OPENIN PTR "
        "PAGE TIME LOMEM HIMEM ABS ACS ADVAL ASC ASN ATN BGET COS COUNT DEG ERL ERR "
        "EVAL EXP EXT FALSE FN GET INKEY INSTR( INT LEN LN LOG NOT OPENUP OPENOUT PI "
        "POINT( POS RAD RND SGN SIN SQR TAN TO TRUE USR VAL VPOS CHR$ GET$ INKEY$ "
        "LEFT$( MID$( RIGHT$( STR$ STRING$( EOF c6 c7 c8 c9 ca cb cc cd ce cf d0 d1 d2 d3 SOUND BPUT "
        "CALL CHAIN CLEAR CLOSE CLG CLS DATA DEF DIM DRAW END ENDPROC ENVELOPE FOR "
        "GOSUB GOTO GCOL IF INPUT LET LOCAL MODE MOVE NEXT ON VDU PLOT PRINT PROC READ "
        "REM REPEAT REPORT RESTORE RETURN RUN STOP COLOUR TRACE UNTIL WIDTH OSCLI").split()
for i, w in enumerate(base):
    T[0x80 + i] = w
T[0x8D] = None  # line number reference
C6 = {0x8E: "SUM", 0x8F: "BEAT"}
C7 = dict(enumerate("APPEND AUTO CRUNCH DELETE EDIT HELP LIST LOAD LVAR NEW OLD RENUMBER "
                    "SAVE TEXTLOAD TEXTSAVE TWIN TWINO INSTALL".split(), 0x8E))
C8 = dict(enumerate("CASE CIRCLE FILL ORIGIN POINT RECTANGLE SWAP WHILE WAIT MOUSE QUIT SYS "
                    "INSTALL LIBRARY TINT ELLIPSE BEATS TEMPO VOICES VOICE STEREO OVERLAY".split(), 0x8E))
T.update({0xC6: None, 0xC7: None, 0xC8: None, 0xC9: "WHEN", 0xCA: "OF", 0xCB: "ENDCASE",
          0xCC: "ELSE", 0xCD: "ENDIF", 0xCE: "ENDWHILE", 0xCF: "PTR", 0xD0: "PAGE",
          0xD1: "TIME", 0xD2: "LOMEM", 0xD3: "HIMEM"})


def line_ref(b):
    b0, b1, b2 = b
    lo = (b1 ^ ((b0 << 2) & 0xC0)) & 0xFF
    hi = (b2 ^ ((b0 << 4) & 0xC0)) & 0xFF
    return lo | hi << 8


def detok(data):
    out, p = [], 0
    while p < len(data):
        if data[p] != 0x0D:
            raise ValueError("bad line start at %d" % p)
        if data[p + 1] == 0xFF:                 # end of program (line numbers go to 65279)
            break
        num = data[p + 1] << 8 | data[p + 2]
        ln = data[p + 3]
        body = data[p + 4:p + ln]
        s, i, quote, rem = [], 0, False, False
        while i < len(body):
            c = body[i]
            if c == 0x7F and not (quote or rem):
                s.append("OTHERWISE")
                i += 1
                continue
            if quote or rem or c < 0x7F:
                if c == 0x22:
                    quote = not quote
                s.append(chr(c) if 32 <= c < 127 else "\\x%02x" % c)
                i += 1
                continue
            if c == 0x8D:
                s.append(str(line_ref(body[i + 1:i + 4])))
                i += 4
                continue
            if c in (0xC6, 0xC7, 0xC8):
                tab = {0xC6: C6, 0xC7: C7, 0xC8: C8}[c]
                s.append(tab.get(body[i + 1], "?%02x%02x" % (c, body[i + 1])))
                i += 2
                continue
            w = T.get(c, "?%02x" % c)
            s.append(w)
            if w == "REM":
                rem = True
            i += 1
        out.append("%5d %s" % (num, "".join(s)))
        p += ln
    return "\n".join(out) + "\n"


if __name__ == "__main__":
    sys.stdout.write(detok(open(sys.argv[1], "rb").read()))
