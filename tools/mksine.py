#!/usr/bin/env python3
"""Write a 1024-entry signed 16-bit sine table ($readmemh) at AMP of full scale.

Usage: mksine.py out.hex [AMP]   (default 0.9)
"""
import math
import sys

amp = float(sys.argv[2]) if len(sys.argv) > 2 else 0.9
with open(sys.argv[1], 'w') as f:
    for i in range(1024):
        v = round(amp * 32767 * math.sin(2 * math.pi * i / 1024))
        f.write(f'{v & 0xffff:04x}\n')
