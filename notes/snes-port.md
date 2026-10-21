# Porting the openfpga-SNES (MiSTer) core with SA-1: open-flow feasibility (Oct 2026)

We tried to build the Analogue Pocket port of the MiSTer SNES core (agg23 openfpga-SNES,
`~/src/vendor/openfpga-SNES` at 1a08c84, mostly srg320's VHDL) with the open-source flow from
`notes/toolchain.md`, with SA-1 enabled. Everything generated is in `~/scratch/snes-port`, not in this
repo; the paths below are relative to that directory.

## Verdict

- **The front end works.** GHDL 5.0.1 (`ghdl synth --out=verilog`) plus yosys 0.52 read and
  elaborate the whole core (VHDL, SV, Verilog) after small mechanical patches and behavioural
  stand-ins for the Altera megafunctions. `synth_intel_alm` maps the SA-1 build in ~6 min.
- **It fits the device on paper**, without DSP blocks: about 20.2k LUTs + 3.4k carry cells (an
  estimated 13–17k of the 18,480 ALMs), 7.0k FFs, and 282 of 308 M10Ks.
- **Placement fails.** nextpnr-mistral cannot place the SA-1 build: the HeAP legaliser gives up
  ("Unable to find legal placement for all cells, design is probably at utilisation limit") and the
  SA placer stalls in initial placement. Even the plain SNES build (no SA-1, ~49% of LUT sites) had
  not legalised its LUTs after ~30 min. The causes are nextpnr-mistral's ALM model and legaliser,
  plus the lack of DSP support, not the device size: Quartus fits this core plus GSU, CX4 and DSPn
  on the same part for the Pocket.

  The pieces work in isolation. The SA-1 on its own places and routes in 87 s with Fmax 29 MHz
  (needs 21.5), and `sdram.sv` reaches 108 MHz (needs 86).
- **So, today: Quartus is needed for an SA-1 SNES on this board.** The open flow is still useful for
  the board bring-up cores (video, SDRAM, PIC32 link, controllers). Making it build this core needs,
  in order:
  1. DSP block support in nextpnr-mistral (saves ~4k LUTs);
  2. a fix for ALM/LAB legalisation at ~70–90% LUT use;
  3. PLL support, a third global clock or LAB clock inversion, and true dual-port M10K;
  4. a source-level port of the VHDL, not a GHDL netlist.

  These are all nextpnr/mistral work, measured in weeks.

### Place and route results (nextpnr-mistral 6b438a1c, `--threads 2`)

Clocks were constrained by SDC to 21.477 MHz (`clk_sys`, pin W16) and 85.909 MHz (`clk_mem`,
pin H16); the dummy top has 3 other pins. In the table, "COMB" is nextpnr's LUT-site count (2
per ALM).

| Netlist | Device use reported by nextpnr | Result |
|---|---|---|
| SA-1 build, DSPs inferred | – | fails at once: no bel for `MISTRAL_MUL18X18` |
| SA-1 build, `-nodsp` (as synthesised) | 3 `MISTRAL_CLKBUF` / 2 | fails: "no BELs remaining to implement cell type 'MISTRAL_CLKBUF'" (`clk_sys`, `clk_mem` and the inverted `clk_sys` for `CEGen`) |
| SA-1 build, `-nodsp`, 3rd clock buffer removed | COMB 23,726/36,960 (64%), FF 6,972 (9%), M10K 282/308 (91%) | **HeAP: "Unable to find legal placement for all cells"** after ~9 min (also with `--placer-heap-beta 0.6`). `--debug-placer` shows the legaliser ripping up `MISTRAL_ALUT6` cells hundreds of times each. **SA placer**: initial placement stalled at 25,000/30,982 cells for 25 min (killed). |
| SA-1 build, `abc9 -maxlut 4` (no 5/6-LUTs) | COMB 31,571 (85%) | HeAP fails the same way after ~3 min |
| SNES without SA-1, `-nodsp` | COMB 18,442 (49%), M10K 280 | HeAP: M10K and FF legalised, then the first LUT legalisation pass ran for ~28 min without finishing (killed after 34 min in total) |
| **SA-1 alone** (`SA1Map` + 65C816 + IRAM, shift-register wrapper) | COMB 5,765, FF 1,235, M10K 2 | **routes in 87 s. Fmax `clk_sys` 29.2 MHz** (critical path 34.3 ns = 4.0 ns logic + 30.2 ns routing, 65C816 AddrGen → SA-1 bus). Passes 21.48 MHz with ~36% margin |
| **SDRAM controller alone** (`sdram.sv`) | COMB ~350, FF 518 | **routes in 14 s. Fmax `clk_mem` 108.5 MHz** (passes 85.9 MHz) |

