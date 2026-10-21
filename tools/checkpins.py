#!/usr/bin/env python3
"""Check that a Quartus build put every user I/O exactly where pins.tcl says.

Usage: checkpins.py project_dir/project.pin project_dir/pins.tcl

Fails (exit 1) if any user signal in the .pin report has no location assignment in pins.tcl
or sits on a different pin, i.e. if the fitter placed something by itself. A core with an
auto-placed pin could drive a random board net, so the Makefile refuses to make the .cor.
"""
import re
import sys

pin_rpt, tcl = sys.argv[1], sys.argv[2]
want = {}
for line in open(tcl):
    m = re.match(r'\s*set_location_assignment\s+PIN_(\w+)\s+-to\s+(\S+)', line)
    if m:
        want[m.group(2).strip('{}"')] = m.group(1)
got = {}
for line in open(pin_rpt):
    f = [x.strip() for x in line.split(':')]
    # "signal : pin : direction : standard : ..." lines; skip power/reserved/GND entries
    if len(f) > 4 and re.fullmatch(r'[A-Z]{1,2}\d{1,2}', f[1]) and f[2] in ('input', 'output', 'bidir'):
        if f[0] and f[0] not in ('TCK', 'TDI', 'TDO', 'TMS') and \
                not f[0].startswith(('GND', 'VCC', 'RESERVED', 'altera_reserved', '~')):
            got[f[0]] = f[1]
bad = []
for sig, pin in sorted(got.items()):
    if sig not in want:
        bad.append(f'{sig} on {pin}: no location assignment')
    elif want[sig] != pin:
        bad.append(f'{sig} on {pin}, pins.tcl says {want[sig]}')
for sig in sorted(set(want) - set(got)):
    print(f'note: {sig} ({want[sig]}) assigned but not in the design')
if bad:
    print('PIN CHECK FAILED:\n  ' + '\n  '.join(bad))
    sys.exit(1)
print(f'pin check: {len(got)} user I/Os, all as assigned')
