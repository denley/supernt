# supernt

Reverse engineering the Analogue Super Nt jailbreak firmware, with the long-term goal of running
our own FPGA cores on it (an SNES core with SA-1 support).

**Status (23 Oct 2026): our SNES + SA-1 core loads and runs games from the SD card on the
console.** Current state, how to use it, next steps and the test workflow: `notes/STATUS.md`.

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
    flip-flops back through buffer LUTs and E/F bypasses; `netlist.py` – gate-level netlist
    (LUT equations, FF clock/enable/load/clear) around seed pins/ports, plus a cycle
    simulator for the extracted logic (conventions and evidence in `notes/pic-link.md`).
  - `m10k.py` – dump block RAM contents (layout in `notes/spc-core.md`).
  - `cvinfo` – package pins, PLL clock-input pins and the HMC bypass port ↔ GPIO table
    (`build/hmc-bypass.txt`, used by `pinmap.py`/`netlist.py`) from mistral's database.
  - `rbf2cor` – turn a nextpnr-built `.rbf` into a `.cor` with spc's options and I/O standards.
  - `pllpatch.py` – give our designs fPLL clocks by copying spc's PLL configurations
    (`hw/<name>/pll.cfg`, `notes/pll.md`).
  - `rom2spc.py` – wrap a SNES ROM in an `.spc` the SPC player sends over the link
    (`notes/snes-load.md`); `sdcore` – manage test cores and those files on the SD card.
- `patches/*.bt` – edits applied to `spc.cor` to make `out/spc-<name>.cor`.
- `hw/<name>/` – our own designs, built with yosys + nextpnr-mistral into `out/<name>.cor`
  (`notes/toolchain.md`; no Quartus needed). `make sim-<name>` renders a simulated frame.
- `quartus/<name>/` – Quartus Prime Lite builds (`make out/q-<name>.cor`; `notes/quartus.md`,
  including the two licence rules this project follows). `tools/quartus` runs Quartus with no
  network access.
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
- Two more 8-bit buses (banks 2A/3B) are the x8 SDRAM pair, run as one x16 memory at 115.86 MHz
  with CL3 and full-page bursts (pin map and parameters in `notes/sdram.md`); bank 4A's 8-bit bus
  is the best candidate for the PIC32 link.

## Test cores

`out/q-vtest.cor` and `out/q-buslog.cor` are Quartus builds of the same designs as `out/vtest.cor`
and `out/buslog.cor`. Quartus' timing models are the reference, and all test designs meet timing
there. If an open-flow build misbehaves, try the `q-` one.

`out/q-snes.cor` (Quartus only, `notes/snes-quartus.md`) is the first real core: the MiSTer/Pocket
SNES core with SA-1, all memory in block RAM, a built-in SA-1 test ROM, 720p60 out. It replaces
`SYSTEM/CORES/spc.cor` like the others; pick any `.spc` file to start it. Expected: a
black screen with a green bar at the top and 7 green bars below it (one per SA-1 test; red = that
test failed), a white square creeping right at the bottom (SNES CPU alive) and a faster cyan one
above it (SA-1 alive). Sync order and colour pins are the ones vtest confirmed, so the picture
should be steady. **Take a photo.** Simulated (`make sim-snes`), not yet tried on the console; it
drives only the video pins. Power-cycle to get back to the menu.

`out/q-snes_sdram.cor` (Quartus only, `notes/snes-sdram.md`) is the same core with the cartridge
ROM in the x8 SDRAM pair: it copies the test ROM into SDRAM at start-up and runs from there. Same
expected picture as `q-snes`. Simulated, not yet run on the console; set the read-capture point
from the hwtest SDRAM result first (`quartus/snes_sdram/sdram_cfg.tcl`).

`out/q-snes_load.cor` (Quartus only, `notes/snes-load.md`) loads the game from the SD card: the
SPC player's file browser runs on it, and a ROM wrapped by `tools/rom2spc.py` (a silent `.spc`
with the ROM appended) is sent over the PIC32 link into SDRAM chip B (8-bit), checked against
its CRC-32 on a diagnostics page and started (LoROM/HiROM/SA-1 from the header). Hold
L+R+SELECT for the diagnostics page, L+R+START for the browser. Simulated end to end; test
procedure in the notes.

Console results so far (`notes/hardware-tests.md`): `spc-colortest` loads and runs; `vtest`
gives a picture (sync order 3, colour map in `notes/spc-core.md`).

The cores below replace `SYSTEM/CORES/spc.cor` too (keep the original). The `spc-` ones only
flip output inverters on pins the SPC core already drives (2 configuration frames), so
electrically they only change logic levels on existing outputs.

- `out/spc-colortest.cor` – inverts 16 colour pins. Expected: the SPC player's picture with
  scrambled colours and stable sync.
- `out/spc-invert-ch{1,2,3}.cor` – invert one proposed colour channel each. Expected on the mostly
  grey player screen: a clear tint (cyan if that channel is red, magenta if green, yellow if blue).
  Tells us whether the channel grouping is right and which channel is which.
- `out/vtest.cor` – our own 720p60 video core (open-source flow, 74.25 MHz board clock, no PLL).
  Cycles the HSYNC/VSYNC/DE role of pins P16/M16/M18 through all 6 orders, 8 s each; when the TV
  shows a picture, the 1–6 white boxes at the top say which order works, and 24 stripes below
  (one colour pin each, proposed order) plus a white block check the colour pin map. **Take a
  photo.** A blank screen for the whole ~50 s cycle means the AD9889B isn't left configured for
  us (or the clock/pixel-clock guess is wrong). It doesn't read the controller, so power-cycle to
  get back to the menu.
- `out/plltest.cor` – checks our PLL patching (`notes/pll.md`): same 720p screen and sync cycling
  as vtest, counts 21.477 MHz PLL cycles per frame. Big block solid white = PLL correct, stripes
  = wrong frequency, black = no PLL clock. White-on-black only, so the colour order doesn't matter.
- `out/buslog.cor` – **PIC32 link logger** (all link pins are inputs, it never drives the bus).
  Replace spc.cor, then pick an `.spc` file: the PIC32 talks to it as if it were the SPC player
  and it shows the first transactions as hex on screen (format at the top of
  `hw/buslog/buslog.v`; simulated with `make sim-buslog`). Fixed to the confirmed sync order; the
  page (3 of them) advances every 16 s, so **film the screen for ~1 minute**.
- `out/blinky.cor` – our first core built from scratch (open-source flow): a counter on the W16
  clock driving one HDMI colour pin. Nothing visible is expected; it only shows whether the console
  accepts a non-Quartus bitstream (no hang/error).