The timing figures use nextpnr's mistral model (sx120f 1.1 V/100 °C cells, simulated routing; no
speed grades), so treat them as rough. In a full, congested chip the SA-1/CPU paths will be slower
than the block-level 29 MHz. The real core runs at 21.48 MHz on MiSTer and the Pocket (Quartus),
with multicycle behaviour hidden behind clock enables.

## What was built

### File list and top

The Pocket build is `projects/snes_pocket.qsf` → `rtl/snes.qip` → `rtl/upstream/snes_mister.qip`, with
`target/pocket/core_top.sv` as the top (APF bridge, PLLs, PSRAM, scaler hooks). The parts kept were:

- **VHDL** (`rtl/upstream`):
  - CPU core: `65C816/*`.
  - SMP and S-DSP: `SPC700/*`, `CEGen.vhd`, `DSP_PKG.vhd`, `DSP.vhd`, `SMP.vhd`.
  - CPU, WRAM, PPU and the console top: `CPU.vhd`, `SWRAM.vhd`, `PPU_PKG.vhd`, `PPU.vhd`, `SNES.vhd`.
  - Chips: `chip/SRTC.vhd`, `chip/RTC4513.vhd`, `chip/DSP/{DSPn,OBC1,DSP_LHRomMap}.vhd`,
    `chip/SA1/*`.
  - RAM wrappers: `bram.vhd`, `mlab.vhd`.
- **Verilog/SV**:
  - `main.v` (module `main`): the SNES plus cartridge-chip mux, all memories external.
  - `cheatcodes.sv`, `ioport.sv`, `lightgun.sv`, `sdram.sv`.
  - `rtl/mister_top/SNES.sv` (module `MAIN_SNES`), the Pocket's wrapper with memories and controller
    plumbing.
- **Our top**: `top/snt_snes.sv`, a copy of MAIN_SNES with the board-specific parts changed:
  - PSRAM removed. WRAM (128 KB) and ARAM (64 KB) moved into M10K, VRAM (2 × 32 KB) stays in M10K.
  - BSRAM moved from M10K (128 KB on the Pocket) to SDRAM port 1, next to the ROM on port 0.
- **Dummy top**: `top/top.v`, generated by `gen_top.py`. It has 2 clock pins (W16, H16), all 258
  core inputs from a shift register on one pin (T12), and all 119 outputs XOR-reduced per clock
  domain onto N20/N19 so nothing is optimised away. It is never meant for hardware.
- Build options: `USE_SA1=1`, everything else 0 (`USE_SS=0`, so no save states).

Clocks are as on MiSTer and the Pocket:

- `MCLK = ACLK = clk_sys` = **21.477 MHz (N = 1)**. CPU, PPU, SMP, DSP and SA-1 all run on it
  through clock enables (`CEGen`, `SYSCLKF_CE`/`SYSCLKR_CE`).
- `clk_mem` = **85.909 MHz (4×)** for the SDRAM controller.
- The Pocket also has 5.37 MHz video (plus a 90° copy) from the same PLL.
- On the Super Nt, FPLL.000.000 in spc.cor already runs its VCO at 601.36 MHz from 74.25 MHz. /28
  gives 21.477 MHz and /7 gives 85.909 MHz, so one fPLL covers both clocks.

### Altera primitives, and the stand-ins used (`repl/`)

