# Open-source FPGA flow for the Super Nt (no Quartus)

yosys (`synth_intel_alm`) → nextpnr-mistral → `.rbf` → `tools/rbf2cor` → `.cor`. Tested Oct 2026
on a counter design (`hw/blinky`). It produces a bitstream that is structurally the same as the
Quartus-built `spc.cor`: same size, uncompressed, byte-identical option frame. **Not yet run on
the console.**

## Setup (Debian 13)

```sh
sudo apt install yosys libboost-dev libboost-filesystem-dev libboost-thread-dev \
  libboost-program-options-dev libboost-iostreams-dev libboost-system-dev libeigen3-dev python3-dev
make $HOME/src/vendor/nextpnr/build-mistral/nextpnr-mistral   # clones + builds as below
git clone https://github.com/Ravenslofty/mistral.git ~/src/vendor/mistral-nextpnr
git -C ~/src/vendor/mistral-nextpnr checkout nextpnr-latest          # 6a97d3e
git clone https://github.com/YosysHQ/nextpnr.git ~/src/vendor/nextpnr  # tested at 6b438a1c
cd ~/src/vendor/nextpnr && mkdir build-mistral && cd build-mistral
cmake .. -DARCH=mistral -DMISTRAL_ROOT=$HOME/src/vendor/mistral-nextpnr -DCMAKE_BUILD_TYPE=Release -DBUILD_GUI=OFF
make -j4 nextpnr-mistral                                             # 10-15 min on this box
```

- yosys 0.52 (Debian package) has `synth_intel_alm` (Cyclone V is its default family).
- **Two mistral checkouts.** `~/src/vendor/mistral` (master, d509238, used by `tools/`) renamed
  its core types (`pos_t` → `xycoords` etc.) and nextpnr hasn't caught up, so nextpnr won't
  compile against it. nextpnr's README points at mistral's `nextpnr-latest` branch, which is
  `~/src/vendor/mistral-nextpnr` (6a97d3e). The bitstream code (`cv-files.cc`, `cv-opt.cc`) only
  differs in those type renames. nextpnr built against 6a97d3e and against d6bd02c (master just
  before the renames) wrote byte-identical bitstreams for the blinky.

## Building a core

```sh
make out/blinky.cor
```

This runs:

```sh
yosys -p 'read_verilog hw/blinky/blinky.v; synth_intel_alm -top top -nodsp; write_json build/hw/blinky.json'
nextpnr-mistral --device 5CEBA4F23C8 --json build/hw/blinky.json --qsf hw/blinky/blinky.qsf --rbf build/hw/blinky.rbf
tools/rbf2cor 5CEBA4F23C8 build/hw/blinky.rbf build/spc.rbf out/blinky.cor
```

A new design goes in `hw/<name>/` with Verilog sources (top module `top`) and `<name>.qsf`, and is
built with `make out/<name>.cor`. The whole flow for the blinky takes about 10 s; rbf2cor takes
most of that because it loads mistral twice.

Constraints: nextpnr-mistral reads a `.qsf` and acts **only on**
`set_location_assignment PIN_xx -to port` (bus bits as `-to name[3]`).
`set_instance_assignment` is parsed but ignored, and `set_global_assignment` is a no-op. Every
I/O must be constrained, otherwise it stops with "unconstrained IO". With no clock constraint the
timing target is 12 MHz; use `--freq <MHz>` for a real target.

## Bitstream: nextpnr output vs spc.rbf

nextpnr calls mistral's `CycloneV::rbf_save` (`mistral/main.cc`), after
`MistralBitgen::options()` (`mistral/bitstream.cc`):

```cpp
if (!ctx->setting<bool>("compress_rbf", false)) {         // default: uncompressed
    cv->opt_b_set(CycloneV::COMPRESSION_DIS, true);
    cv->opt_r_set(CycloneV::OPT_B, 0xffffff40adffffffULL);
} else                                                    // --compress-rbf
    cv->opt_r_set(CycloneV::OPT_B, 0xffffff402dffffffULL);
```

| | nextpnr default | spc.rbf (Quartus) |
|---|---|---|
| Size | 2,632,660 bytes | 2,632,660 bytes |
| COMPRESSION_DIS | 1 (uncompressed) | 1 (uncompressed) |
| OPT_B | `ffffff40.adffffff` | `ffffff40.2dffffff` |
| JTAG_ID (user code) | `ffffffff` (default, not set) | `03cbd16e` |
| Everything else in the option frame | defaults | defaults |

So nextpnr's uncompressed output already has the right layout: 628-byte option frame,
64 × 524 PRAM, 4958 × 524 CRAM frames, and the same postamble. Only 19 option-frame bytes differ:

- **OPT_B bit 31**: byte 132, mask 0x08 in `.rbf` order. nextpnr's comment ties `ad…` to
  uncompressed output, but Quartus' uncompressed spc.cor has `2d…`, so the bit means something
  else (unknown). rbf2cor copies spc's value.
- **JTAG_ID**: 16 bytes. It is a user code; Quartus' value is *not* mistral's
  `compute_default_jtag_id()` (the CRAM byte sum of spc is `03c8a83c`). Whether the jailbreak
  loader looks at it is unknown, so rbf2cor copies spc's value (`--jtag-id` to override).
- The option frame's CRC16: bytes 294–295.

**Byte 272 is not a whole "compression byte".** It holds bit 35 of option strips 0–7.
COMPRESSION_DIS is mask **0x02** in `.rbf` order (**0x40** in `.cor` order), and JTAG_ID owns mask
0x01 (0x80). spc has 0x1a in `.rbf` order (0x58 in `.cor` order), which is uncompressed. Its
compressed equivalent would be 0x18 (`.cor` 0x18). Found by toggling each option in libmistral
and diffing `rbf_save` output.

### tools/rbf2cor

`tools/rbf2cor model in.rbf ref.rbf out.cor [--jtag-id ref|sum|keep|<hex>] [--keep-io]`
(source `tools/src/rbf2cor.cc`, built by `make tools/rbf2cor`):

1. Loads the design (compressed or not) and the reference core (`build/spc.rbf`) with libmistral.
2. Copies **every** option from the reference and forces COMPRESSION_DIS on, so the option frame
   is byte-identical to spc's.
3. Copies the reference core's per-pad `DRIVE_STRENGTH` (I/O standard) onto every pad the design
   uses (see I/O below). `--keep-io` skips this.
4. Saves uncompressed, then re-loads its own output. It compares every block setting, route,
   inverter and option with the design, checks that a second save gives identical bytes, and
   only then bit-reverses and writes the `.cor`. Exit code 3 on any difference.

Verified for the blinky. `mistral-cv decomp` of the bit-reversed `out/blinky.cor`, compared with
the decompile of nextpnr's own rbf, differs only in the intended lines:

```
< o OPT_B ffffff40.adffffff
> o JTAG_ID 03cbd16e
> o OPT_B ffffff40.2dffffff
< s GPIO.054.018:DRIVE_STRENGTH.2 V3P3_LVTTL_16MA_LVCMOS_2MA ; N20
> s GPIO.054.018:DRIVE_STRENGTH.2 V2P5_50OHM ; N20
```

The libmistral round trip reports 0 differences, also for M10K and MLAB test designs and for
`--compress-rbf` input. Compressed input gives the identical `.cor`.

Side notes:

- `mistral-cv decomp` → `mistral-cv comp` (via the text `.bt`) is *not* bit-exact even for
  nextpnr's raw output: one CRAM bit (LAB 039.013 area, frames 3558/3560) moves. spc.rbf loses
  bits the same way. That is why `mistral-patch` exists. Check round trips at the libmistral
  level (as rbf2cor does) or by comparing decompiles, not by `comp`-ing a `.bt`.
- mistral computes the per-frame EDCRC (bytes 516–519 of each CRAM frame) over the whole frame.
  Quartus evidently doesn't for MLAB frames: re-saving spc.rbf changes the EDCRC + CRC16 of
  exactly 160 frames, the ones holding MLAB bits. EDCRC is the SEU-scrubbing CRC, and spc has
  CRC_ERROR_DETECTION off (copied into our cores), so it probably doesn't matter. For the first
  hardware tests, though, prefer designs without MLABs (`synth_intel_alm -nolutram`). The
  blinky uses none.

## What nextpnr-mistral supports (checked in source, nextpnr 6b438a1c)

Sources: `nextpnr/mistral/{arch,pack,bitstream,lab,m10k,io,globals,qsf,delay}.cc`,
`/usr/share/yosys/intel_alm/common/*`. Throwaway probe designs: `~/scratch/supernt-flow/feat/`.

