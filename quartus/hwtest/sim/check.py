#!/usr/bin/env python3
"""Check the hwtest simulation (make sim-hwtest): convert the frame to PNG and decode the I2S
stream in both framings. Each 96-sample segment should be a clean sine (small sample-to-sample
steps, ~0.9 full scale) in the framing the core says it is playing, and broken in the other.

Usage: check.py DIR   (DIR holds hwtest.ppm and i2s.txt)
"""
import subprocess
import sys

import glob
import os
d = sys.argv[1]
for ppm in glob.glob(f'{d}/hwtest-*.ppm'):
    subprocess.run(['convert', ppm, ppm[:-4] + '.png'], check=True)
    os.remove(ppm)

bits = [tuple(map(int, l.split())) for l in open(f'{d}/i2s.txt')]   # lrclk, data, mode
starts = [i for i in range(1, len(bits)) if bits[i][0] != bits[i - 1][0]]


def word(i, n=24):
    v = 0
    for k in range(n):
        v = v << 1 | bits[i + k][1]
    return v - (1 << n) if v >> (n - 1) else v


rows = []
for i in starts:
    if i + 26 >= len(bits):
        break
    if bits[i][0] == 0:   # left channel slot; mode as logged when its MSB went out
        rows.append((word(i), word(i + 1), bits[i + 1][2]))
# Group consecutive samples by the mode the core reported; score each group (skipping the
# first and last two samples around a switch): max |step| / amplitude.
groups, cur = [], []
for r in rows:
    if cur and r[2] != cur[-1][2]:
        groups.append(cur)
        cur = []
    cur.append(r)
ok = len(groups) >= 4
for gi, part in enumerate(groups[1:], 1):   # the first group may start mid-way
    part = part[2:-2]
    expect = 'I2S' if part[0][2] == 0 else 'LJ'
    res = []
    for k, name in ((1, 'I2S'), (0, 'LJ')):
        v = [r[k] for r in part]
        amp = max(abs(x) for x in v)
        step = max(abs(a - b) for a, b in zip(v, v[1:]))
        res.append((name, amp / (1 << 23), step / max(amp, 1)))
    good = [n for n, a, st in res if 0.85 < a < 0.95 and st < 0.2]
    flag = 'ok' if good == [expect] else 'BAD'
    ok &= flag == 'ok'
    print(f'group {gi} ({len(part)} samples, expect {expect}): ' +
          '  '.join(f'{n} amp {a:.2f} step {st:.2f}' for n, a, st in res) + f'  {flag}')
print('PASS' if ok else 'FAIL')
sys.exit(0 if ok else 1)
