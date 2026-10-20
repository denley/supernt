#!/usr/bin/env python3
"""Summarise per-pin I/O usage from a mistral-cv .bt decompile.

Usage: pins.py file.bt [--md]

mistral annotates every GPIO setting, inverter and route with the package pin
name after a ';'. This groups those lines per pin and classifies each pin as
input, output, bidirectional (output enable driven from logic) or clock.
"""
import re
import sys
from collections import defaultdict

LINE = re.compile(r'^(?P<kind>[sir]) (?P<body>.*?) ; (?P<pin>\S+)$')
BLOCK = re.compile(r'GPIO\.(\d+)\.(\d+)(?:\.(\d))?:([A-Z_]+)(?:\.(\d+))?')


def main():
    path = sys.argv[1]
    md = '--md' in sys.argv
    pins = defaultdict(lambda: {'set': {}, 'inv': {}, 'routes': [], 'block': None})
    for line in open(path):
        m = LINE.match(line.rstrip('\n'))
        if not m:
            continue
        kind, body, pin = m['kind'], m['body'], m['pin']
        p = pins[pin]
        b = BLOCK.search(body)
        if b and p['block'] is None:
            p['block'] = f'GPIO.{b[1]}.{b[2]}.{b[3] or "?"}'
        if kind == 's':
            key, val = body.split(' ', 1)
            p['set'][key.split(':', 1)[1].rsplit('.', 1)[0]] = val
        elif kind == 'i':
            key, val = body.split(' ', 1)
            p['inv'][key.split(':', 1)[1]] = val
        else:
            p['routes'].append(body)

    rows = []
    for pin, p in pins.items():
        ports_in, ports_out = set(), set()
        for r in p['routes']:
            src, dst = r.split(' ')
            if 'GPIO' in src:
                ports_out.add(src.split(':', 1)[1].split('.')[0])  # pad -> fabric
            if 'GPIO' in dst:
                ports_in.add(dst.split(':', 1)[1].split('.')[0])   # fabric -> pad
        oe_routed = 'OEIN' in ports_in
        data_out = 'DATAOUT' in ports_in or any(k.startswith('DATAOUT') for k in p['inv'])
        data_in = 'DATAIN' in ports_out
        clk = 'CLKIN' in ports_in or 'CLKOUT' in ports_in
        if oe_routed and data_in:
            d = 'bidir'
        elif data_out or oe_routed:
            d = 'out'
        elif data_in:
            d = 'in'
        elif clk:
            d = 'clk'
        else:
            d = '?'
        std = p['set'].get('DRIVE_STRENGTH', '')
        extra = []
        if p['set'].get('USE_OPEN_DRAIN') == '1':
            extra.append('open-drain')
        if p['set'].get('USE_WEAK_PULLUP') == '1':
            extra.append('pullup')
        if clk:
            extra.append('ddio/clk:' + ','.join(sorted(x for x in ports_in if x.startswith('CLK'))))
        rows.append((p['block'] or '', pin, d, std, ' '.join(extra), len(p['routes'])))

    rows.sort()
    if md:
        print('| Block | Pin | Dir | Drive/std | Notes | Routes |')
        print('|---|---|---|---|---|---|')
        for r in rows:
            print('| ' + ' | '.join(str(x) for x in r) + ' |')
    else:
        for r in rows:
            print('%-16s %-5s %-6s %-22s %-30s %d' % r)
        print(f'{len(rows)} pins', file=sys.stderr)


if __name__ == '__main__':
    main()
