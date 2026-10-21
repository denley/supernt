#!/usr/bin/env python3
"""Make a `ghdl synth --out=verilog` netlist usable next to main.v in Verilator.

Usage: ghdl_fix.py file.v prefix top main.v

- Every module except `top` gets `prefix` (each GHDL output carries its own copy of shared
  entities such as the 65C816).
- GHDL names an instance output net `<inst>_<port>`, which can collide with a VHDL signal of
  the same name (e.g. signal SRTC_DO and instance SRTC's port DO). It then declares the wire
  twice and writes `assign srtc_do = srtc_do;`. The signal is just a copy of the port, so the
  second declaration and the self-assignment are dropped.
- Top ports take the case main.v uses for the pin (VHDL is case-insensitive; main.v mixes
  `.mclk` and `.DBG_BG_EN`); others are lower-cased.
- An `enable` input of SA1Map/DSP_LHRomMap is removed and tied to 1: they declare
  `ENABLE : in std_logic := '1'`, main.v leaves it unconnected, and the VHDL default is lost in
  the netlist (notes/snes-port.md).
- `parameter USE_DSPn = 0;` is added to DSP_LHRomMap (main.v passes it; the netlist is
  synthesised with -gUSE_DSPn=0).
- GHDL's `--latches` turns `when others => null` in combinational case statements into
  `default: x = x;`; those become don't-cares, as Quartus treats them (full case).
"""
import re
import sys

f, prefix, top, mainv = sys.argv[1:5]
s = open(f).read()
mv = open(mainv).read()
inst = re.search(r'^%s\b.*?^\);' % re.escape(top), mv, re.M | re.S)   # its instance in main.v
pins = {p.lower(): p for p in re.findall(r'\.(\w+)\s*\(', inst.group(0))}

# Duplicate wire declarations (per module).
out, ndup = [], 0
for mod in re.split(r'(?=^module )', s, flags=re.M):
    seen = set()
    lines = []
    for ln in mod.split('\n'):
        m = re.match(r'\s*wire\s+(?:\[[^\]]*\]\s*)?(\w+);', ln)
        if m:
            if m.group(1) in seen:
                ndup += 1
                continue
            seen.add(m.group(1))
        m = re.match(r'\s*assign\s+(\w+)\s*=\s*(\w+);', ln)
        if m and m.group(1) == m.group(2):
            continue
        lines.append(ln)
    out.append('\n'.join(lines))
s = ''.join(out)

names = [n for n in re.findall(r'^module (\S+)', s, re.M) if n != top]
for n in names:
    s = re.sub(r'^module %s\b' % re.escape(n), 'module %s%s' % (prefix, n), s, flags=re.M)
    s = re.sub(r'^(\s+)%s(\s+(#\(|\S+\s*\())' % re.escape(n), r'\g<1>%s%s\2' % (prefix, n), s,
               flags=re.M)

i = s.index('module %s\n' % top)
j = s.index('endmodule', i)
body = s[i:j]
hdr_end = body.index(');')
hdr = body[:hdr_end]
for p in re.findall(r'(?:input|output|inout)\s+(?:\[[^\]]*\]\s*)?(\w+)', hdr):
    want = pins.get(p.lower(), p.lower())
    if p != want:
        body = re.sub(r'\b%s\b' % re.escape(p), want, body)
hdr_end = body.index(');')
m = re.search(r'\n\s*input\s+enable,', body[:hdr_end])
if m and top in ('SA1Map', 'DSP_LHRomMap'):
    body = body[:m.start()] + body[m.end():]
    hdr_end = body.index(');')
    body = body[:hdr_end + 2] + "\n  wire enable = 1'b1; // VHDL port default (ghdl_fix.py)" + body[hdr_end + 2:]
if top == 'DSP_LHRomMap':
    hdr_end = body.index(');')
    body = body[:hdr_end + 2] + '\n  parameter USE_DSPn = 0; // ghdl_fix.py' + body[hdr_end + 2:]
s = s[:i] + body + s[j:]

s, nl = re.subn(r"default: (\S+) = \1;", r"default: \1 = 'bx; // ghdl_fix.py: was a latch", s)
open(f, 'w').write(s)
print(f'{f}: {len(names)} modules prefixed, {ndup} duplicate wires merged, '
      f'{nl} latch defaults made don\'t-care')
