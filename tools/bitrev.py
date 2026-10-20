#!/usr/bin/env python3
"""Reverse the bit order of every byte: .cor <-> .rbf. Usage: bitrev.py in out"""
import sys

REV = bytes(int(f'{i:08b}'[::-1], 2) for i in range(256))
open(sys.argv[2], 'wb').write(open(sys.argv[1], 'rb').read().translate(REV))
