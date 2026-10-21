#!/usr/bin/env python3
"""Turn an open-flow pin file (hw/<name>/<name>.qsf, location assignments only) into Quartus pin
settings: the same locations plus 50 ohm series termination on every non-input pin, matching how
spc.cor configures its outputs (notes/spc-core.md).

Usage: qsf2quartus.py hw/<name>/<name>.qsf hw/<name>/<name>.v > pins.tcl
Port directions are read from the Verilog `input`/`output` declarations of module `top`.
"""
import re
import sys

qsf, verilog = sys.argv[1:3]
src = open(verilog).read()
inputs = set()
for m in re.finditer(r'\binput\s+(?:wire\s+)?(?:\[[^\]]+\]\s*)?(\w+)', src):
    inputs.add(m.group(1))
print(f'# Generated from {qsf} by tools/qsf2quartus.py')
for line in open(qsf):
    f = line.split()
    if len(f) == 4 and f[0] == 'set_location_assignment':
        pin, port = f[1], f[3]
        print(f'set_location_assignment {pin} -to {port}')
        if port.split('[')[0] not in inputs:
            print(f'set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITHOUT CALIBRATION" -to {port}')
