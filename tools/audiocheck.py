#!/usr/bin/env python3
"""Analyse the sound of a console video for the hwtest audio framing test.

Usage: audiocheck.py video.mov [FFMPEG]

quartus/common/i2s_test.sv alternates every 4 s between I2S framing with a 440 Hz sine and
left-justified framing with an 880 Hz sine; the framing that matches the AD9889B plays a clean
tone, the other a harsh distorted one. For each 0.5 s window this prints the strongest
frequency, how much of the energy sits in 440 Hz / 880 Hz (fundamental only), and a verdict;
then a summary: which tone is clean. FFMPEG defaults to imageio-ffmpeg's binary in
~/scratch/ffvenv (any ffmpeg works).
"""
import glob
import os
import subprocess
import sys

import numpy as np

video = sys.argv[1]
ff = sys.argv[2] if len(sys.argv) > 2 else (glob.glob(os.path.expanduser(
    '~/scratch/ffvenv/lib/python3*/site-packages/imageio_ffmpeg/binaries/ffmpeg-*')) or ['ffmpeg'])[0]
rate = 48000
raw = subprocess.run([ff, '-v', 'error', '-i', video, '-vn', '-ac', '1', '-ar', str(rate),
                      '-f', 's16le', '-'], capture_output=True, check=True).stdout
x = np.frombuffer(raw, dtype='<i2').astype(np.float64) / 32768
win = rate // 2
f = np.fft.rfftfreq(win, 1 / rate)
hann = np.hanning(win)


def band(spec, hz, w=15):
    return spec[(f > hz - w) & (f < hz + w)].sum()


rows = []
for i in range(0, len(x) - win, win):
    seg = x[i:i + win]
    spec = np.abs(np.fft.rfft(seg * hann)) ** 2
    total = spec[(f > 100) & (f < 12000)].sum() + 1e-12
    p440, p880 = band(spec, 440) / total, band(spec, 880) / total
    peak = f[np.argmax(spec * (f > 100))]
    rms = np.sqrt(np.mean(seg ** 2))
    rows.append((i / rate, rms, peak, p440, p880))
    tag = ''
    if rms > 0.003:
        if p440 > 0.6 and p440 > p880:
            tag = 'clean 440 (I2S)'
        elif p880 > 0.6 and p880 > p440:
            tag = 'clean 880 (left-justified)'
        else:
            tag = 'not a clean tone'
    print(f'{i / rate:6.1f} s  rms {rms:.4f}  peak {peak:7.1f} Hz  440 {p440:.2f}  880 {p880:.2f}  {tag}')
c440 = sum(1 for r in rows if r[1] > 0.003 and r[3] > 0.6 and r[3] > r[4])
c880 = sum(1 for r in rows if r[1] > 0.003 and r[4] > 0.6 and r[4] > r[3])
print(f'\nclean windows: 440 Hz (I2S) {c440}, 880 Hz (left-justified) {c880}')
if c440 > 2 * c880 and c440 >= 2:
    print('=> I2S (AUD_FRAMING = 0)')
elif c880 > 2 * c440 and c880 >= 2:
    print('=> left-justified (AUD_FRAMING = 1)')
else:
    print('=> undecided (check the audio by ear; was the sound on?)')
