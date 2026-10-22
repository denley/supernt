#!/usr/bin/env python3
"""Check the hwtest screen simulation (make sim-screen).

Usage: check_screen.py DIR

DIR holds screen.log and screen-PP-FFF.ppm (PP = display page). Converts the frames to PNG,
decodes every bit-image frame (pages 29-35) with tools/bitdump.py and checks its CRC against
the capture's block CRCs at the end of the run (blocks 1-6 are written once) or, for the
screen (block 0, page 29), against one of the screen versions in the history. One bit image
is also turned into a mock photo (perspective, 1.13x scale, blur, noise, JPEG at quality 70)
and must decode the same. Needs testbench output "SCREEN PASS".
"""
import glob
import os
import re
import subprocess
import sys

d = sys.argv[1]
here = os.path.dirname(os.path.abspath(__file__))
bitdump = os.path.join(here, '..', '..', '..', 'tools', 'bitdump.py')
log = open(f'{d}/screen.log').read()
ok = 'SCREEN PASS' in log
for ppm in sorted(glob.glob(f'{d}/screen-*.ppm')):
    subprocess.run(['convert', ppm, ppm[:-4] + '.png'], check=True)
    os.remove(ppm)
m = re.search(r'capture CRCs: blocks ((?:\S+ ){7}\S+)', log)
blocks = m.group(1).upper().split()
hist = {h.upper() for h in re.findall(r'history \d+: .* CRC (\S+)', log)}
print('block CRCs', ' '.join(blocks), '; screen versions', len(hist))


def decode(png):
    out = subprocess.run([sys.executable, '-I', bitdump, png], capture_output=True, text=True)
    m = re.search(r'CRC (\S+)\s+ring errors (\d+)', out.stdout)
    if not m:
        return None, None, out.stdout + out.stderr
    return m.group(1), int(m.group(2)), out.stdout.strip()


n = 0
sample = None
for png in sorted(glob.glob(f'{d}/screen-*.png')):
    page = int(png.split('-')[-2])
    if not 29 <= page <= 35:
        continue
    frame = int(png.split('-')[-1][:3])
    crc, errors, text = decode(png)
    want = hist if page == 29 else {blocks[page - 29]}
    good = crc in want and errors == 0
    print(('ok   ' if good else 'FAIL ') + text)
    ok &= good
    n += 1
    if page == 30 and frame > 2:
        sample = (png, crc)
if n == 0:
    print('FAIL: no bit-image frames')
    ok = False
if sample:
    png, crc = sample
    photo = png[:-4] + '-photo.jpg'
    # 1280x720 -> a 1920x1080 "photo": the picture 1450 px wide, keystoned, blurred, noisy
    subprocess.run(['convert', png, '-resize', '1450x815!', '-bordercolor', 'rgb(60,55,50)',
                    '-border', '235x132', '-virtual-pixel', 'background', '-background',
                    'rgb(60,55,50)', '-distort', 'Perspective',
                    '235,132 250,150  1685,132 1670,120  1685,947 1690,960  235,947 230,930',
                    '-blur', '0x1.1', '-attenuate', '0.4', '+noise', 'Gaussian', '-quality', '70',
                    photo], check=True)
    pcrc, errors, text = decode(photo)
    good = pcrc == crc and errors <= 2
    print(('ok   ' if good else 'FAIL ') + 'mock photo: ' + text)
    ok &= good
print('PASS' if ok else 'FAIL')
sys.exit(0 if ok else 1)
