#!/usr/bin/env python3
"""Make GSU.vhd digestible for `ghdl synth` (simulation only; Quartus takes the original).

Usage: gsu_split.py GSU.vhd OUT.vhd

GSU.vhd has processes (three in this version) of the form

    process(CLK, RST_N) [variable ...] begin
        if RST_N = '0' then <reset>
        elsif falling_edge(CLK) then <F>
        elsif rising_edge(CLK) then <R>
        end if;
    end process;

which GHDL's synthesis rejects ("synchronous code does not expect else part"). If no signal is
assigned in both <F> and <R>, the process is two independent register sets, and splitting it
into a falling-edge process and a rising-edge process, each with the reset assignments of its
own signals, is equivalent. The script checks that condition and fails otherwise.
"""
import re
import sys

src = open(sys.argv[1]).read()
lines = src.split('\n')

ASSIGN = re.compile(r'^\s*([A-Za-z_]\w*)\s*(?:\([^;]*?\))?\s*(?:\.\w+\s*)?<=', re.M)


def assigned(text):
    return {m.group(1).upper() for m in ASSIGN.finditer(text)}


out, i, n_split = [], 0, 0
while i < len(lines):
    line = lines[i]
    if re.match(r'\s*process\s*\(\s*CLK\s*,\s*RST_N\s*\)', line):
        # find the end of this process
        j = i
        while not re.match(r'\s*end process', lines[j]):
            j += 1
        body = lines[i:j + 1]
        text = '\n'.join(body)
        fe = [k for k, l in enumerate(body) if re.match(r'\s*elsif falling_edge\(CLK\) then', l)]
        re_ = [k for k, l in enumerate(body) if re.match(r'\s*elsif rising_edge\(CLK\) then', l)]
        if fe and re_ and fe[0] < re_[0]:
            f0, r0 = fe[0], re_[0]
            begin = next(k for k, l in enumerate(body) if re.match(r'\s*begin\s*$', l))
            ifrst = next(k for k, l in enumerate(body) if re.match(r"\s*if RST_N = '0' then", l))
            # the process's closing "end if;" is the last one before "end process"
            endif = max(k for k, l in enumerate(body) if re.match(r'\s*end if;', l))
            head = body[:begin + 1]                 # process(...) + variables + begin
            rst = body[ifrst + 1:f0]
            fbody = body[f0 + 1:r0]
            rbody = body[r0 + 1:endif]
            fa, ra = assigned('\n'.join(fbody)), assigned('\n'.join(rbody))
            both = fa & ra
            if both:
                sys.exit(f'process at line {i + 1}: signals assigned on both edges: {sorted(both)}')
            # split the reset statements: one statement per assignment (may span lines)
            stmts, cur = [], []
            for l in rst:
                cur.append(l)
                if ';' in l:
                    stmts.append(cur)
                    cur = []
            if cur:
                sys.exit(f'process at line {i + 1}: unterminated reset statement')
            rst_f, rst_r = [], []
            for st in stmts:
                names = assigned('\n'.join(st))
                if not names:
                    continue
                name = next(iter(names))
                if name in fa:
                    rst_f += st
                elif name in ra:
                    rst_r += st
                # signals reset but assigned on neither edge: constant after reset; keep on R
                else:
                    rst_r += st
            for edge, rs, bd in (('falling', rst_f, fbody), ('rising', rst_r, rbody)):
                out += head
                out.append(body[ifrst])
                out += rs if rs else ['\t\t\tnull;']
                out.append(f'\t\telsif {edge}_edge(CLK) then')
                out += bd
                out.append(body[endif])
                out.append(body[-1])
                out.append('')
            n_split += 1
            i = j + 1
            continue
    out.append(line)
    i += 1

if n_split < 2:
    sys.exit(f'expected to split at least 2 processes, split {n_split}')
open(sys.argv[2], 'w').write('\n'.join(out))
print(f'gsu_split: split {n_split} processes')
