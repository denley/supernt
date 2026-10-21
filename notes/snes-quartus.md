# SNES + SA-1 core for the Super Nt, built with Quartus (milestone 1, Oct 2026)

`make out/q-snes.cor` builds an SNES with SA-1 for the Super Nt from agg23's openfpga-SNES
(srg320's MiSTer SNES core) with Quartus Prime Lite. It needs nothing we haven't identified yet:
no SDRAM, no PIC32 link, no controllers, no audio. A small SA-1 test ROM is built into block RAM,
and the picture goes out as 720p60 on the HDMI transmitter pins. `make sim-snes` simulates the
whole top level and renders the output frames.

**Status:** builds (8.7 min), fits (50% of ALMs, 292/308 M10K), meets timing at every corner
(clk_sys Fmax 32.7 MHz for 21.48 needed, video 143.6 MHz for 74.25), drives only the video pins,
and in simulation runs the SA-1 test ROM to an all-pass screen at 720p with the output
frame-locked to the SNES. **Not yet run on hardware.**

**What you should see on the TV** (`out/q-snes.cor` in place of `SYSTEM/CORES/spc.cor`): 720p,
black screen with a green bar at the top (all tests passed), 7 green bars below it (one per test;
red = that test failed), a white square moving slowly right at the bottom (SNES CPU alive) and a
cyan square above it moving faster (SA-1 alive). While the sync order is still unknown the
picture only appears for the 8 s windows with the right order (the ~48 s cycle repeats); the
number of small white boxes in the top-left corner during that window is the working order + 1
(same as vtest). If the colours are swapped, the green bars show the colour channel the proposed
ch2 pins carry.

## Files

| File | What |
|---|---|
| `quartus/snes/snes.qsf`, `snes.qpf`, `files.tcl` | project; `files.tcl` lists the vendor sources, used in place from `~/src/vendor/openfpga-SNES` (1a08c84), nothing copied |
| `quartus/snes/snes.sdc` | clocks, clock groups, pixel-clock output constraints |
| `quartus/snes/pins.tcl` | same pins and port names as `quartus/vtest` (W16 in, video pins out) |
| `quartus/snes/snes_top.sv` | top `top`: PLL, reset, core, video, output registers, colour mapping, pixel-clock DDIO |
| `quartus/snes/snes_core.sv` | `snes_core`: `main` (the MiSTer SNES core with SA-1) plus all its memories in M10K |
| `quartus/snes/snes_video.sv` | capture into a 16-line ring buffer, 720p timing, scaling, frame lock, sync-order cycling |
| `quartus/snes/snes_pll.v` | `altera_pll`, 74.25 → 21.477272 MHz |
| `quartus/snes/testrom/` | SA-1 test ROM (asar) and `rom2hex.py` |
| `quartus/snes/sim/` | Verilator testbench, simulation models, GHDL conversion fixes |

No vendor file is modified for the Quartus build. The simulation patches three vendor VHDL files
for GHDL (`sim/ghdl.patch`, applied to copies in the work directory) and replaces the Altera RAM
and multiplier wrappers with behavioural VHDL (`sim/*_sim.vhd`, derived from the GPL originals).

## Architecture

```
W16 74.25 MHz ─┬─ altera_pll (fractional) ── clk_sys 21.477272 MHz ── snes_core ── capture ─┐
               │                                                                            │ ring buffer
               └──────────────────────────── clk_vid 74.25 MHz ──── 720p timing ── scaler ──┘ (dual-clock M10K)
                                                                         │
                                         ch1/ch2/ch3, P16/M16/M18 (I/O registers), M22 (DDIO)
```

- `snes_core` instantiates `main` (`rtl/upstream/main.v`) with `USE_SA1 = 1` and every other chip,
  MSU and save states off, the way the Pocket's `MAIN_SNES` (`rtl/mister_top/SNES.sv`) does, but
  without SDRAM, PSRAM, ROM loading, controllers, lightgun or cheats.
- Cartridge constants (what MiSTer/the Pocket's `rom_parser.sv` derive from the header):
  `ROM_TYPE = 8'h60` (`[7:4] = 6` selects `SA1Map`; header map mode `$23` with ROM type
  `$32/$34/$35` gives this), `ROM_MASK = 24'h7FFF` (32 KB, `(1024 << 5) - 1`),
  `RAM_MASK = 24'h7FF` (2 KB BW-RAM, header RAM size 1). They are parameters of `snes_core`.
- The core's own reset is held for `RESET_CYCLES` (65535, ~3 ms) after the PLL reports lock and
  released on the same 4-cycle divider phase as in `MAIN_SNES`.
- Controller data inputs are tied high (= no button pressed); `JOY_STRB`/`JOY*_CLK` go nowhere.
- Audio is not connected (`AUDIO_L/R` unused), so Quartus removes the S-DSP's output path; the
  S-DSP and SPC700 still run (the CPU talks to the SMP through its ports).

## Memory map and M10K use

All RAMs are inferred in Verilog (`snes_spram` in `snes_core.sv`: registered address, unregistered
output, new data on read-during-write, powers up as zero) on `clk_sys`, matching the timing of the
`altsyncram` wrappers the core uses elsewhere.

| Memory | Size | Where | M10K |
|---|---|---|---|
| WRAM | 128 KB | `snes_core` `wram` | 128 |
| VRAM | 2 × 32 KB | `vram1`, `vram2` | 64 |
| ARAM (SPC700) | 64 KB | `aram` | 64 |
| Cartridge ROM | 8 KB (4K × 16), from `build/snes/sa1test.hex` | `snes_core` `rom` | 8 |
| BW-RAM (BSRAM) | 2 KB | `bsram` | 2 |
| Line buffer | 16 lines × 512 × 18 bit, dual clock | `snes_video` `lb` | 16 |
| SA-1 I-RAM | 2 KB | inside SA1.vhd | 2 |
| PPU CGRAM, OAM (2), HOAM, sprite line buffer | | inside PPU.vhd | 5 |
| S-DSP register RAM, BRR buffer | | inside DSP.vhd | 2 |
| a 512 × 11 ROM Quartus inferred from a case statement | | core | 1 |
| **Total** | | | **292 / 308** |

(From the fitter's RAM summary; the PPU's 32 × 7 range table is one MLAB.) 16 blocks are left.

- The ROM is 16-bit wide like `sdram.sv`'s port 0 (the SA-1 always reads words; byte reads at
  odd addresses get the high byte in both halves). Only address bits 12:1 are used, so the 8 KB
  appear mirrored over the whole ROM space: the 32 KB test ROM file consists of four identical
  8 KB blocks, and `build/snes/sa1test.hex` holds the first one. A 16 KB ROM (`ROM_AW = 13`)
  would still fit (+8 blocks).
- The ROM is initialised with `$readmemh` (one 4-digit word per line, little-endian byte order),
  the same file for Quartus and the simulation. Quartus reads it at synthesis, so
  `quartus/snes/snes.rbf` depends on `build/snes/sa1test.hex` in the Makefile.
- SA-1 view of the cartridge (srg320's SA1.vhd): ROM at `$00–$3F/$80–$BF:8000–FFFF` and
  `$C0–$FF:0000–FFFF` through the CXB–FXB bank registers, BW-RAM at `$40–$4F` and the
  `$6000–$7FFF` window, I-RAM at `$3000–$37FF` (SNES) / `$0000–$07FF` and `$3000–$37FF` (SA-1).
  With `RAM_MASK = $7FF` the 2 KB BW-RAM is mirrored through all of it.

## Clocks

- `clk` (W16, 74.25 MHz board clock): the video side, directly (global clock), and the PLL
  reference.
- **Since 21 Oct 2026 `clk_sys` is 21.44196 MHz, not 21.477272**: 74.25 × 357366/1237500, so an
  NTSC SNES frame (357366 master clocks) lasts exactly one standard 720p frame (60.000 Hz). The
  SNES runs 0.164% slow (2.8 cents flat). Why: the projector on the test console drops the
  signal when the frame length varies (the earlier 748/749-line lock), and the alternative,
  a 74.372282 MHz video clock (74.25 × 656250/655171) for 60.0988 Hz output, can't be made: the
  fPLL's fractional multiplier must lie in 0.05–0.95, and with N = 1 (PFD ≥ 50 MHz) every
  usable VCO gives a fraction of 0.015–0.03 (Quartus rejects it; the IP generator falls back to
  74.25). A cascade from the SNES PLL's VCO would work but wasn't tried. The text below
  describes the original 21.477272 MHz setup; the PLL counters are in the fit report.
- `clk_sys` = 21.477272 MHz from one fractional fPLL (`snes_pll.v`, `altera_pll` instantiated
  directly with parameters, mode "normal"). The fitter report gives N = 1, M = 8 +
  425945992/2^32, VCO 601.363616 MHz, C = 28: the same frequency as the Pocket core's PLL and
  spc.cor's FPLL.000.000. The timing analyser shows the VCO as 601.68 MHz (1037/128): that is
  its rational stand-in for the fractional multiplier, not the configured frequency. It sits in
  `FRACTIONALPLL_X0_Y1_N0` (bottom left, fed from W16). The core needs no other clock: MCLK =
  ACLK = `clk_sys`, everything else runs on clock enables; without SDRAM there is no 85.9 MHz
  clock.
- `snes.sdc`: `create_clock` on `clk`, `derive_pll_clocks`, `derive_clock_uncertainty`; `clk` and
  the PLL clock are asynchronous groups. Crossings: a toggle synchroniser (frame event), a
  2-flop synchroniser (224/239-line mode) and the dual-clock line buffer.
- Pixel clock: M22 is driven by an `altddio_out` with `datain_h = 0`, `datain_l = 1`, i.e. the
  inverted `clk` leaving through a DDIO output register. The 27 data/sync outputs come straight
  from I/O-cell registers (`FAST_OUTPUT_REGISTER`) on the rising edge of `clk`, so the AD9889B's
  rising edge is half a period (6.7 ns) after the data changes. The SDC declares
  `pclk_out` as a generated clock on the `pclk` port (`-invert` of `clk`) and constrains the
  data/sync ports against it with an assumed AD9889B setup of 1.5 ns and hold of 1.0 ns (the
  datasheet values weren't at hand; the real ones are smaller for a 165 MHz part).

## Video

- **Capture** (`clk_sys`): the PPU puts out one colour per half dot (`DOTCLK = 1`: sub screen,
  the left pixel of a hi-res pair; `DOTCLK = 0`: main screen, the normal pixel). Lines are
  stored 512 columns wide: hi-res lines as they come, normal lines with each pixel written to
  both columns. Colour is stored as 6:6:6 (one 512 × 20 M10K per line), 16 lines in a ring.
  `HDE`/`VDE` from the PPU give the visible area (256 dots × 224 or 239 lines).
- **Output** (`clk_vid`): CEA-861 1280×720p60 (VIC 4): 1650 × 750 total, H front porch 110,
  sync 40, V front porch 5, sync 5, positive syncs. Each SNES line is shown on 3 output lines
  (224 → 672 lines, centred from line 24; 239 → 717 lines from line 1). Horizontally, 512
  columns map to `OUT_W` output pixels by nearest neighbour (default 768: 3 output pixels per
  normal SNES pixel, 1.5 per hi-res pixel), centred; `OUT_W = 896` gives a 4:3 picture with
  alternating 3/4-pixel widths. Everything outside the picture is black.
- **Frame lock.** At the real SNES clock an SNES frame (262 lines × 1364 master clocks) lasts
  16.639 ms, a 750-line 720p frame 16.667 ms. With `clk_sys` = 21.44196 MHz both last exactly
  16.667 ms, so the output keeps standard totals at 60.000 Hz. Once per SNES frame the capture side sends an event at a fixed point: at the
  start of the first visible line (`VDE` rise) in 239-line mode, about 8.2 SNES lines earlier
  in 224-line mode (counted against the previous frame's length). If it arrives outside output
  lines 744–746 (`LOCK_LINE` − 1 ± `LOCK_WIN`), the output line counter jumps to line 746 (in the
  vertical back porch) at the end of that line: once at startup, then only after a 224/239 mode
  change or if fractional-PLL rounding ever drifts the clocks apart by more than a line. Aligned,
  the output starts reading each SNES line 2.3–3.7 (± 1) output lines after the capture side
  finished writing it.
  - Why a 16-line ring: during the visible part the SNES delivers a line every 63.5 µs, but 3
    output lines take 66.7 µs, so the writer pulls ahead by ~11 lines over a frame; it catches
    up during vertical blanking. Its lead stays below 16 lines, and the simulation counts any
    cycle where the output reads the slot being written (none, see Simulation).
  - What a TV sees: standard 720p60 (74.25 MHz, 1650 × 750, 60.000 Hz). The first design kept
    the real SNES clock and jumped every frame (748/749-line frames, 60.10 Hz); Denley's
    projector showed the free-running 60.000 Hz picture but dropped the signal as soon as those
    jumps started (console test, 21 Oct 2026). `LOCK = 0` never jumps (the picture
    tears/rolls if the clocks don't match the SNES; a full frame buffer needs SDRAM).
  - Interlace changes the SNES frame length (262.5 lines average), which this fixed clock
    doesn't follow: such games would re-align (a glitch) whenever the drift exceeds a line.
  - Interlaced SNES modes are shown with both fields on the same lines (no deinterlacing).
- **Sync roles and colour mapping** (confirmed with `out/vtest.cor` on the console, 21 Oct 2026):
  - `SYNC_ORDER` (top-level parameter) = 3: P16 = VSYNC, M16 = DE, M18 = HSYNC. `-1` still
    cycles the 6 orders of `hw/vtest/vtest.v`, 8 s each (small white boxes in the top-left
    border, 224-line mode only, = order + 1).
  - Colours: `pins.tcl` assigns ch1/ch2/ch3 = red/green/blue, bit 7..0, per the vtest photo
    (`notes/spc-core.md`). `CH_ORDER` (default 0 = R,G,B) can still permute the channels.

## Test ROM

`quartus/snes/testrom/sa1test.asm` (asar; `make testrom` → `build/snes/sa1test.sfc`, 32 KB, and
`build/snes/sa1test.hex`, the 8 KB the FPGA stores). Layout, tests and expected values are in
the file's header comment. In short:

- Header: map mode `$23`, ROM type `$35`, ROM size `$05` (32 KB), RAM size `$01` (2 KB), NTSC,
  title "SUPERNT SA1 TEST", valid checksum. Code and data sit in `$00:E000–$EF28` (~3.9 KB);
  `rom2hex.py --mirror` copies that 8 KB block into all four slots of the 32 KB file (so an
  emulator sees exactly what the FPGA's mirrored 8 KB ROM gives) and fixes the checksum.
- The SNES CPU sets up the PPU (mode 0, BG1 solid-colour tiles, two sprites), sets the SA-1
  vectors and releases it, then checks what the SA-1 did:
  0. boot: the SA-1 writes a signature into I-RAM;
  1. multiplier (`$2250 = 0`, signed, incl. negative operands);
  2. divider (`$2250 = 1`; positive dividends only: for negative dividends this core truncates,
     real hardware rounds down and Mesen2 differs again);
  3. multiply–accumulate (`$2250 = 2`, 40-bit sum with bit 32 set);
  4. BW-RAM: SA-1 writes 256 bytes at `$40:xxxx`, the SNES reads them back through `$00:6000`
     and writes/reads its own pattern;
  5. SA-1 ROM reads: checksum of a ROM table through `$00:8000+`, the `$C0` linear bank and a
     mirror;
  6. messages: SNES → SA-1 through `$2200`/`$2301`, SA-1 → SNES through `$2209`/`$2300`, and
     clearing the SA-1→SNES IRQ flag via `$2202` (the IRQ line itself is not enabled).
  A dead SA-1 is caught by a ~1 frame timeout per test (red, never a hang).
- **Screen** (SNES pixels, 224-line mode, black background): rows 16–31, x 16–239: summary band,
  green if every test passed, red if any failed, grey while pending. Rows 48+16k … 55+16k: one
  band per test k = 0–6, same colours. A white 16×16 square at rows 192–207 moves right 1 pixel
  per frame (NMI counter: the SNES CPU is alive); a cyan one at rows 176–191 moves with a
  counter the SA-1 keeps incrementing (the SA-1 is alive). Frame 1 after reset is black, frame 2
  shows the final result.
- WRAM, for the simulation: `$7E:0100+k` = result of test k (0 pending, 1 pass, 2 fail),
  `$7E:00FF` = 7 tests, `$7E:00FE` = `$A5` when all are evaluated, `$7E:00FC–FD` frame counter.
- **Mesen2** (run headless: `DOTNET_ROOT=~/.dotnet`, a separate `HOME` with `{}` as
  `settings.json`, `--testrunner` with a Lua script, `--Snes.DisableFrameSkipping=true`): all 7
  tests pass, with power-on RAM random, all zeros and all ones; pixel positions match the layout.
  Patched copies that never release the SA-1 or expect a wrong product turn the right bands
  red. Script and screenshots: `~/scratch/snes-quartus/testrom/`.

## Simulation

`make sim-snes` simulates the whole Super Nt top (`top` in `snes_top.sv`, with the real
`snes_core`/`snes_video` and the test ROM hex) for `SNES_FRAMES` (6) output frames, writes
`build/sim/snes-00.png` … `snes-05.png` (the 720p output as the AD9889B would get it, with
ch1/ch2/ch3 shown as R/G/B) and `build/sim/snes.log`, and fails unless the last line says PASS.

- Flow: the vendor VHDL is copied to `$(SNES_SIM)` (default `~/scratch/snes-quartus/sim`),
  patched for GHDL (`sim/ghdl.patch`: two incomplete case/variable assignments and one length
  mismatch that Quartus accepts), the Altera RAM/MLAB/multiplier wrappers are replaced with
  behavioural VHDL (`sim/*_sim.vhd`), and `ghdl synth --out=verilog` turns `SNES`, `SA1Map` and
  `DSP_LHRomMap` into Verilog. `sim/ghdl_fix.py` fixes the netlists for Verilator (module name
  prefixes, port name case as `main.v` uses it, GHDL's duplicate wire names, the lost
  `ENABLE := '1'` port default, latch defaults; details in the script). Verilator then builds
  `sim/tb.sv` + our SystemVerilog + vendor `main.v` + the netlists with `sim/tb_snes.cpp`.
  `sim/sim_models.v` replaces the PLL (the C++ drives 21.477272 MHz and 74.25 MHz with the right
  phase drift), `altddio_out` and the Game Genie block. The sim uses `RESET_CYCLES = 256` and
  sync order 0.
- Times on this box: GHDL ~8 s, Verilator ~30 s plus a few minutes of C++ compilation (~10 min
  while Quartus was running), simulation ~3–4 s per output frame (0.36 M SNES master cycles +
  1.24 M video cycles), so `make sim-snes` takes ~25 s once built.
- Checks in `tb_snes.cpp`: output frame length (from frame 2 on: 750 lines), the
  line-buffer ring (any video-clock cycle where the output reads the ring slot the capture side
  is writing counts as a conflict), the test ROM's WRAM results, and the summary band's colour
  in the last frame. `TB_DEBUG=1` prints where the conflicts and line-0 writes happen;
  `TB_ROM=<file.hex>` runs another ROM image without rebuilding.
- **Result** (`build/sim/snes.log`): all 7 tests pass in the core (WRAM results `1 1 1 1 1 1 1`,
  done flag `$A5` already in the first output frame); from the second output frame on, the
  frames are 750 lines with zero line-buffer conflicts (SNES clock 21.44196 MHz since 21 Oct;
  before that 748/749 lines); SNES line 0 is complete ~3 output
  lines before it is first shown. `build/sim/snes-05.png` shows the green summary band, 7 green
  test bands and the white/cyan squares; across frames the white one moves 3 output pixels
  (1 SNES pixel) per frame and the cyan one ~18. The first output frame (before the SNES
  starts) is free-running, and the first lock jump makes one short frame (731 lines here).
- A variant of the ROM with SETINI = `$0C` (239 lines + pseudo hi-res; built in
  `~/scratch/snes-quartus/variant`, run with `TB_ROM`) also passes, with the picture from output
  line 1, zero conflicts and the hi-res columns alternating sub (black) / main (green) at 1.5
  output pixels each.

## Build results

`make out/q-snes.cor` (Quartus 25.1 Lite, `quartus/snes/build.log`; 8.7 min on this box):

- **Resources** (`snes.fit.summary`): 9,268 / 18,480 ALMs (50 %), 6,335 registers,
  292 / 308 M10K (2,362,112 bits), 16 / 66 DSP blocks, 1 / 4 PLLs, 29 pins. By entity: CPU
  (5A22 + 65C816) 2,817 ALMs, SA-1 2,200, PPU 1,401, S-DSP 1,368, SMP 892, video 224. (The S-DSP
  is smaller than in the Pocket build because the audio output is unconnected.)
- **Timing** (`snes.sta.summary`), all met, worst slacks at the slow 1100 mV 85 °C corner:
  setup `clk_sys` +14.594 ns (Fmax 32.7 MHz vs 21.48), `clk` +6.506 ns (Fmax 143.6 MHz vs
  74.25), `pclk_out` (video output ports vs the assumed AD9889B window) +4.536 ns; hold
  `clk_sys` +0.299, `clk` +0.522, `pclk_out` +5.064 ns. The smallest slack at any corner is
  +0.079 ns hold on `altera_reserved_tck` (the JTAG hub, fast 0 °C). Metastability report: 2
  synchroniser chains, MTBF > 10^9 years.
- **Pins** (`snes.pin`): outputs are exactly the 24 colour pins, M22, P16, M16, M18 and
  `altera_reserved_tdo` (M5); inputs W16 and the JTAG pins; 196 pins are
  `RESERVED_INPUT_WITH_WEAK_PULLUP`. All outputs are among those spc.cor drives.
- The `.cor` (2,632,660 bytes, same as spc.cor) is the bit-reversed uncompressed `.rbf`.
- The core's `spram` wrapper (SA-1 I-RAM, PPU HOAM) asks for the In-System Memory Content
  Editor (`ENABLE_RUNTIME_MOD=YES`), so Quartus adds a JTAG hub (`sld_hub`, `altera_reserved_*`
  clock). It only uses the dedicated JTAG pins.

## Verified vs not

Verified (no hardware):
- Quartus compiles, fits and meets timing; pins as above; PLL settings in the fitter report.
- Simulation of the whole top (same RTL as the bitstream except the PLL, DDIO and Game Genie
  models and a shorter reset): the SNES core with SA-1 boots the test ROM, all 7 SA-1 tests
  pass, the 720p picture matches the layout, 224 and 239/pseudo-hi-res modes, frame lock with no
  line-buffer conflicts.
- The test ROM passes in Mesen2 too.

Not verified / assumptions:
- **Console (21 Oct 2026):** the Quartus `.cor` loads, all 7 SA-1 tests pass and both CPUs run
  (green summary + 7 green bars, white and cyan squares moving; video in Denley's thread). The
  60 Hz version (SNES clock 21.44196 MHz) is not yet tried on the console.
- AD9889B setup/hold numbers (assumed 1.5/1.0 ns; the real margin is ~6 ns either way).
- Whether the 60 Hz build holds the picture (it showed the same timing while free-running).
- The simulation is of a GHDL-converted netlist with behavioural RAMs, not Quartus' netlist
  (no gate-level/timing simulation). Quartus' handling of the unconnected `ENABLE := '1'`
  VHDL port defaults (SA1Map, DSP_LHRomMap) is the same as in agg23's Pocket build, which works.
- The very first lock after reset makes one irregular output frame (the jump can land in the
  active area once); the TV may blink once at start-up.
- SA-1 features the test doesn't touch: SA-1 DMA, character conversion, timers, variable-length
  bit reads, bitmap BW-RAM, SA-1 IRQs. The divider differs from hardware for negative dividends
  (core behaviour, not ours).

## Next steps

- **SDRAM**: trace the x16 AS4C8M16SA's pins (top bank, clock H8) from spc.cor, then put the ROM
  there with `sdram.sv` (needs the 85.9 MHz clock, a second PLL output). That frees 8+ M10K and
  lifts the 8 KB ROM limit; WRAM/ARAM can stay in M10K.
- **PIC32 loading**: work out the bank 4A link protocol (`out/q-buslog.cor`), then feed
  `ioctl_*`-style writes into SDRAM and set ROM_TYPE/ROM_MASK/RAM_MASK from the header (the
  Pocket's `rom_parser.sv`). BW-RAM saves need the reverse path.
- **Controllers**: find the port pins (candidates in `notes/spc-core.md`) and connect `JOY_STRB`,
  `JOY1/2_CLK`, `JOY1/2_DI` (`main` already has the raw serial interface).
- **Audio**: I2S on K17/L18 with MCLK/BCLK on L19/L17 (spc's 12.288/3.072 MHz), the S-DSP's 32 kHz
  resampled to 48 kHz or the AD9889B set to 32 kHz, which needs its register setup (unknown who
  owns the I2C bus).
- Video: real AD9889B setup/hold numbers in `snes.sdc`; a frame buffer in SDRAM for a
  free-running 60.000 Hz option without tearing.
