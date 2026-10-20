# supernt

Reverse engineering the Analogue Super Nt jailbreak firmware, with the long-term goal of running
our own FPGA cores on it (an SNES core with SA-1 support).

Nothing from Analogue or the jailbreak author is committed here: `make` downloads the jailbreak
into `firmware/` (gitignored) and everything else is derived from it locally.

## Layout

- `tools/` – scripts and small C++ tools built on [mistral](https://github.com/Ravenslofty/mistral)
  (open-source Cyclone V bitstream library, checked out at `~/src/vendor/mistral`).
  - `bitrev.py` – `.cor` ⇄ `.rbf` (jailbreak cores are bit-reversed raw bitstreams).
  - `mistral-patch` – `mistral-cv` plus a `patch base.rbf edits.bt out.rbf` command that applies
    `.bt` lines on top of an existing bitstream, so bits mistral doesn't print survive.
  - `mkcor.py` – turns a patched `.rbf` back into a `.cor`, copying every unchanged frame from the
    original verbatim (mistral's EDCRC differs from Quartus' in MLAB frames).
  - `pins.py` – per-pin I/O summary of a `.bt` decompile; `trace.py` – walk routing back/forward.
- `patches/*.bt` – edits applied to `spc.cor` to make `out/spc-<name>.cor`.
- `notes/` – findings, in more detail than below.

`make` builds everything; `make out/spc-colortest.cor` builds one test core.

## Findings so far (Oct 2026, jailbreak JB7.2)

- `snt_firmware_verJB7.2.bin` (8.7 MB) is encrypted: uniform ~8 bits/byte entropy, incompressible,
  no structure. Not attacked.
- `SYSTEM/CORES/spc.cor` (the SPC music player, loaded from SD) is **an unencrypted, unsigned,
  uncompressed Cyclone V `.rbf` with each byte bit-reversed**. mistral decodes it with zero errors
  (≈155k routes, 907 LABs, 351 MLABs, 121 M10Ks, 52 DSPs, 4 fPLLs, 1 hard memory controller).
- The die is the Cyclone V E "e50f" (5CEBA2/5CEBA4, 25k/49k LE; same die as the Analogue Pocket's
  main FPGA). Package assumed F23 (484-pin) – **unconfirmed**; pin names below depend on it.
- Round trip: decode → re-encode reproduces every configuration bit; a no-op patch through
  `mistral-patch` + `mkcor.py` is byte-identical to the original `.cor`.
- Clocks (decoded fPLL settings): board reference is **74.25 MHz**. One PLL makes exactly
  21.4773 MHz (NTSC SNES master clock); others make 148.5 MHz (1080p60 pixel clock) and
  12.288 / 3.072 MHz (I2S MCLK/BCLK for 48 kHz audio). One PLL's reconfiguration port is wired
  to logic, so clocks are retuned at runtime.
- The right-hand I/O bank (pins K17–T22, F23 names) is the HDMI transmitter interface:
  27 registered outputs on one clock (24-bit RGB + HS/VS/DE), 2 outputs on an audio clock
  (I2S LRCLK/data) and 3 pins driven straight from clock networks (pixel clock, MCLK, BCLK).
  16 of the video pins are fed directly from M10K RAM outputs, so they are colour bits.

## Test core: `out/spc-colortest.cor`

Inverts the 16 RAM-fed colour pins with the I/O cell's own output inverter; nothing else changes
(2 configuration frames). Expected result if the console runs it: the SPC player's picture has
scrambled colours with stable sync. Electrically it only changes logic levels on pins that were
already outputs.