| Where | Primitive | Stand-in | Mappable by the open flow? |
|---|---|---|---|
| `bram.vhd` spram/spram_sz (PPU HOAM, SA-1 IRAM 2 KB, DSPn/CX4 ROMs) | `altsyncram` SINGLE_PORT, MIF init | inferred RAM, MIF → `.hex` read with textio at ghdl-synth time (`mif2hex.py`) | yes (M10K) |
| `bram.vhd` dpram/dpram_dif (DSP REGRAM, BRR_BUF, PPU CGRAM, OAM 16/32 mixed width, MAIN_SNES VRAM/BSRAM) | `altsyncram` BIDIR_DUAL_PORT, clock enables, mixed widths | two write ports **merged into one** (B has priority); mixed width split into narrow banks | only after the merge. CGRAM (reset clear), VRAM/WRAM/ARAM (clear on load) and BSRAM (save port) really use two write ports |
| `bram.vhd` dpram_difclk (GSU cache, CX4 data RAM) | `altsyncram` with clock0 = `not CLK`, clock1 = `CLK` | literal two-clock model | **no**: M10K in nextpnr has one clock. Not in the SA-1 build |
| `mlab.vhd` (PPU RANGE_TBL), `CX4/cx4cache.vhd` | `altdpram` MLAB, async read | inferred LUTRAM | yes (MLAB, no init needed) |
| `SA1/SA1MULT.vhd` | `lpm_mult` 16×16 signed | `*` | in LUTs only (`-nodsp`) |
| `sdram.sv` SDRAM clock | `altddio_out` | `assign out = clk ? h : l` | as a fabric clock mux only; no DDIO in nextpnr |
| Pocket PLLs (`mf_pllbase`, `pll_reconfig`) | `altera_pll` + `altera_pll_reconfig` | dropped; the clocks are top-level pins in the dummy top | **no** (PLL work in progress) |
| Pocket `psram.sv`, `mf_ddio_bidir_12`, `mf_datatable`, sync_fifo etc. | Pocket/APF only | not used | – |

### Source patches needed (all small; copies in `patched/`)

GHDL (VHDL-2008 with `-fsynopsys -frelaxed -fexplicit`) and the yosys SV front end are stricter
than Quartus:

