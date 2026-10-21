# spc.cor (JB7.2) decode notes

The FPGA is a 5CEBA4F23C8N (F23, 484 pins), read from board photos (`notes/hardware-research.md`).

## Format

- Raw Cyclone V `.rbf`, every byte bit-reversed (`0x6a` option preamble appears as `0x56`).
- Uncompressed, no encryption, nothing appended (ends in `0xff` padding exactly where mistral's own
  uncompressed output ends). No signature visible; whether the loader checks anything is unknown.
- Options: `JTAG_ID 03cbd16e` (user ID, not the device IDCODE), `OPT_B ffffff40.2dffffff`.

## Clocks (fPLL settings, reference 74.25 MHz)

| PLL | VCO | Outputs | Reading |
|---|---|---|---|
| FPLL.000.000 | 601.36 MHz (M=8.0992 fractional) | C0 21.4773 MHz | NTSC SNES master clock |
| FPLL.000.037 | 1188 MHz | C1 148.5, C3 21.6, C6 148.5 MHz | 1080p60 pixel clock; DPRIO wired to logic (retuned at runtime) |
| FPLL.054.000 | 28× ref / N (N not decoded) | C5, C8 = VCO/7, C8 phase-shifted | probably 148.5 MHz + shifted copy for the HDMI chip |
| FPLL.054.037 | 811.04 MHz (142/13) | C7 12.2885, C5 3.0721 MHz, others | I2S MCLK / BCLK for 48 kHz |

## Clock inputs

fPLL `CLKIN_n_SRC` = 4 + n selects dedicated input `CLKIN.n` (calibrated on the Pocket core, whose
`clk_74a` on V15 is `FPLL.054.000:CLKIN.0` with SRC 4). `tools/cvinfo pllin` lists the pins:

| PLL | SRC | pin |
|---|---|---|
| FPLL.000.000 (bottom left) | 7 → CLKIN.3 | W16 |
| FPLL.054.000 (bottom right) | 5 → CLKIN.1 | W16 |
| FPLL.000.037 (top left) | 7 → CLKIN.3 | H16 |
| FPLL.054.037 (top right) | 5 → CLKIN.1 | H16 |

So the board has two clock inputs, **W16 and H16**, both consistent with 74.25 MHz (cf. the Pocket:
`clk_74a` V15, `clk_74b` H16).

## Pin groups

`tools/pinmap.py` (traced drivers/loads per pin, default clock routes ignored) → `build/spc-pinmap.txt`.

- **Board RAM is SDR SDRAM, not DDR** (photos, `notes/hardware-research.md`): one x16
  AS4C8M16SA and a pair of x8 IS42S81600F. The `HMC.011.045:IOINT*` names in the decompile are the
  hard memory controller's *bypass* ports, which is how ordinary fabric I/O reaches top-bank pins
  on this die; they don't mean the HMC is in use. `pinmap.py` follows them (`(via HMC)`), but
  mistral also prints default HMC inverters, so only bypass ports driven from fabric matter.
- **SDRAM clocks**: H8 (top bank) and AB11 (bank 3B) are DDIO output registers with no routed
  data – the usual `altddio_out` constant-data trick for an SDRAM clock. So H8 → the x16 SDRAM on
  the top bank (A–K rows, little used by the SPC player) and AB11 → the x8 pair.
- **Right bank, x=54 (5A/5B): HDMI transmitter.**
  - 24 colour pins, registered in fabric, data from the port A outputs of two x20 M10Ks
    (`M10K.022.023` ports a0–a19, `M10K.022.031` ports b0–b3), traced with `tools/ffsrc.py`.
    21 are straight RAM bits; R22 (a9), P17 (a13) and M21 (a15) go through a LUT that mixes in
    other sources (M21's mixes four more M10Ks – an overlay?).
  - Sync/DE (logic, not RAM): P16, M16, M18.
  - Clock outputs: M22 (from `CMUXHG`, pixel clock), L17 and L19 (from `CMUXVG`, audio MCLK/BCLK).
  - K17, L18: I2S LRCLK/data.
  - Port → pin: a0 N19, a1 N16, a2 P18, a3 P19, a4 T22, a5 R15, a6 T18, a7 T17, a8 R21, a9 R22,
    a10 P22, a11 N20, a12 R17, a13 P17, a14 N21, a15 M21, a16 L22, a17 M20, a18 K22, a19 K21,
    b0 R16, b1 T19, b2 T15, b3 T20.
  - The RAM's initial contents include a 16-entry grey ramp in which bits {a0,a4,a12}
    {a1,a5,a13} … {a11,a19,b3} are always equal, i.e. one bit position per triple, one member per
    channel. With Quartus' MSB-first port order that gives (unconfirmed, and which channel is R/G/B
    is unknown):

    | channel | bit 7 → bit 0 |
    |---|---|
    | ch1 | N19 N16 P18 P19 R21 R22 P22 N20 |
    | ch2 | T22 R15 T18 T17 L22 M20 K22 K21 |
    | ch3 | R17 P17 N21 M21 R16 T19 T15 T20 |
