#!/usr/bin/env python3
"""Check that every top-level port bit of a yosys netlist has a pin in the .qsf (open flow).

Usage: checkqsf.py design.json design.qsf

nextpnr places an unconstrained I/O on any free pin, which on the Super Nt could drive a random
board net, so the Makefile runs this before nextpnr and stops on a missing assignment.
"""
import json
import re
import sys

net = json.load(open(sys.argv[1]))
top = next(m for n, m in net['modules'].items() if m.get('attributes', {}).get('top'))
want = set()
for name, p in top['ports'].items():
    n = len(p['bits'])
    want |= {name} if n == 1 else {f'{name}[{i}]' for i in range(n)}
have = set()
for line in open(sys.argv[2]):
    m = re.match(r'\s*set_location_assignment\s+PIN_\w+\s+-to\s+(\S+)', line)
    if m:
        have.add(m.group(1).strip('{}"'))
missing = sorted(want - have)
if missing:
    sys.exit('QSF CHECK FAILED, no pin for: ' + ' '.join(missing))
print(f'qsf check: {len(want)} port bits, all assigned')