- `CPU.vhd`: a case statement without `when others`.
- `DSP.vhd`: a process variable assigned only in the clocked branch ("clocked logic requires clocked
  logic on else part").
- `DSPn.vhd`, `CX4Map.vhd`: operand length mismatches that Quartus silently extends.
- `GSU.vhd`: one process has both a `falling_edge` and a `rising_edge` branch, which GHDL can't
  synthesise. Not fixed; GSU was dropped from the tests.
- **Latches**: 16 combinational case statements in the 65C816 (both copies), SPC700 and PPU end in
  `when others => null`. GHDL turns them into latches on the metavalue path, plus 2 combinational
  loops (PPU `main_en`/`sub_en`, DSP_LHRomMap `CC_SR`). Quartus treats these as full cases.
  `fix_latches.py`/`fix_loops.py` rewrite the generated Verilog's defaults to `'bx`, using the sites
  that yosys `proc`/`scc` report. A real port should add explicit defaults in the VHDL instead.
- **VHDL port defaults are lost at the VHDL→Verilog boundary.** `SA1Map`, `DSP_LHRomMap` and
  `CX4Map` have `ENABLE : in std_logic := '1'`, which `main.v` leaves unconnected. In the GHDL
  netlist that input is undriven, and yosys silently optimised the entire SA-1 away (first run: 3
  LUTs). Fixed with explicit `.enable(1'b1)`. Watch for this on any GHDL-converted entity.
- VHDL port names keep their declared case in GHDL's output, but `main.v` connects them in a
  different case, so the top ports were lower-cased (`prefix_mods.py`). Each GHDL output carries its
  own copy of the shared entities (`p65c816`, `alu`, …), so modules are prefixed per file.
- yosys SV gaps: unpacked array assignment patterns (`'{...}` in `ioport.sv`, `sdram.sv`),
  initialised regs declared inside `always` blocks (`sdram.sv`), an unpacked struct array driven
  from `always_comb` (`sdram.sv state[5]`, reported as a latch), an `always_comb` loop variable
  (`cheatcodes.sv`), and `$info`. All of these fail loudly except wire arrays assigned element by
  element (`ioport.sv JOYSTICK[4]`), which silently end up undriven. sv2v would probably handle
  all of them.
- Bidirectional buses (`sdram.sv`, `psram.sv`, MAIN_SNES) were split into `_o/_oe/_i` triples. We
  need that anyway: yosys leaves `$_TBUF_` cells that nextpnr can't place (`notes/toolchain.md`),
  so pads have to be `MISTRAL_IO` instances.
- Negative-edge flops: `CEGen` (used by the S-DSP) clocks on `falling_edge`. yosys makes an
  inverted copy of `clk_sys` and gives it a third `MISTRAL_CLKBUF`, and nextpnr has only 2 global
  clocks ("no BELs remaining to implement cell type 'MISTRAL_CLKBUF'"). For the experiment that
  buffer is removed (`repl/clkbuf_bypass.v`, fabric-routed clock for 33 FFs). Real fixes: LAB
  clock inversion in nextpnr, or more globals.

### Timings (this box: 4 cores, 15 GB)

| Step | Time | Peak memory |
|---|---|---|
| `ghdl -a` all VHDL | 0.3–0.5 s | – |
| `ghdl synth` SNES / SA1Map / DSP_LHRomMap (with DSPn ROMs) | 2 s / 0.4 s / 3.5 s | – |
| yosys read + elaborate | ~14 s | – |
| yosys `proc; flatten; opt -full` (latch/loop checks) | ~60 s (135 s for SA1+CX4+DSPn) | – |
| `synth_intel_alm -nodsp`, SA-1 build | 6–6.5 min | 1.2 GB |
| `synth_intel_alm` (DSP inference), SA-1 build | 5.8 min | 1.0 GB |
| `synth_intel_alm -nodsp`, SA1+CX4+DSPn | 9 min | 1.7 GB |
| nextpnr-mistral, SA-1 build: read JSON, pack, set up M10Ks, then HeAP until it gives up | ~9 min total | ~1 GB |
| nextpnr-mistral, SA-1 block alone / SDRAM controller alone (full P&R) | 87 s / 14 s | – |

## Resource numbers

### Open flow (yosys `synth_intel_alm`)

The ALM estimate is a range:

- **Low**: every ALUT6 takes a whole ALM, everything else pairs up perfectly.
- **High**: ALUT6 and ALUT5 each take an ALM, smaller LUTs pair up, and carry cells go two per ALM.

| Build | LUTs (2/3/4/5/6-input) | Carry | FFs | M10K | MLAB cells | DSP | ALMs (estimate) |
|---|---|---|---|---|---|---|---|
| SNES only, no SA-1, `-nodsp` | 15,617 (2014/2869/2792/5910/2032) | 2,698 | 5,979 | 280 | 15 | 0 | 10.2–13.1k |
| **SA-1**, `-nodsp` | **20,235** (2468/4198/3701/7359/2509) | 3,359 | **6,972** | **282** | 15 | 0 | **13.1–16.7k** |
| SA-1, DSPs inferred | 16,256 | 3,382 | 6,972 | 282 | 15 | 17 (10 × 18×18, 7 × 9×9) | 10.8–14.0k |
| SA-1, `abc9 -maxlut 5` | 22,649 (no 6-LUTs) | 3,341 | 6,972 | 282 | 15 | 0 | 13.0–17.5k |
| SA-1, `abc9 -maxlut 4` | 28,059 4-LUTs | 3,380 | 6,972 | 282 | 15 | 0 | ~15.7k (two 4-LUTs always share an ALM) |
| SA-1 + CX4 + DSPn, `-nodsp` | 27,063 | 4,040 | 8,872 | **330 (> 308)** | 263 | 0 | 17.3–22.2k |

The device has 18,480 ALMs (36,960 LUT/COMB sites), 73,920 FFs, 308 M10K and 66 DSP blocks.

- **Per block, SA-1 build, `-nodsp`** (LUTs/FFs/M10K):

  | Block | LUTs | FFs | M10K |
  |---|---|---|---|
  | S-DSP | 5,914 | 1,483 | 4 |
  | CPU (5A22 + 65C816) | 5,546 | 1,386 | 0 |
  | **SA-1** | **4,998** | **930** | **2** |
  | PPU | 3,923 | 1,505 | 4 |
  | SMP | 1,040 | 337 | 16 |
  | DSP_LHRomMap (OBC1/SRTC) | 467 | 162 | 0 |

  The SA-1 includes its 16×16 multiplier and divider in LUTs.
- **M10K, SA-1 build**: WRAM 128 + ARAM 64 + VRAM 64 + 26 others (16 of them the SPC700 microcode
  ROM). Only 26 blocks are left for a line buffer, the scaler and other extras.
- **DSP inference saves ~4k LUTs (20%)**, but nextpnr can't place them: "no BELs remaining to
  implement cell type 'MISTRAL_MUL18X18'". Most of the 17 multipliers are in the S-DSP (echo FIR,
  volume, Gaussian interpolation), plus the PPU (mode 7), CPU and SA-1.
- **SA-1 + CX4 + DSPn doesn't fit with WRAM/ARAM in M10K** (330 > 308). The Pocket keeps those in
  PSRAM. The CX4's dual-clock data RAM was not validated in this run.

### Quartus reference: Pocket `snes_main.rbf`

This is the agg23 0.4.4 release, built in Nov 2022 (an older revision than the checked-out
source), with SA-1 + GSU + CX4 + DSPn. Counts come from `build/pocket/snes_main.bt`:

- LABs with any setting: 1,359 LAB + 483 MLAB = **1,842 of ~1,848 (100%)**.
- **18,208 ALMs with a programmed LUT mask (98.5% of 18,480).**
- 32 MLABs in RAM mode.
- **257 M10K** (VRAM 64 + BSRAM 128 + DSPn ROMs + GSU/CX4/SA-1 RAMs; WRAM/ARAM live in the
  Pocket's PSRAM).
- **32 DSP blocks**.
- 2 fPLLs.

So Quartus fills the chip with roughly 1.5× our SA-1-only logic: it uses the DSP blocks and packs
ALMs much more densely (shared/extended modes, register packing). spc.cor (the SPC player) uses
1,246 LABs+MLABs, 121 M10K and 52 DSPs for comparison.

## Blockers, by severity

1. **Placement at this size (nextpnr-mistral). Severe, blocks everything.**
   - The ALM model is simple: a 6-LUT takes a whole ALM, two LUTs must fit 64 LUT bits and 8
     inputs, there are no shared or extended modes, a FF needs a free LUT half or an E/F path, and
     a LAB allows one clock and limited ENA/ACLR/SCLR/SLOAD combinations.
   - The HeAP legaliser thrashes well below 100% utilisation: ripping up ALUT6 cells with the
     default mapping, and still failing at 85% LUT sites with a 4-LUT-only mapping.
   - Needs packer/legaliser work in nextpnr (pre-packing LUT pairs into ALMs, or a cluster-based
     legaliser), or a much smaller design.
2. **No DSP blocks. Severe for this core.**
   - It costs ~4k LUTs (20% of the logic), which is what pushes the SA-1 build into the
     legaliser's trouble zone.
   - mistral decodes DSP blocks (spc uses 52, the Pocket SNES 32), so adding a DSP bel plus
     bitstream support is medium work.
3. **No PLL.** The core needs 21.477 MHz and 85.909 MHz, and 74.25 MHz isn't an integer multiple
   of either. The PLL patching already in progress is a must; it is not specific to this core.
4. **Two global clocks only, and no LAB clock inversion.** clk_sys, clk_mem and the inverted
   clk_sys for `CEGen` need three, and a video clock and the audio MCLK/BCLK would add more.
   - Workaround for the experiment: one inverted clock on fabric routing.
   - Real fix: more CMUX indices in `globals.cc` (easy–medium per `toolchain.md`), plus clock
     inversion bits in the LAB.
5. **True dual-port / dual-clock M10K.** The SA-1 build gets by with merged write ports, but only
   because port B writes only while the core is held in reset (RAM clear, save load). The CX4 and
   GSU need both clock edges on the same RAM.
6. **No DDIO for the SDRAM clock.** The forwarded SDRAM clock becomes a fabric mux on `clk_mem`;
   at 86 MHz the phase between that and the fabric-registered address, command and DQ is
   uncontrolled. Usually fixable with an extra PLL output phase-shifted to an ordinary pin, or by
   running SDRAM slower.
7. **GHDL conversion quirks** (latches, lost port defaults, case, duplicate modules). Fine for an
   experiment. For maintenance, either fix the VHDL sources or wait for a ghdl-yosys-plugin package.
   Debian 13 ships `libghdl-dev` and `yosys-dev` (0.52) but no plugin package, so the plugin
   would be a small source build. We used `ghdl synth --out=verilog` instead.

**Not blockers:**

- I/O standards (rbf2cor copies them).
- Logic speed: 21.5 MHz is slow for this part (MiSTer meets it on the same family).
- The resource total: Quartus proves SA-1 + three other chips fit in this die.

## Board-specific work for a Super Nt port

The pin facts below come from `notes/spc-core.md` and `notes/hardware-research.md`.

- **Clocks.**
  - Reference: 74.25 MHz on W16/H16.
  - One fPLL (spc's FPLL.000.000 settings) gives 21.477 MHz (/28) and 85.909 MHz (/7).
  - Video at 720p would use 74.25 MHz directly. Matching 60.0988 Hz SNES frames to 60 Hz HDMI needs
    either a frame buffer (SDRAM) or a slightly retuned SNES master clock (21.477 × 60/60.0988 ≈
    21.442 MHz). spc's runtime-retuned PLL suggests Analogue does something like the latter.
- **SDRAM.** There are two independent buses:
  - **x16 AS4C8M16SA (16 MB)**: top bank, clock out on H8. This bus can run `sdram.sv` as is (port 0
    ROM, port 1 BSRAM; 13-bit address, 2 banks, DQML/H). SA-1 ROMs are ≤ 4 MB.
  - **x8 pair IS42S81600F (2 × 16 MB)**: banks 2A/3B, clock AB11. The two DQ bytes have separate
    pin groups, so they are probably one 16-bit bus with a shared clock. Address/control sharing
    is unconfirmed.
  - Uses: WRAM/ARAM, if M10K is needed elsewhere, and a frame buffer for scaling.
  - Pin-level mapping still has to be traced from spc.cor (`tools/pinmap.py`). `sdram.sv` was
    written for MiSTer's 32 MB x16 module; the CAS latency and refresh timing must be checked
    against the 166 MHz parts at 86 MHz (CL2 should work).
- **Video out (AD9889B).**
  - 24 RGB pins + HS/VS/DE (P16/M16/M18) + pixel clock (M22), all known from spc.
  - The SNES gives 256/512 × 224/239 at ~5.37 MHz, 15 kHz. We need a scaler to an HDMI mode:
    720p from 74.25 MHz with 3× line repetition plus horizontal scaling, with a line buffer in
    M10K (2–4 blocks).
  - The pixel clock has to leave on M22, which spc drives from a clock network (DDIO or clock-out
    path in nextpnr, or a fabric toggle).
  - Unknown: whether the PIC32 or the core must program the AD9889B over I2C (B11 is the only
    I2C-like pin). `out/vtest.cor` answers part of this.
- **Audio.**
  - I2S on K17/L18 (LRCLK/data) with MCLK/BCLK on L19/L17.
  - The S-DSP produces 32 kHz. Either resample to 48 kHz (spc's PLL makes 12.288/3.072 MHz), or
    set the AD9889B to 32 kHz (N/CTS), if we control its registers.
  - The Pocket's `sound_i2s.sv` is a starting point.
- **Controller ports.**
  - Real SNES ports (J5/J6, transistor level shifting). `MAIN_SNES` already has the MiSTer SNAC
    "raw serial" path (`JOY_STRB`, `JOY1_CLK`/`JOY2_CLK`, `JOY*_DI`, P6/IOBit), which maps
    straight onto pins.
  - The pins are unknown: find them in spc.cor, or by probing.
- **Cartridge slot.**
  - Behind 8 × SN74LVC8T245. A ROM-from-SD core must hold the direction/OE pins in a safe state
    (inputs), which means identifying them first.
  - A cart-based core is the alternative: ROM and any SA-1 stay on the cartridge, and WRAM, VRAM
    and ARAM fit in M10K. That needs the cart bus pin map, but no SDRAM or PIC32 protocol.
- **ROM loading from SD.**
  - The PIC32 reads the SD card. Its link to the FPGA (probably the bank 4A 8-bit bus with one
    shared OE, or 2A/3B if those are not SDRAM) and its protocol are **unknown**.
  - The core needs an `ioctl_*`-style loader (`ioctl_download`, `ioctl_addr`, 16-bit
    `ioctl_dout`, `ioctl_wr`) feeding `sdram.sv` port 0. It also needs the header parse that
    MiSTer does on the ARM side and the Pocket in `rom_parser.sv`: ROM type, size and region give
    `rom_type`/`rom_mask`/`ram_mask`. SA-1 is `rom_type[7:4] = 6`.
  - Saves: the BSRAM write-back path (`sd_*` ports) needs the same link in the other direction.
  - Until the protocol is known, a test core could embed a small ROM in M10K or SDRAM via
    JTAG/bitstream.
- **Menus/OSD, reset, LED.** None of these exist in the core. The PIC32 menu is lost while our core
  runs; power-cycling returns to the stock firmware (per the jailbreak's core loading).

## Reproducing (`~/scratch/snes-port`)

```sh
sudo apt install ghdl                      # 5.0.1; no ghdl-yosys-plugin package in Debian 13
./ghdl_all.sh                              # VHDL -> vlog/*.v (SA-1 build); full.env for +CX4+DSPn
yosys -l logs/latch.log latch.ys; python3 fix_latches.py logs/latch.log
yosys -l logs/loops.log loops.ys; python3 fix_loops.py logs/loopcells.txt
yosys -l logs/synth_nodsp.log synth_nodsp.ys     # -> build/snes_nodsp.json, logs/stat_nodsp.txt
./pnr.sh snes_nodsp heap                   # drops the 3rd CLKBUF, runs nextpnr-mistral
```

`prep.sh` chains the first three steps.
