#!/usr/bin/env python3
"""Per-pin I/O usage from a mistral-cv .bt decompile, ignoring default clock routes.

Usage: pinmap.py file.bt pins.txt [--hmc hmc-bypass.txt] [--all]

pins.txt is `tools/cvinfo pins MODEL` output (pin name -> GPIO block/index/bank);
hmc-bypass.txt is `tools/cvinfo hmc MODEL` output (HMC bypass port -> GPIO port), needed
for top-bank pins the fabric drives or reads through the hard memory controller's bypass.
For each pin prints: bank, what drives DATAOUT and OEIN (traced back to a block
port), how many block ports its DATAIN reaches, and the non-default settings
(open drain, pull-up, I/O standard...). Pins with nothing routed and no
settings are hidden unless --all is given.
"""
import re
import sys
from collections import defaultdict

sys.path.insert(0, __file__.rsplit('/', 1)[0])
import trace  # noqa: E402


def main():
    bt, pinsf = sys.argv[1], sys.argv[2]
    show_all = '--all' in sys.argv
    hmcf = sys.argv[sys.argv.index('--hmc') + 1] if '--hmc' in sys.argv else None
    drv, fan = trace.load(bt)
    # Top-bank pins reach the fabric through the hard memory controller's bypass
    # ports. mistral prints the link only as a comment on HMC inverter lines,
    #   i HMC.011.045:IOINTDQDOUT.8 1 ; C11 ; HMC...:PHYDDIODQDOUT.8 GPIO.032.045.2:DATAOUT.0
    # and most bypass routes have none (r TD... HMC.011.045:IOINTDQDOUT.64 ; K16), so
    # take the full table from mistral's database when given.
    links = []    # (HMC port, GPIO port, from an inverter line)
    for line in open(bt):
        if line.startswith('i HMC') and line.count(' ; ') == 2:
            links.append((line.split()[1], line.rstrip().split()[-1], True))
    if hmcf:
        links += [(*line.split()[:2], False) for line in open(hmcf)]
    for hmc, gpio, inv_line in links:
        if not gpio.startswith('GPIO.'):
            continue
        if gpio.split(':')[1].startswith(('DATAOUT', 'OEIN')):
            if inv_line or hmc in drv:    # an unrouted port with an inverter = constant
                drv.setdefault(gpio, hmc)
        elif hmc in fan and hmc not in fan[gpio]:
            fan[gpio].append(hmc)

    pins = {}
    for line in open(pinsf):
        f = line.split()
        if len(f) >= 2 and f[1].startswith('GPIO.'):
            pins[f[0]] = (f[1], f[-1] if len(f) > 2 else '')

    sets = defaultdict(list)
    invs = defaultdict(dict)
    for line in open(bt):
        if ' ; ' not in line:
            continue
        body, pin = line.rstrip('\n').rsplit(' ; ', 1)
        if line.startswith('s GPIO') or line.startswith('s DQS16'):
            key, val = body[2:].split(' ', 1)
            k = key.split(':', 1)[1]
            if k.startswith(('RB_T9_SEL_EREG_CFF_DELAY', 'INPUT_REG4_SEL', 'IOCSR_STD')):
                continue
            sets[pin].append(f'{re.sub(r"[.][0-9]+$", "", k)}={val}')
        elif line.startswith('i GPIO'):
            port, val = body[2:].split()
            invs[pin][port.split(':', 1)[1]] = val

    print(f'{"pin":5} {"gpio":16} {"bank":4} {"dataout":32} {"oe":32} {"in":>3}  settings')
    for name, (gpio, bank) in sorted(pins.items(), key=lambda kv: kv[1][0]):
        out = oe = ''
        p = f'{gpio}:DATAOUT.0'
        if p in drv:
            out = trace.back(drv, p)[-1]
            if out.startswith('HMC') and out in drv:
                out = trace.back(drv, out)[-1] + ' (via HMC)'
        elif invs[name].get('DATAOUT.0') == '1':
            out = 'const(inv)'
        for k in ('OEIN.0', 'OEIN.1'):
            p = f'{gpio}:{k}'
            if p in drv and (not oe or oe.startswith('HMC')):   # prefer a fabric driver
                oe = trace.back(drv, p)[-1]
                if oe.startswith('HMC') and oe in drv:
                    oe = trace.back(drv, oe)[-1] + ' (via HMC)'
        nin = 0
        for k in range(4):
            for dst in trace.fwd(fan, f'{gpio}:DATAIN.{k}'):
                nin += len(trace.fwd(fan, dst)) if dst.startswith('HMC') else 1
        st = sorted(set(sets[name]) - {'USE_WEAK_PULLUP=0', 'DRIVE_STRENGTH=V2P5_50OHM'})
        if not show_all and not out.startswith(('LAB', 'MLAB', 'M10K', 'DSP', 'HMC', 'FPLL', 'CMUX', 'GPIO', 'DQS')) \
                and not oe and not nin and not st:
            continue
        print(f'{name:5} {gpio:16} {bank:4} {out:32} {oe:32} {nin:3d}  {" ".join(st)}')


if __name__ == '__main__':
    main()
