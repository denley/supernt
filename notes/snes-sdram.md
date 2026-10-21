# SNES core with the cartridge ROM in SDRAM (quartus/snes_sdram, Oct 2026)

`make out/q-snes_sdram.cor` builds the SNES + SA-1 core of `notes/snes-quartus.md` with the
cartridge ROM in the x8 SDRAM pair (`notes/sdram.md`) instead of block RAM. Loading through the
PIC32 link isn't wired in yet, so the core is self-contained: at start-up it copies the built-in
SA-1 test ROM (8 KB of block RAM, `build/snes/sa1test.hex`) into SDRAM as the 32 KB `.sfc` image,
then releases the SNES reset and runs from SDRAM. Video, audio and controller port 1 are as in
`quartus/snes` (same top-level parameters: `SYNC_ORDER`, `CH_ORDER`, `AUD_FRAMING`, `PAD_CFG`,
...).

**Status:** simulated (controller against a timed model in iverilog; whole top in Verilator with
a cycle-based SDRAM model: all 7 SA-1 tests pass from SDRAM, also with a 1 MB image read at its
far end); builds, meets timing at every corner with datasheet worst-case SDRAM numbers, pin check
passes. **Not run on hardware.** The read-capture point (and DQM) depend on the hwtest console
run (see "Parameters to set from hwtest").

**What you should see on the TV:** the same as `q-snes`: green summary bar, 7 green test bars,
white and cyan squares moving, the chord after the tests. If the SDRAM read timing is wrong the
SNES gets garbage from ROM: most likely a black screen (the CPU never reaches the PPU setup) or
red bars; nothing can be damaged by that. The boot copy takes ~2 ms, so start-up looks the same.

## Files

| File | What |
|---|---|
| `quartus/common/sdram_rom.sv` | `sdram_rom`: the controller (ROM read port, write port, aux read port, refresh) |
| `quartus/common/link_loader.sv` | `link_loader`: PIC32 link slave that writes a window of the link address space into SDRAM (not wired in) |
| `quartus/snes_sdram/snes_sdram_top.sv` | top `top`: PLL, controller, boot copy, core, video/audio/pads as `quartus/snes/snes_top.sv` |
| `quartus/snes_sdram/snes_sdram_core.sv` | `snes_sdram_core`: copy of `quartus/snes/snes_core.sv` with the ROM port brought out (`rom_addr/rom_word/rom_q`, `ROM_OE_N`, `SYSCLKF_CE`) and `rom_mask` as an input |
| `quartus/snes_sdram/snes_sdram_pll.v` | `altera_pll`, 4 outputs: clk_sys, clk_mem (controller), clk_sd (SDRAM clock source), clk_cap (read capture) |
| `quartus/snes_sdram/sdram_cfg.tcl` | **the SDRAM settings** (capture point, clock phases), read by `sdram_params.tcl` (→ top-level parameters via the `.qsf`) and by the `.sdc` |
| `quartus/snes_sdram/snes_sdram.qsf`, `.qpf`, `files.tcl`, `sdram_params.tcl`, `snes_sdram.sdc`, `pins.tcl` | project; `snes_video.sv` and `audio_pll.v` are used from `quartus/snes` unchanged |
| `quartus/snes_sdram/sim/` | `sdram_model.v` (timed model, iverilog), `sdram_cyc.v` (cycle model, Verilator), testbenches, sim stand-ins |
| `quartus/snes_sdram/testrom/mkfar.py` | 1 MB far-bank variant of the test ROM for the simulation |

Make targets: `out/q-snes_sdram.cor`, `sim-sdram-rom` (controller), `sim-link-loader`,
`sim-snes-sdram` (whole top; reuses `sim-snes`'s GHDL netlists; work files in
`~/scratch/sdramrom/sim`, `SNES_SDRAM_CAP=<h>` builds another capture point).

## Clocks

One fractional fPLL (`snes_sdram_pll`, from W16), one VCO (600.375 MHz), so the timing analyser
treats all outputs as related. Phases relative to clk_sys, set in `sdram_cfg.tcl` (multiples of
VCO/8 = 208.2 ps):

