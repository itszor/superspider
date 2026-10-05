#!/usr/bin/env python3
"""Cross-check SuperSpider's ARM2 decoder (superspider decode) against
capstone and against the projects' spider.py valid_arm2(), on every word of
the four images (PLAN.md phase 2).

Compared, per word:
  - validity: ours undefined vs capstone failing to decode; capstone-only
    decodes are expected for ARMv4+ encodings (listed by mnemonic)
  - plausibility vs valid_arm2 (NV words excluded: valid_arm2 rejects NV
    outright, we decode them as never-executed)
  - branch targets, registers written / read, data-processing immediates
NV words are compared against capstone's decode of the same word with the
condition set to AL (capstone, being ARMv7, decodes NV space as v5+
unconditional instructions).
"""
import collections, importlib.util, json, os, subprocess, sys
import capstone
from capstone import arm_const

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SS = os.path.join(ROOT, '_build', 'default', 'bin', 'main.exe')
IMAGES = ['galdan', 'lemprog', 'lemboot', 'musmod']

spec = importlib.util.spec_from_file_location('spider', os.path.expanduser('~/games/lemmings/ghidra/spider.py'))
spider = importlib.util.module_from_spec(spec)
spec.loader.exec_module(spider)

md = capstone.Cs(capstone.CS_ARCH_ARM, capstone.CS_MODE_ARM)
md.detail = True
REG = {}
for n in range(16):
    pass


def cs_regno(insn, r):
    name = insn.reg_name(r)
    m = {'sb': 9, 'sl': 10, 'fp': 11, 'ip': 12, 'sp': 13, 'lr': 14, 'pc': 15}
    if name in m:
        return m[name]
    if name and name[0] == 'r' and name[1:].isdigit():
        return int(name[1:])
    return None                       # cpsr, apsr, fpscr ...


def parse(line):
    f = line.split()
    d = dict(addr=int(f[0]), word=int(f[1]), kind=f[2])
    for kv in f[3:]:
        k, v = kv.split('=', 1)
        d[k] = v
    d['defs'] = {int(x) for x in d['defs'].split(',') if x}
    d['uses'] = {int(x) for x in d['uses'].split(',') if x}
    return d


def main():
    tot = collections.Counter()
    v4 = collections.Counter()
    diffs = collections.defaultdict(list)
    executed = {}
    for name in IMAGES:
        b = json.load(open(os.path.join(ROOT, 'phase0', 'data', name + '.json')))
        t = json.load(open(os.path.join(ROOT, 'phase0', 'data', name + '.truth.json')))
        executed[name] = {int(x, 16) for x in t['executed']}
        out = subprocess.run([SS, 'decode', b['image'], '%x' % b['base']], capture_output=True,
                             text=True, check=True).stdout
        for line in out.splitlines():
            o = parse(line)
            w, a = o['word'], o['addr']
            nv = w >> 28 == 15
            cw = (w & 0x0FFFFFFF) | 0xE0000000 if nv else w
            cs = list(md.disasm(cw.to_bytes(4, 'little'), a))
            ci = cs[0] if cs else None
            tot['words'] += 1
            tot['nv'] += nv
            ours_undef = o['kind'] == 'undef'
            # validity vs capstone
            if ours_undef and ci is not None:
                v4[ci.mnemonic.rstrip('.w')] += 1
                tot['undef_here_capstone_decodes'] += 1
                continue
            if o['plausible'] == 'false' and not ours_undef and a in executed[name] and not nv:
                diffs['EXECUTED word we call implausible'].append((name, a, w, line))
            if not ours_undef and ci is None:
                key = 'cop' if o['kind'] == 'cop' else o['kind']
                if key == 'cop':
                    tot['cop_capstone_fails'] += 1   # FPA / unknown coprocessors: capstone is ARMv7
                else:
                    diffs['ours valid, capstone fails'].append((name, a, w, line))
                continue
            if ci is None:
                tot['both_undefined'] += 1
                continue
            # plausibility vs valid_arm2 (non-NV)
            if not nv:
                theirs = spider.valid_arm2(w) is None
                ours_pl = o['plausible'] == 'true'
                if theirs != ours_pl:
                    diffs['plausible (ours %s) vs valid_arm2 (%s)' % (ours_pl, theirs)].append(
                        (name, a, w, '%s / %s' % (spider.valid_arm2(w), line)))
                    if ours_pl is False and a in executed[name]:
                        diffs['EXECUTED word we call implausible'].append((name, a, w, line))
            if o['kind'] == 'cop':
                tot['cop'] += 1
                continue                    # capstone's coprocessor register model differs
            tot['compared'] += 1
            # branch target
            if o['kind'] in ('b', 'bl'):
                ct = ci.operands[0].imm if ci.operands else None
                if ct is not None and (ct & 0x3FFFFFC) != int(o['target']):
                    diffs['branch target'].append((name, a, w, '%s vs %x' % (line, ct)))
            # registers
            rr, rw = ci.regs_access()
            cdefs = {cs_regno(ci, r) for r in rw} - {None}
            cuses = {cs_regno(ci, r) for r in rr} - {None}
            if o['kind'] in ('b', 'bl'):
                cdefs |= {15}               # capstone doesn't list pc for branches
                if o['kind'] == 'bl':
                    cdefs |= {14}
            if o['kind'] == 'swi':
                cdefs -= {14}               # capstone: svc writes lr_svc; user r14 is untouched
            mn = ci.mnemonic[:3]
            if o['defs'] != cdefs:
                pat = 'defs %s ours-only %s capstone-only %s' % (mn, sorted(o['defs'] - cdefs), sorted(cdefs - o['defs']))
                if o['kind'] == 'ldr' and o['pre'] == 'false':
                    pat += ' (post-index)'
                diffs[pat].append((name, a, w, '%s | capstone %s %s' % (line, ci.mnemonic, ci.op_str)))
            ou, cu = o['uses'] - {15}, cuses - {15}
            if ou != cu:
                pat = 'uses %s ours-only %s capstone-only %s' % (
                    mn, 'rs/stored' if ou - cu and not cu - ou else sorted(ou - cu), sorted(cu - ou))
                diffs[pat].append((name, a, w, '%s | capstone %s %s' % (line, ci.mnemonic, ci.op_str)))
            if o['kind'] == 'dp' and o.get('imm', '-') != '-':
                ims = [op.imm & 0xFFFFFFFF for op in ci.operands if op.type == arm_const.ARM_OP_IMM]
                if len(ims) == 2:           # non-canonical "#imm8, #rot" form
                    v, r = ims
                    ims = [((v >> r) | (v << (32 - r))) & 0xFFFFFFFF if r else v]
                if ims and int(o['imm']) not in ims:
                    diffs['dp immediate'].append((name, a, w, '%s | capstone %s %s' % (line, ci.mnemonic, ci.op_str)))
    print('words %(words)d (NV %(nv)d), compared %(compared)d, coprocessor %(cop)d, '
          'both undefined %(both_undefined)d, undefined here but capstone decodes %(undef_here_capstone_decodes)d' % tot)
    print('  capstone decodes these as (ARMv4+ / ARMv3+ expected):', dict(v4.most_common(20)))
    print('  coprocessor words capstone cannot decode: %d' % tot['cop_capstone_fails'])
    for k, l in sorted(diffs.items(), key=lambda kv: -len(kv[1])):
        print('%-70s %d' % (k, len(l)))
        for x in l[:2]:
            print('    %-8s %08x %08x  %s' % (x[0], x[1], x[2], x[3][:200]))
    if not diffs:
        print('no disagreements')


if __name__ == '__main__':
    main()