- **Left bank 2A and bottom bank 3B: two 8-bit bidirectional buses** – most likely the DQ buses of
  the two x8 SDRAMs (clock AB11), with address/control on the neighbouring outputs.
  - 2A data D3 E2 L2 L1 G2 G1 C2 C1; outputs W2 AA2 AA1 U2 U1 N2 N1.
  - 3B data AB5 AB6 AB7 AA7 AB8 AA8 AA9 AA10; N8 bidir; outputs N6 P6 M6 P7 R7 P8 M8 R9 AA12.
  - Write data comes straight from the B ports of x2 M10Ks (`011.004`–`007`, `022.004`–`007`,
    4 KB each – write buffers), OEs from fabric FFs, inputs captured with clock enables.
  (An earlier note read these as the PIC32 link; the SDRAM reading fits the photos better.)
- **Bottom bank 4A: classic 8-bit bus** (now the best PIC32-link candidate; or the cartridge data
  bus behind the SN74LVC8T245 level shifters) AB21 AA22 AB22 W22 Y22 W21 Y21 V21 with one shared OE FF
  (`LAB.021.017.0:FFT0`), ~12 outputs (AB12 AB13 AA13 AA14 AA15 AB15 AB17 AB18 AA17 AA18 P14) and
  inputs T12 AB20 AA20 AA19 U22 U21.
- **Open drain**: B11 plus A8 B10 A10 A9 A12 B12 C16 (via HMC bypass) are all driven from the
  same FF (`MLAB.023.040.2:FFT0`); G6 from another. Purpose unknown. The HDMI transmitter is an
  AD9889B (I2C-configured); nothing in this core looks like an I2C master with an init table, so
  the PIC32 probably configures it – unconfirmed.

## Block RAM (M10K) layout

Solved against the Pocket SNES core, whose ROM init files are in its source (`firmware/pocket`,
`~/src/vendor/openfpga-SNES`):

- Stored inverted (empty RAM decodes as all ones), 256 rows × 40 bits (`s M10K…:RAM.n`).
- x1 mode (8192×1): address a → row a>>5; column index c = (a4, a3, a0, a1, a2) as bits 0..4,
  into data columns [0..15, 20..35]. Verified bit-exact against DSP-1 program ROM bit 22.
- x20 mode (512×20): word w → row w>>1; port n lives at physical bit 2·pair(n) + (w&1), with
  pair(n) = 2n for n<10, 2(n−10)+1 for n≥10. Verified against the S-DSP Gaussian table (ports 0–10 =
  table bits 10..0, so Quartus wires data MSB-first).
- Which logical data bit a port carries is decided by routing, not by the layout.
- Contents found in the SPC core: the S-DSP per-voice sequencer (x20 ROM `030.019`, 24-step blocks ×
  8 voices), the Gaussian table (`038.033`), 1-bit ROMs that look like UI graphics, and the video RAM
  above. No HDMI-transmitter init table found.

## Hardware hints from forums (unverified)

- Atari-Forum thread on the Super Nt (https://www.atari-forum.com/viewtopic.php?t=33187): main parts
  reported as a Cyclone V E with 18.5K ALMs (= 5CEBA4, 49K LE) and a **PIC32MX microcontroller
  handling the SD card** and housekeeping. Analogue said the board is virtually the same as the
  Nt Mini's, minus analog AV. If true, cores get SD data from the PIC32 over some bus (the left-bank
  8-bit bus + 7 outputs is a candidate), not by reading the SD card themselves.

## Open questions

- How the SPC data reaches the core (over the PIC32 link, or left in SDRAM by the firmware).
- Which of the 2A/3B/4A buses is the PIC32 link, the cartridge and the controllers; the LED (the
  changelog mentions the SPC core sets the LED colour).
- Whether the core configures the HDMI transmitter (B11 is the only I2C-like pin) or the firmware
  leaves it configured.
- Board revision: a 2023 production run replaced end-of-life parts (`notes/hardware-research.md`);
  the pin map above is from the JB7.2 core, which supports all revisions, so it should hold.
