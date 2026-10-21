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
  - `pins.py` – rough per-pin I/O summary; `pinmap.py` – traced per-pin drivers/loads (follows
    the memory-controller bypass); `trace.py` – walk routing back/forward; `ffsrc.py` – follow
    flip-flops back through buffer LUTs and E/F bypasses.
  - `m10k.py` – dump block RAM contents (layout in `notes/spc-core.md`).
  - `cvinfo` – package pins and PLL clock-input pins from mistral's database.
  - `rbf2cor` – turn a nextpnr-built `.rbf` into a `.cor` with spc's options and I/O standards.
- `patches/*.bt` – edits applied to `spc.cor` to make `out/spc-<name>.cor`.
- `hw/<name>/` – our own designs, built with yosys + nextpnr-mistral into `out/<name>.cor`
  (`notes/toolchain.md`; no Quartus needed).
- `notes/` – findings, in more detail than below.

`make` builds the tools and the test cores; `make out/spc-colortest.cor` builds one, `make
out/blinky.cor` builds `hw/blinky` (first `make` of it also builds nextpnr, see `notes/toolchain.md`).

## Findings so far (Oct 2026, jailbreak JB7.2)

- `snt_firmware_verJB7.2.bin` (8.7 MB) is encrypted: uniform ~8 bits/byte entropy, incompressible,
  no structure. Not attacked.
- `SYSTEM/CORES/spc.cor` (the SPC music player, loaded from SD) is **an unencrypted, unsigned,
  uncompressed Cyclone V `.rbf` with each byte bit-reversed**. mistral decodes it with zero errors
  (≈155k routes, 907 LABs, 351 MLABs, 121 M10Ks, 52 DSPs, 4 fPLLs; the hard memory controller is
  only used in bypass mode, i.e. as plain I/O).
- The FPGA is a **5CEBA4F23C8N** (Cyclone V E, 49k LE, 484 pins; same part as the Analogue Pocket's
  main FPGA), read from board photos. Other parts: AD9889B HDMI transmitter, PIC32MX470 (SD card,
  menus, loads cores), 48 MB SDR SDRAM (one x16 + two x8 chips), SN74LVC8T245 level shifters on the
  cart bus (`notes/hardware-research.md`).
- Round trip: decode → re-encode reproduces every configuration bit; a no-op patch through
  `mistral-patch` + `mkcor.py` is byte-identical to the original `.cor`.
- Clocks (decoded fPLL settings): board reference is **74.25 MHz**, on pins **W16 and H16**. One PLL makes exactly
  21.4773 MHz (NTSC SNES master clock); others make 148.5 MHz (1080p60 pixel clock) and
  12.288 / 3.072 MHz (I2S MCLK/BCLK for 48 kHz audio). One PLL's reconfiguration port is wired
  to logic, so clocks are retuned at runtime.
- The right-hand I/O bank (pins K17–T22, F23 names) is the HDMI transmitter interface:
  27 registered outputs on one clock (24-bit RGB + HS/VS/DE), 2 outputs on an audio clock
  (I2S LRCLK/data) and 3 pins driven straight from clock networks (pixel clock, MCLK, BCLK).
  The 24 colour pins are fed from a video RAM; a proposed per-channel pin order is in the notes.
- Block RAM layout (x1 and x20 modes) solved against the Pocket SNES core's known ROMs, so RAM
  contents can be read and rewritten.
- Two more 8-bit buses (banks 2A/3B) look like the x8 SDRAM pair; bank 4A's 8-bit bus is the best
  candidate for the PIC32 link.

## Test cores

Each replaces `SYSTEM/CORES/spc.cor` (keep the original). All only flip output inverters on pins
the SPC core already drives (2 configuration frames), so electrically they only change logic
levels on existing outputs.

- `out/spc-colortest.cor` – inverts 16 colour pins. Expected: the SPC player's picture with
  scrambled colours and stable sync.
- `out/spc-invert-ch{1,2,3}.cor` – invert one proposed colour channel each. Expected on the mostly
  grey player screen: a clear tint (cyan if that channel is red, magenta if green, yellow if blue).
  Tells us whether the channel grouping is right and which channel is which.
- `out/blinky.cor` – our first core built from scratch (open-source flow): a counter on the W16
  clock driving one HDMI colour pin. Nothing visible is expected; it only shows whether the console
  accepts a non-Quartus bitstream (no hang/error).
