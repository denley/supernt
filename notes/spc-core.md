# spc.cor (JB7.2) decode notes

Pin names assume the F23 (484-pin) package; the bank/position (`GPIO.x.y.n`) is what the bitstream
actually says. Confirm the package from the chip marking before trusting pin names.

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

## Pin groups

- **Top bank, rows A–K (42 pins)**: driven through the hard memory controller's I/O paths
  (`HMC.011.045:IOINT*`) → external DDR2/DDR3, probably 16-bit.
- **Right bank, x=54 (32 pins, K17–T22)**: HDMI transmitter.
  - 27 registered outputs on clock `CMUXVR.025.045.2`: 24-bit RGB + HS/VS/DE.
  - 16 of those are fed straight from M10K outputs (colour bits):
    N20 P22 K21 R17 R16 T20 P18 K22 T18 M21 P19 N16 R21 R15 N21 T17.
  - The other 11 video-domain pins: P17 T15 N19 M20 T22 T19 (same register cluster, no RAM
    input) and M18 P16 L22 R22 M16 (registered elsewhere; HS/VS/DE candidates).
  - L18 (clocked by the clock that also drives pin L19) and K17 (another clock): I2S LRCLK/data.
  - M22, L17, L19: driven straight from clock networks (pixel clock, MCLK, BCLK).
- **Left bank, x=0 rows 18–21**: 8 bidirectional pins with clock-enabled I/O registers
  (D3 E2 L2 L1 G2 G1 C2 C1) and 7 outputs (W2 AA2 AA1 U2 U1 N2 N1). A synchronous 8-bit bus.
- **Bottom bank**: two 8-bit bidirectional groups (AB5 AB6 N8 AB7 AA7 AB8 AA8 AA9 AA10 and
  AB21 AA22 AB22 W22 Y22 W21 Y21 V21), ~20 outputs, inputs T12 AB20 AA20 AA19 U22 U21, and many
  pins whose output inverter is set but which have no routed data (constant level or tri-stated;
  the OE polarity encoding isn't understood yet). Likely the cartridge bus (via level shifters)
  plus controller ports.
- **Open-drain-style** (OE routed, no data out): J9 J7 K7 (top bank), B11 (open-drain with
  readback) – I2C (HDMI transmitter config?) candidates.

## Open questions

- How the SPC data reaches the core (SD read by the core itself vs handed over in DDR kept in
  self-refresh across reconfiguration).
- Which group is the SD card, the controller ports and the LED (the changelog mentions the SPC
  core sets the LED colour).
- Package and exact part (5CEBA2 vs 5CEBA4) – read the chip marking.