| Feature | Status | Detail |
|---|---|---|
| LUTs (ALUT2–6), FFs | **yes** | Normal and arithmetic ALM modes. FF with CLK/ENA/ACLR/SCLR/SLOAD (3 clk+ena pairs and 2 ACLRs per LAB). No shared-arith or extended (7-input) modes. |
| Carry chains | **yes** | `MISTRAL_ALUT_ARITH`, chained across LABs. |
| MLAB (LUT RAM) | **partial** | 32×1 simple dual port, sync write, async read. **No initial contents** (bitstream.cc: `TODO: LUTRAM init`; the yosys rule has `init 0`), so initialised ROMs go to M10K/logic. |
| M10K | **partial** | Simple dual port (1 write + 1 read port), **one shared clock**, read enable, write enable, 8192×1 … 256×40 (no ×8/×16/×32: byte-wide memories use ×10/×20 shapes). Initial contents supported. **No** true dual port, no second clock, no byte enables, no mixed widths, no ACLR/clock enables, no output register (output_sel ASYNC). 308 blocks on 5CEBA4. |
| DSP (hard multipliers) | **no** | yosys maps `*` to `MISTRAL_MUL9X9/18X18/27X27`, but nextpnr has no DSP bel ("no BELs remaining to implement cell type 'MISTRAL_MUL9X9'"). Use `synth_intel_alm -nodsp` (the Makefile does) and multipliers become LUTs. A 9×9 registered multiplier took ~150 LUTs. |
| fPLL / `altera_pll` | **no** | No PLL bel; `altera_pll` (in yosys' blackbox lib) fails placement. |
| Global clocks | **partial** | Clock nets get a `MISTRAL_CLKBUF` and are routed onto global networks through CMUXHG, but only **from general routing** (`INPUT_SEL` hardcoded 0x1b, only index 2 of each CMUXHG: "TODO: why do other Zs not work?"). So: **at most 2 global clocks** (utilisation shows `MISTRAL_CLKENA 1/2`), no dedicated clock-pin → global path, no regional clocks, no clock enable on the buffer. Further clocks run on fabric routing. |
| I/O buffers | **partial** | `MISTRAL_IB/OB/IO`, location only. **I/O standard, drive, slew, pull, termination are not configurable**: outputs are hardcoded to `V3P3_LVTTL_16MA_LVCMOS_2MA`, weak pull-up off, inputs left at the default standard. The Super Nt banks the SPC core uses are set `V2P5_50OHM`; rbf2cor copies that per pin. |
| Bidirectional pins | **yes, with a workaround** | Inferred `assign io = oe ? x : 1'bz` that is also read back leaves a `$_TBUF_` in yosys 0.52 that nextpnr can't place. Instantiating `MISTRAL_IO iob(.PAD(io), .I(out), .OE(oe), .O(in))` works, and the OE inverter setup matches spc's bidirectional pins (e.g. D3). |
| I/O registers, DDIO, delay chains, DQS | **no** | Every I/O goes straight to fabric. No `altddio_*` (fails placement), no IOE input/output/OE registers, no I/O delays, no LVDS/differential, no OCT. GPIOs in the HMC's banks *are* usable as plain I/O (nextpnr routes them through the HMC bypass). |
| Hard memory controller (HMC) | **no** | Not modelled at all. |
| Internal oscillator | places | `cyclonev_oscillator` bel exists and routes; bitstream.cc writes no oscillator settings. Untested. |
| Timing | approximate | Cell delays from the sx120f 1.1 V/100 °C corner (no speed grades); routing delays from mistral's analogue simulator. The blinky reports ~220 MHz. No SDC; use `--freq`. |

## Gaps that matter for a SNES core, and effort

- **VHDL / SystemVerilog input** (not nextpnr, but blocks porting existing cores).
  `~/src/vendor/openfpga-SNES` (the Pocket SNES core, same e50f die, MiSTer-derived) is
  ~29k lines VHDL, ~5k SV, ~2k Verilog. Debian ships GHDL 5.0.1 but no ghdl-yosys-plugin.
  `ghdl synth --out=verilog` can turn the VHDL into Verilog for yosys, or the plugin can be built
  from source. SystemVerilog may need sv2v. That core also instantiates `altsyncram`, `altera_pll`
  + `altera_pll_reconfig`, DDIO-bidir and Altera multipliers, so all of those need open
  replacements (inferred RAM, the PLL work below, plain I/O, `*`).
- **PLLs: medium, the key gap.** mistral already decodes everything needed:
  - spc's fPLL settings (`s FPLL.…` lines: M/N/C counter hi/lo, fractional value, CP/BW,
    `CLKIN_n_SRC`).
  - The fixed links pin → `FPLL:CLKIN.n` and `FPLL:PLLCOUT.n` → `CMUX*:PLLIN.m`.
  - The CMUX input matrix (`INPUT_SEL` 0x08–0x17 = `PLLIN.0–15`, 0x00–0x07 = clock pins via pre-muxes,
    0x1b = general routing; `docs/gendoc/cmuxhg-links.rst`).

  Two routes:
  1. *Hack, roughly 100 lines of tooling.* Feed the design's clock nets from spare input pins so
     nextpnr routes them CMUXHG → global. Afterwards, patch that CMUXHG's `INPUT_SEL` from 0x1b to
     the right `PLLIN.n`, add the fPLL `s` lines copied from spc.bt (FPLL.000.000 already makes
     21.4773 MHz from 74.25 MHz), and drop the dummy pin route. Timing analysis is then blind to
     the PLL, but at SNES speeds that's fine.
  2. *Proper.* Add an FPLL bel plus dedicated-pin and PLL inputs to the CMUX bels in nextpnr, and
     write the counter settings in bitstream.cc: a few hundred lines of C++. Other frequencies
     need the counter encoding understood; mistral's names make it mostly mechanical. Copy CP/BW
     from a spc PLL with a similar VCO.

  Without a PLL you only have the board reference (74.25 MHz, probably W16, see below) and
  fabric dividers of it. 21.477 MHz isn't an integer division of it.