| clock | output | MHz | phase | drives |
|---|---|---|---|---|
| clk_sys | 0 | 21.44196 (/28) | 0 | the SNES core (as `q-snes`) |
| clk_mem | 1 | 85.76784 (/7) | +1250 ps (`SDRAM_MEM_LAG_PS`) | controller, command/address/write-data registers, boot copy |
| clk_sd | 2 | 85.76784 | −1041 ps (`SDRAM_CLK_LEAD_PS`) | SDRAM clock DDIO on AB11 (inverted, as hwtest) |
| clk_cap | 3 | 85.76784 | +625 ps = clk_sd + 1666 ps (`SDRAM_CAP_OFFSET_PS`) | read-capture register |

All three at 0 is hwtest's arrangement. Logically nothing changes (the simulations run all clocks
aligned); the phases only distribute the 8 clk_mem cycles of the latency budget (below) over its
parts at the slow corner:
- **clk_mem late (+1.25 ns):** clk_sys → controller paths (the ROM address from the SA-1's
  address registers through its mapper and `main.v`'s ROM mux into the ACT's output registers,
  ~12.6 ns) get one cycle + 1.25 ns. The SDC checks the other side as a hold requirement: the
  clk_mem edge just after a clk_sys edge must still see the old value, so every such path must
  be longer than 1.25 ns (the fitter pads them: `OPTIMIZE_HOLD_TIMING "ALL PATHS"` and 0.15 ns
  extra hold uncertainty in the fitter only). At 1.67 and 1.46 ns a few paths into the address
  output registers stayed 0.04–0.07 ns short.
- **clk_sd early (−1.04 ns):** the SDRAM clock edges come 2.3 ns earlier relative to the commands
  than in hwtest (commands get half a cycle minus 2.3 ns of setup at the chips: 0.8 ns spare
  with tIS 1.5 ns), so the whole read happens earlier relative to clk_sys.
- **clk_cap 1.67 ns after clk_sd:** positions the capture inside the read window (this offset,
  not the others, is what the capture-point table below depends on), and the capture lands
  0.6 ns after clk_sys's grid instead of 1.25 ns, leaving the core's ROM-data paths 1.5 cycles
  − 0.6 ns = 16.9 ns.
- The first attempt (everything on clk_mem, no lag) missed by 2.2 ns (ROM data → SA-1), 1.1 ns
  (read input) and ~1 ns (address); getting all three to meet together needed the three phases.

## Controller (`sdram_rom.sv`)

Geometry and pins as `notes/sdram.md`: 4 banks × 4096 rows × 1024 columns × 16 bit; word address
w[23:0] → bank w[23:22], row w[21:10], column w[9:0]. The ROM port uses w = byte address / 2, so a
ROM up to 16 MB sits in banks 0-1 (a 6 MB ROM in bank 0).

