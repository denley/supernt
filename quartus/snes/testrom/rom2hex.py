#!/usr/bin/env python3
"""Helpers for the SA-1 test ROM (quartus/snes/testrom).

  rom2hex.py in.sfc out.hex NBYTES
      Write NBYTES/2 lines for Verilog $readmemh into a 16-bit wide ROM: line i
      is the little-endian word rom[2i] | rom[2i+1] << 8 from the start of the
      file, as 4 lowercase hex digits.

  rom2hex.py --mirror in.sfc out.sfc [BLOCK]
      Make the 32 KB image the FPGA expects (it keeps BLOCK = 8192 bytes and
      ignores higher ROM address bits): take the last BLOCK bytes of the 32 KB
      asar output (code, header and vectors at $00:E000-$FFFF), check that the
      rest is empty, copy the block to every BLOCK position and write the SNES
      header checksum/complement ($FFDC-$FFDF of each copy).
"""
import sys

ROM_SIZE = 0x8000
CHK_OFF = 0x7FDC  # complement, checksum (file offset in the 32 KB LoROM-style image)


def mirror(src, dst, block):
    data = open(src, 'rb').read()
    if len(data) != ROM_SIZE:
        sys.exit(f'{src}: expected {ROM_SIZE} bytes, got {len(data)}')
    if ROM_SIZE % block:
        sys.exit(f'block size {block} does not divide {ROM_SIZE}')
    blk = bytearray(data[ROM_SIZE - block:])
    if any(data[:ROM_SIZE - block]):
        sys.exit(f'{src}: data outside the last {block}-byte block')
    copies = ROM_SIZE // block
    off = CHK_OFF - (ROM_SIZE - block)
    # Checksum over the whole image with complement/checksum = $FFFF/$0000;
    # every copy's 4 checksum bytes then sum to $1FE whatever their values.
    blk[off:off + 4] = b'\xff\xff\x00\x00'
    chk = (sum(blk) * copies) & 0xFFFF
    blk[off:off + 4] = bytes([~chk & 0xFF, (~chk >> 8) & 0xFF, chk & 0xFF, chk >> 8])
    rom = bytes(blk) * copies
    assert sum(rom) & 0xFFFF == chk
    open(dst, 'wb').write(rom)


def tohex(src, dst, nbytes):
    data = open(src, 'rb').read()
    if nbytes <= 0 or nbytes % 2:
        sys.exit('NBYTES must be a positive even number')
    if len(data) < nbytes:
        sys.exit(f'{src}: only {len(data)} bytes, need {nbytes}')
    with open(dst, 'w') as f:
        for i in range(0, nbytes, 2):
            f.write(f'{data[i] | data[i + 1] << 8:04x}\n')


def main(argv):
    if len(argv) in (3, 4) and argv[0] == '--mirror':
        mirror(argv[1], argv[2], int(argv[3], 0) if len(argv) == 4 else 0x2000)
    elif len(argv) == 3 and not argv[0].startswith('-'):
        tohex(argv[0], argv[1], int(argv[2], 0))
    else:
        sys.exit(__doc__)


if __name__ == '__main__':
    main(sys.argv[1:])