- **More global clocks: easy–medium.** Lifting the "index 2 only, general routing only" limit in
  globals.cc needs the other CMUXHG/CMUXVG indices and the clock-pin `INPUT_SEL` values. All of
  that is documented in mistral and visible in spc (which uses CMUXHG.000.022 indices 0–3 and
  CMUXVG/CMUXVR).
- **I/O standards: easy.** Done in post-processing by rbf2cor. Proper fix: read an `IO_STANDARD`
  attribute in `write_io_cell` (bitstream.cc).
- **I/O registers / DDIO: medium–hard.** Needed for tight external-bus timing and for driving a
  clock out to the HDMI transmitter the way spc does (3 pins straight from clock networks). At
  SNES-cart-bus speeds fabric I/O is fine. Video at 1080p (148.5 MHz) from fabric registers
  across 27 pins is risky; a lower HDMI mode (480p/720p) chosen when we program the transmitter
  is much easier.
- **True dual-port / dual-clock M10K: medium.** Mostly bitstream bits plus pin mapping; spc uses
  121 M10Ks in whatever modes Quartus picked, which gives reference encodings. Until then,
  CPU/PPU-shared RAMs must be time-multiplexed or written as simple-dual-port.
- **DSP: medium, low priority.** SNES-sized multipliers (8×8, 16×8, the SA-1's 16×16) fit in
  LUTs.
- **HMC + DDR: hard.** The HMC is a large hard block, and Quartus normally pairs it with a soft
  calibration sequencer. Copying spc's HMC settings plus its sequencer logic is a project in
  itself. Without it there's no usable external DDR (no DDIO/DQS either).
- **Memory budget without DDR.** 308 M10Ks used as bytes give 308 KB. SNES WRAM 128 KB + VRAM
  64 KB + ARAM 64 KB + CGRAM/OAM ≈ 257 KB, which fits with ~50 blocks left for everything else.
  That works for a core that runs a real cartridge (ROM and any SA-1 stay on the cart). ROMs
  loaded from SD need external RAM, which means the HMC.

## Reference clock pin (likely W16 / H16)

Each fPLL's reference mux (`CLKIN_0/1_SRC`) chooses among four dedicated pins, wired by fixed
p2p links (`FPLL:CLKIN.n` ← `GPIO:COMBOUT`). `make tools/fpllpins && tools/fpllpins` lists them
(mistral-cv's own `p2p` dump is garbled in d509238):

| fPLL | CLKIN.0 | CLKIN.1 | CLKIN.2 | CLKIN.3 | spc `CLKIN_0_SRC` |
|---|---|---|---|---|---|
| FPLL.000.000 | M9 | N9 | V15 | **W16** | 7 |
| FPLL.054.000 | V15 | **W16** | N16 | – | 5 |
| FPLL.000.037 | E10 | G10 | H13 | **H16** | 7 |
| FPLL.054.037 | H13 | **H16** | – | – | 5 |

If `src = 4 + n` selects `CLKIN.n` (mistral marks the encoding TODO; its defaults are 2 and 3),
both bottom PLLs take W16 and both top PLLs take H16. That's consistent on all four PLLs, and in
spc both W16 and H16 are pure inputs (only `USE_WEAK_PULLUP 0`, no drive or OE settings). By
contrast V15, H13 and N9 are driven outputs and M9 is set up like an output. So the 74.25 MHz
reference is probably W16 and/or H16 (maybe one oscillator on both, maybe two). It's a
hypothesis until a scope or test core confirms it. `hw/blinky` clocks from W16.

## hw/blinky

26-bit counter clocked from W16, MSB on N20 (an HDMI colour pin spc already drives, so
electrically safe). It checks the flow; nothing visible will happen on the TV without the HDMI
transmitter being set up. A useful first hardware test still needs a visible output (LED pin
unknown) or a patch of spc that we know is observable.