Robust against the uncertain parts of the pin map, as `sdram_test.sv`:
- Mode register: spc.cor's pin pattern `MRS_PINS = 12'h037` (CL3 + full page if A0-A6 are as
  `notes/sdram.md` says); `CL = 3` must match it.
- Single words out of full-page bursts. **Read:** ACT, READ 2 cycles later (column on A0-A9,
  A10 = A11 = 0), PRECHARGE (that bank, A10 = 0) 4 cycles after ACT (tRAS), which ends the
  burst after word 1; next ACT 6 cycles after ACT (tRC). **Write:** ACT, WRITE + data,
  BURST TERMINATE in the next cycle (DQM can't mask, so the burst must not go on), PRECHARGE
  4 cycles after ACT (tWR 2 clocks after the data), next ACT after 6. **Refresh:** AUTO REFRESH,
  6 cycles to the next command. **Init:** ≥ 200 µs NOP, PRECHARGE of each bank separately,
  8 × REF 6 cycles apart, MRS, 3 cycles.
- Closed page: every bank is idle between accesses, so every read takes the same time and a
  refresh never waits for a bank.

Timing at 85.77 MHz (11.66 ns) against IS42S81600F-6: tRCD 2 cycles (23.3 ns ≥ 18), tRAS 4
(46.6 ≥ 42), tRP 2 (23.3 ≥ 18), tRC 6 (70 ≥ 60, also REF → next command), tWR 2 clocks, tMRD 2
(3 used).

**ROM port** (MiSTer `sdram.sv` port 0 semantics): `rom_addr`/`rom_word` come from clk_sys logic
and are compared every clk_mem cycle; **a read starts whenever the word address changes** (no
strobe; `ROM_OE_N` isn't used for that, since for SA-1 carts it is just the SA-1's `CLK_CE`).
`rom_q` comes straight from the capture register; byte reads at odd addresses (`rom_word = 0`)
get the high byte in both halves, as `sdram.sv`.

Latency, in clk_mem cycles after the clk_sys edge E at which the address changes: ACT at E+1,
READ at E+3, PRECHARGE at E+5, data in the capture register at E+3 + CAPTURE_HALF/2 (E+6.5 for
fall 3.5), controller free for the next ACT at E+7.

**Why that is the budget** (read off the vendor VHDL, then confirmed in simulation):
- SA-1 (`SA1.vhd`): one bus cycle per 2 clk_sys; `ROM_RD_N` = `CLK_CE` toggles every clk_sys
  cycle; the 65C816's address changes at the edge ending a `CLK_CE = 1` cycle and it latches
  `ROM_DI` (through its ALU/flag logic, ~13 ns) at the next such edge: **E+8 clk_mem cycles**.
  Same for the SNES CPU when its ROM window opens on such an edge.
- SNES CPU (`CPU.vhd`) reading ROM through the SA-1: the SA-1 latches the CPU address at
  SYSCLKR, but its ROM window (`WINDOW = 0`, `SNES_ROM_SEL`) only opens at the next edge with
  `CLK_CE = 1`. In a FastROM cycle (6 clk_sys) `CLK_CE` is 0 in the SYSCLKR cycle (it is forced
  to 0 at SYSCLKF and toggles), so the address appears one clk_sys later and the CPU takes the
  data at SYSCLKF **2 clk_sys = 8 clk_mem cycles after that, the same budget as the SA-1**
  (slow ROM: 16). Its data path (SA-1 `SNES_DO` mux, `main.v` data mux, 65C816, up to the PC
  register) is ~15 ns, the longest of all.
- Simulated: capture one cycle later (data at E+8, `SNES_SDRAM_CAP=10`) and the SNES CPU still
  boots and evaluates the tests, but all 7 SA-1 tests fail.
- So with data at E+6.5 (+ clk_cap's 0.6 ns) the core has 17.5 − 0.6 = 16.9 ns for those paths;
  rise 4 (data at E+7) would leave 11 ns, too little (the paths are 13–15 ns).

**Refresh, hidden between reads.** A REF blocks the bus for 6 cycles. For SA-1 carts ROM
addresses change only at the clk_sys edge after a cycle with `CLK_CE = ROM_OE_N = 1` (SA-1 bus
cycle) or with `SYSCLKF_CE = 1` (the SNES's ROM window ends, `INT_ROM_A` switches back to the
SA-1's address). So in a clk_sys cycle with both low (`rfsh_ok`), a REF issued at the 2nd-4th
clk_mem edge ends by E+9 and never delays a read that starts at E+8. Policy (counter of cycles
since the last REF):
- from 640 cycles (7.5 µs): REF in such a slot if no read is pending;
- from 1200 (14 µs): REF in any slot without a pending read (`n_rf_forced`, may make the next
  SA-1 read late);
- at 1320 (15.4 µs): REF even ahead of a pending read (`n_rf_stall`).
So the interval never exceeds 15.4 µs + one access. `n_late` counts reads whose data came later
than E+6.5 (the first read after enabling or a write is excluded). Writes use the same slots
as soft refreshes while ROM reads are on, any slot while they are off.

For other mappers (LoROM/HiROM through `DSP_LHRomMap`), `rfsh_ok` would come from
`SYSCLKF_CE`/`SYSCLKR_CE`; not worked out yet, since only SA-1 is built.

**Aux read port** (`aux_req/aux_addr/aux_ack/aux_valid/aux_q`): one word, for the link
loader's read-modify-write. Served only while `rom_en = 0`, because the data goes through the
ROM port's capture register.

## Read capture point

`CAPTURE_HALF` (h) counts half cycles of the capture clock after its edge that goes with the
controller edge putting the READ on the pins, in hwtest's terms (`quartus/common/sdram_test.sv`,
where all of these are one clock): **rise n = 2n, fall n.5 = 2n + 1**. Default **7 = fall 3.5**.
The SA-1 and FastROM need h ≤ 7 (above).

Datasheet convention (IS42S81600F, and spc.cor's controller in `notes/sdram.md`): with CAS
latency 3, the word for a READ sampled at SDRAM edge e is driven from tAC (5.4 ns) after edge
e+2 until tOH (2.7 ns) after edge e+3. With the SDRAM clock the inverted controller clock, e is
half a cycle after the READ edge, so at the FPGA's input register the word is valid from
2.5 T + tAC + D to 3.5 T + tOH + D after the READ edge (counted on the capture clock), where
**D** = SDRAM clock output delay + board + data input delay, minus the capture clock's offset
behind the SDRAM clock source (`SDRAM_CAP_OFFSET_PS`, 1.67 ns; 0 in hwtest). The controller
clock's own phase doesn't enter. Each capture point therefore works for a range of D:

| point | h | hwtest, 74.25 MHz, offset 0 | 85.77 MHz, offset 0 | 85.77 MHz, offset 1.67 ns (default) |
|---|---|---|---|---|
| fall 2.5 | 5 | −16.2 … −5.4 ns | −14.4 … −5.4 | −12.7 … −3.7 |
| rise 3 | 6 | −9.4 … 1.3 | −8.5 … 0.4 | −6.9 … 2.1 |
| **fall 3.5** | **7** | −2.7 … 8.1 | −2.7 … 6.3 | **−1.0 … 7.9** |
| rise 4 | 8 | 4.0 … 14.8 | 3.1 … 12.1 | 4.8 … 13.8 |
| fall 4.5 | 9 | 10.8 … 21.5 | 9.0 … 17.9 | 10.6 … 19.6 |

(Without FPGA setup/hold and jitter; take ~0.5 ns off each end.) The timed iverilog model
reproduces the 85.77 MHz/offset-0 column (sweep in `~/scratch/sdramrom/sweep.sh`: h = 7 passes for
D = 1–6 ns, h = 8 for D = 4–10 ns). Expected D on this board: DDIO clock out ~3.7 ns (Quartus),
traces ~1 ns, input ~1–2.5 ns → 5–7 ns, i.e. hwtest should show **fall 3.5 clean and rise 4
clean or marginal**.

**The hwtest simulation model is one edge late.** `quartus/hwtest/sim/sdram_model.v` drives
the word from tAC after edge e+3 (not e+2), so in that simulation rise 4 and fall 4.5 pass and
fall 3.5 fails. That is a CL4 timing; on hardware expect the window one cycle earlier (fall 3.5
/ rise 4, as above). spc.cor's own controller captures at the edge 3 cycles after the SDRAM
edge that samples the READ (`notes/sdram.md`, "Timing check"), which only works with the
datasheet convention.

## Parameters to set from hwtest

`SDRAM_CAPTURE_HALF` in `quartus/snes_sdram/sdram_cfg.tcl`; the simulation default is
`CAPTURE_HALF = 7` in `snes_sdram_top.sv` (keep it the same, or pass `SNES_SDRAM_CAP`).

| hwtest result (74.25 MHz, which `errN` stay 0) | D | set |
|---|---|---|
| fall 3.5 only (err3), maybe also rise 3 (err0) | < 4 ns | keep h = 7 |
| fall 3.5 and rise 4 (err3, err2) | 4–8 ns | keep h = 7 (covers D up to 7.9 ns) |
| rise 4 only (err2) | 8–10.8 ns | keep h = 7 and set `SDRAM_CAP_OFFSET_PS` ≥ D − 5.8 ns (h = 7 covers D ≤ 6.3 ns + offset − 0.5 ns margin), in 208 ps steps. The ROM-data slack (1.29 ns) allows offsets up to ~2.9 ns, i.e. D ≤ ~8.7 ns; rebuild and check timing |
| rise 4 and fall 4.5, or later | > 10.8 ns | doesn't fit: h ≥ 8 is too late for the SA-1/FastROM. Needs CL2 (one cycle shorter; needs the A0-A6 order confirmed for the MRS) |
| nothing clean | | pin map/CKE/DQM problem, not timing |

Fine adjustment: `SDRAM_CAP_OFFSET_PS` moves the capture in 208 ps steps; one step later covers
0.21 ns more D and takes 0.21 ns from the core's ROM-data paths, one step earlier the reverse
from the read-data input setup (spare slack on both under "Build results"). The other two
phases have no slack to give.

Also from hwtest: **DQM**: `DQM_LOW` in `snes_sdram_top.sv` (1 = hold the candidate pins low,
default; 0 = release them) if only one of `err_dqm0`/`err_dqmz` is clean. And `AUD_FRAMING` /
`PAD_CFG` as for `quartus/snes`.

## Boot copy

clk_mem side of `snes_sdram_top.sv`: after the controller's init, SDRAM word i ← boot ROM word
(i mod 4096) for i = 0 … 16383 (`ROM_WORDS`, the 32 KB `.sfc`: the 8 KB block mirrored four
times, as the file is), one write per ~9 cycles (~1.7 ms). Then `loaded` turns ROM reads on and,
synchronised to clk_sys, starts the `RESET_CYCLES` count before the core leaves reset.
`ROM_MASK = $7FFF` as before. Block RAM use is unchanged (the ROM's 8 M10K are now the boot ROM).

## Link loader (`link_loader.sv`, not wired in)

The stock link slave as `link_logger.sv` (A[2:0], /WR, /RD, 32-bit address register written a
byte at a time at A = 0/1/4/5, data at A = 2 with post-increment, A = 3 latch, the stock read
constants). Data bytes with addresses in [`WIN_BASE`, `WIN_BASE + WIN_SIZE`) go to SDRAM word
`SD_BASE + offset/2`, low byte for even offsets. Byte pairing: a pending half word waits for its
partner, also across address-register writes (chunked transfers with odd lengths still give
whole words); it is written by read-modify-write (aux read port) when a byte for another word
arrives, after `IDLE_FLUSH` cycles (~1 ms) without a strobe, or on `flush`. A 16-word FIFO feeds
the write port; overflow drops are counted (`n_dropped`). Needs ROM reads off (core in reset)
while loading. Wiring it in needs: a write-port mux with the boot copy, the window/offset from
the hwtest result (where the PIC writes the file, and whether a 512-byte copier header comes
along), `ROM_MASK`/`ROM_TYPE`/`RAM_MASK` from the header (the Pocket's `rom_parser.sv`), and
releasing the reset when the transfer ends.

`make sim-link-loader`: loader + controller + timed model, PIC32 stand-in with 120 ns /WR
pulses: 300 bytes at an even offset, 7 from an odd one, 5 with an odd end (idle flush), 3 + 3
across an address change, bytes just outside both ends of the window, A = 3/6 writes, a 4 KB
block. Result: all 65536 bytes of the window match (SDRAM prefilled with a pattern, so
read-modify-write is checked), 4418 bytes taken, 2210 words written, exactly 2 read-modify-writes
(the odd start and the odd end; the chunk boundary paired up without one), 0 dropped, 0 model
errors. **PASS.**

## Simulation

**Controller** (`make sim-sdram-rom`, iverilog, `sim/tb_sdram_rom.sv` + `sim/sdram_model.v`):
the timed model has the full geometry and checks setup/hold of commands, address and write
data, tRCD/tRAS/tRP/tRC/tRRD/tWR/tMRD, REF/ACT spacing, bank states, the init sequence and mode
register, refresh interval, and bus contention; board delays D_CLK 3.5, D_OUT 3.5, D_IN 1.0 ns.
An SA-1 stand-in reads as `SA1.vhd` does (new address after a CE edge, data latched 8 cycles
later). Steps: write 2112 words (a block top-down, so a missing BURST TERMINATE would corrupt
the word above; page and bank ends; banks 2-3) and check them in the model; 6000 SA-1 cycles
with a new word in 60% of them; 600 cycles with a new word in every one (no hidden slot);
2000 more. Results:
- h = 7 and h = 8: 0 errors in 8000 checked reads, 0 model errors, no contention; refresh every
  ≤ 7.8 µs while hidden slots exist; in the worst-case stretch 3 forced refreshes (longest gap
  14.1 µs ≤ 15.6) and 6 reads late (2 per forced refresh). Also h = 7 with the phases as built
  (relative to the capture clock: SDRAM clock 1.67 ns early, commands 0.63 ns late; run as
  D_CLK 1.83, D_OUT 4.13): pass, no setup/hold violations at the chips.
- h = 6 and h = 9: every read wrong (expected, the make target checks that they fail).

**Whole top** (`make sim-snes-sdram`, Verilator, `sim/tb.sv` + `sim/tb_snes_sdram.cpp` +
`sim/sdram_cyc.v`): clk_mem driven at 4 × clk_sys with aligned edges; the cycle model takes
commands on falling clk_mem edges (the inverted SDRAM clock), presents burst word k at the
FPGA's input for samples wlo + 2k … whi + 2k half cycles after the READ edge (default 7, 8 =
fall 3.5 and rise 4, `TB_WIN` changes it at run time) and garbage otherwise, and checks the same
protocol rules. Result (6 output frames, ~50 s once built; the build ~1.5 min):
- Boot copy 16384 words, then all 7 SA-1 tests pass (WRAM results `1 1 1 1 1 1 1`, done flag
  `$A5` in the first output frame), summary band green, 750-line frames from frame 2, no
  line-buffer conflicts (same as `sim-snes`). **PASS.**
- SDRAM traffic per output frame: ~157 k reads, ~2190 REF (mean 7.6 µs); longest REF gap 728
  cycles (8.5 µs); no forced or stalled refreshes, no late reads, 0 model errors. So the SA-1
  test leaves plenty of hidden refresh slots.
- 1 MB image (`mkfar.py`, `TB_SFC=build/snes/sa1far.sfc TB_MASK=FFFFF`): test 5's second
  checksum view reads bank $CF = ROM offset $F6F7F (SDRAM bank 0, row $1ED): all pass. The
  same image with the far table corrupted (`--bad`): test 5 fails, the others pass, so the far
  reads really go to that address.
- Window moved against the capture point (h = 7): `TB_WIN=6,7` and `7,7` pass, `8,9` and `5,6`
  fail (nothing runs). Capture one cycle late (`SNES_SDRAM_CAP=10`, window 10,10): the SNES
  runs, all 7 SA-1 tests fail (above).

## Build results

`make out/q-snes_sdram.cor` (Quartus 25.1 Lite, `quartus/snes_sdram/build.log`; ~10 min on this
box). The `.cor` is 2,632,660 bytes like the others.

- **Resources** (`snes_sdram.fit.summary`): 9,516 / 18,480 ALMs (51 %; `q-snes`: 9,268),
  6,770 registers, 292 / 308 M10K (unchanged: the ROM's 8 blocks are now the boot ROM),
  18 / 66 DSP, 2 / 4 PLLs (SNES/SDRAM + audio), 81 pins. The controller is 132 ALMs.
- **PLL** (fit report): VCO 600.37488 MHz (M = 8 + fraction, N = 1); clk_sys C = 28;
  clk_mem/clk_sd/clk_cap C = 7 with 38.57°, 327.86° (−32.14°) and 19.29° = +1250, −1041,
  +625 ps.
- **Timing: met at all four corners** (no "Timing requirements not met"). Worst slacks:

| path | slack | corner |
|---|---|---|
| SDRAM read data → capture register (setup; tAC 5.4 + 2 × 0.5 ns traces) | +0.121 ns | slow 85 °C |
| same, hold (tOH 2.7 ns) | +3.98 ns | fast 0 °C |
| ROM address (SA-1 address registers → `sd_a` output registers), clk_sys → clk_mem setup | +0.341 ns | slow 85 °C |
| clk_sys → clk_mem hold (must exceed the 1.25 ns lag) | +0.143 ns | fast 0 °C |
| ROM data (capture register → SA-1 65C816 PC, 16.9 ns budget) | +1.287 ns | slow 85 °C |
| SNES CPU address → controller (multicycle, see SDC) | +7.36 ns | slow 85 °C |
| commands/address/write data → chips (tIS 1.5 ns) | +0.789 ns | slow 85 °C |
| same, hold (tIH 0.8 ns) | +6.4 ns | slow 85 °C |
| everything else (core, video, audio) | ≥ +0.123 ns hold, ≥ +6.2 ns setup on `clk` | |

  The read window has ~4 ns to spare in total, almost all on the hold side: moving the capture
  1–2 steps later (`SDRAM_CAP_OFFSET_PS` 1875–2083) would centre it at the cost of 0.2–0.4 ns
  of the ROM-data slack; left as is until hwtest says where the real window is.
- **Pins** (`make` runs `tools/checkpins.py`: 81 user I/Os, all as assigned): the SDRAM pins
  exactly as `quartus/hwtest` (command/address/BA/DQ, AB11 clock, AB10 CKE driven high, DQM
  candidates open-drain low: Quartus infers open drain from the 0/Z HDL, as in hwtest), the
  `quartus/snes` video/audio/controller pins, JTAG TDO (M5).
- Settings: `OPTIMIZE_HOLD_TIMING "ALL PATHS"`; I/O-cell registers for commands, address, DQ out
  and OE, and the DQ capture.
- Pitfall: Quartus rewrites (flattens) the `.qsf` if a file it sources changes during a
  compile; don't edit `sdram_cfg.tcl`/`files.tcl`/`pins.tcl` while it runs.

## Verified vs not

Verified (no hardware): controller protocol and timing against a timed model with datasheet
numbers; whole core from SDRAM in simulation incl. a 1 MB image; Quartus timing at all corners
with datasheet worst-case SDRAM numbers and assumed 0.5 ns traces; pins as `quartus/hwtest`
(SDRAM) and `quartus/snes` (the rest).

The multicycle exceptions the timing rests on, all argued in `snes_sdram.sdc`: clk_sys →
clk_mem one cycle + lag (with the hold check at the lag); SNES CPU address → controller one
more cycle (the SA-1 masks it with `WINDOW`); capture register → clk_sys 1.5 cycles (valid for
reads that start right after the address change); read data → capture register at the capture
point.

Not verified / open:
- **Hardware.** Read window (h), DQM pins, CKE, the MRS pin pattern. AA14 = A10 doesn't matter
  (0 in every PRECHARGE/READ/WRITE, a row bit in ACT), nor does the BA order.
- **Refresh with real games.** Hidden slots need SA-1 bus cycles without a new ROM word
  (internal cycles, the second byte of a word, I-RAM code with repeated addresses...). The test
  ROM gives one every few µs; a game that makes the SA-1 read a new word in every cycle for
  > 14 µs gets forced refreshes, each making ~2 SA-1 reads late (wrong data). `n_rf_forced`,
  `n_rf_stall`, `n_late` and `rf_max` are outputs of `sdram_rom` for a debug screen. If it
  happens: refresh rows by ACT/PRE in an idle bank while reads go to another (ROM in one bank,
  others free), or a small read cache.
- The capture → clk_sys multicycle assumes on-time reads. A read delayed by a refresh or a
  queued read loads the register at another phase; an SA-1 or FastROM read has latched (late)
  data anyway and a SlowROM read is still in time, but other clk_sys registers could sample a
  changing `rom_q` (harmless unless they use it in that cycle).
- `rfsh_ok` for non-SA-1 mappers, and SNES-side reads that change the address at other edges
  than the ones analysed (none seen in simulation: `n_late` stays 0).
- Board traces (0.5 ns each assumed) and the AD9889B numbers as in `quartus/snes`.
- The cycle model's window comes from the analysis above, not from hardware; the Verilator run
  proves the logic and latency, not the analog timing.
