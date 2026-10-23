# SNES core that loads its ROM from the SD card (quartus/snes_load, Oct 2026)

`make out/q-snes_load.cor` builds the SNES + SA-1 core (srg320's MiSTer core as in
`notes/snes-quartus.md`) with the cartridge ROM in SDRAM chip B, loaded from the SD card
through the SPC player: the core stands in for `SYSTEM/CORES/spc.cor`, the PIC32 runs the
player's file browser on it, and a "song" made by `tools/rom2spc.py` carries the ROM. After the
transfer the core checks the ROM in SDRAM against the file's CRC-32, shows the result for 4 s
and starts the game. Everything the PIC does stays visible on a diagnostics page.

**Status:** v1 (commit 6ea85d1) **works on the console** (23 Oct: SA-1 test, Gradius III,
Kirby Super Star; notes/hardware-tests.md). v2 (commit dd820dc) closes v1's gaps: the way back
to the player's menu, 64 KB of save RAM (Super Mario RPG, Kirby's Dream Land 3), keeping saves
across reloads, a full PIC link log; **works on the console** (23 Oct, DOWN+SELECT back to the
browser). v3 (one console run, 23 Oct) found port 2's data pin (D6: **player 2 works**) but its
SELECT fix didn't work. v4 (console run 23 Oct) read D6 directly; SELECT alone no longer opened
the browser, but neither did DOWN+SELECT, and its log showed why: **while a game runs the PIC
reads the pad registers over the link** (0x2000/0x2001 every ~33 ms) and wakes on SELECT there;
it doesn't watch the controller lines. v5 (console run 23 Oct) passed DOWN+SELECT through to it
during games: nothing woke it (its log: 0x2000 read as 0x24 279 times). v6 (this version, "v6
in short") sends it SELECT alone instead: **works on the console** (23 Oct). v7 ("v7 in short")
adds the **Super FX (GSU)** next to the SA-1; not yet run on the console.

## v7 in short (23-24 Oct 2026): Super FX (works on the console, v7.2)

Goal: Yoshi's Island (GSU-2) and Star Fox (GSU-1) in the same core as the SA-1 games.

- `USE_GSU = 1` (top parameter, `snes_sdram_core.sv`): main.v's GSUMap. The GSU reads the ROM a
  byte at a time (ROM_WORD 0, lane 0), as the 8-bit controller delivers it, and uses the BSRAM
  port for its RAM: the existing 64 KB block-RAM BSRAM is the GSU RAM (Yoshi's Island and Star
  Fox have 32 KB; kept across reloads like the other save RAMs).
- `rom_loader.sv`: GSU carts (map 20, type 13/14/15/1A) -> ROM_TYPE 7x, RAM mask from ROM byte
  0x7FBD (FF = Star Fox's 32 KB; at most 64 KB), as the Pocket's `rom_parser.sv`. The status
  page shows "LoROM + SUPER FX". `tools/rom2spc.py` reports it too; `make load-spcs` builds
  `yoshi.spc` and `starfox.spc`.
- **GSU.vhd is patched** (`quartus/snes_load/gsu_rom_hold.patch` -> `build/snes_load/GSU.vhd`):
  1. **ROM address hold.** The GSU's ROM address mux falls back to its program counter
     (PBR:R15) whenever it isn't reading ROM, i.e. whenever it runs from its cache. That changes
     almost every clock, and our controller starts an SDRAM read for every new address: the
     ROM sequencer never idles, real fetches wait, and the S-DSP's ARAM accesses starve. In
     simulation Yoshi's Island hung after starting the GSU (frame ~74 of the game; Mesen2 has
     the GSU done by frame 77), with 20 001 ROM addresses held 4 clocks whose byte never
     arrived and 2 102 late ARAM reads (`TB_ROMLAT=1` histogram). Patched: the address only
     follows the GSU in its LOAD/FETCH/CACHE states (and to the SNES CPU's address when the GSU
     doesn't own the ROM), otherwise it holds the last value. Then every byte arrives within 3
     clocks, no address goes unserved, 1 late ARAM read, and the game shows "Nintendo
     Presents" as in Mesen2.
  2. **Refresh hint.** ROM_RD_N (only MiSTer's SDRAM controller used it) becomes "this clock
     ends on a GSU clock-enable edge" (FLAG_GO and CLK_CE). At 10.7 MHz (GSU-1) a FETCH takes its
     byte at the second enable edge after the address change: 2 clk_sys, which our reads meet
     (latency 2) unless a refresh is in the way. The top's `rfsh_ok` for GSU carts is
     `~SYSCLKR_CE & ROM_OE_N`, so soft refreshes only start in clocks after which no GSU access
     can begin. At 21.4 MHz (GSU-2, Yoshi's Island) a fetch has 3 clocks, a cache fill 4, a
     LOAD 6.
- Fits with the SA-1: 87 % of the ALMs (v6: 79 %), 300 / 308 M10K. **Timing is not met**
  ("v7 build"), so there is also a Super FX-only build, `quartus/snes_gsu`.

### v7 build (24 Oct)

v6 met timing with +0.5 ns on clk_mem. With the GSU the fill level costs ~1 ns on the paths
into the controller's ARAM sample logic (`sdram_rom8.sv`, everything decided at k = 2: the
S-DSP/SPC700's address and data from clk_sys, the write queue and forwarding compares). Tried:
- fitter seeds 3 and 4 (worse: -0.54 to -0.86 ns; note that `quartus_fit --seed` rewrites the
  .qsf, flattening the sourced file lists into it: restore it from git afterwards);
- `OPTIMIZATION_MODE "AGGRESSIVE PERFORMANCE"`: -0.25 ns, but with the changes below it
  overflowed the LABs (1887 of 1848), so it's back to HIGH PERFORMANCE EFFORT;
- clk_mem lagging clk_sys by 333 ps (`SDRAM_MEM_LAG_PS`; the SDC counts one more edge for
  clk_sys -> clk_mem setups when there is a lag), a multicycle 2 from the ARAM write queue to
  upd/upd_d/upd_tag (they load only at k = 2; the queue changes only at k = 0 and 2), and
  `rom_loader`'s end-of-transfer compares registered (they became critical).
Result after a fitter-only 0.15 ns hold margin on clk_sys -> clk_mem (commit 5fc9bbb; the
snes_gsu build had a 41 ps hold miss without it): **clk_mem setup -0.27 ns at slow 85 °C, -0.03
ns at slow 0 °C**, hold met everywhere, pins checked (`TESTCORES/16-q-snes_load-v7.cor`). The
Super FX-only build meets everything (clk_mem +0.28 / +0.39 ns; `17-q-snes_gsu.cor`). The remaining paths run from the ARAM sample's
own state and the SPC700 into the write queue registers. At room temperature and typical
silicon this is likely to work, but it isn't guaranteed. The real fix is to pipeline the ARAM
sample (register the port at k = 2, decide at k = 3), which needs care: a read completion at k = 3
must then also see a write to its address sampled in the same clock (today `a_stale`, set at
k = 2, covers that).

Rebuilt with the loader fix (24 Oct ~06:00, now on the card as 16 and 17): combined **-0.126 ns
at slow 85 °C, +0.069 ns at 0 °C**, hold met; Super FX-only setup +0.18 ns, hold 2 ps short at
fast 0 °C on SPC700 -> `last_wd` (harmless: last_wd loads only at the k = 2 sample, not at the
k = 0 edge that check is for). A 0.25 ns fitter hold margin for snes_gsu met that hold but left
setup 9 ps short, so it stayed 0.15.

Bug in the first v7 cards cores (fixed in 6ab00a1, rebuilt the same night): the registered
end-of-transfer flags `got_all_q`/`idle_long_q` still held the state from before a file when
its first byte arrived (`idle_long` true after the wait in the browser, `got_all` from the last
file), so the transfer could end at once. The Yoshi/Star Fox sims (`TB_FAST`, one file, no wait)
didn't show it; the SA-1 regression did (second file 98815 of 98816 bytes, 1 order error). Both
flags now clear on every file byte. Lesson: after any `rom_loader` change rerun the SA-1 regression
(`make sim-snes-load`, or `Vtb 62 ... sa1test.spc` on the GSU build: byte gaps, a second file),
not only the game sims.

`quartus/snes_gsu` (`make out/q-snes_gsu.cor`): the same top with `USE_SA1 = 0` (sources,
pins, SDRAM settings and SDC all from `quartus/snes_load`), to test the Super FX without the
timing doubt. SA-1 carts don't run on it.

Fixed after the first v7 builds (`aram-case3`, 24 Oct morning; both found with a new GSU-like
phase C in `make sim-sdram-rom8`: byte reads, addresses held 1-6 clk_sys, reads back to back):
- **late ARAM reads**: Yoshi's Island had ~2 per 6 s, and 26 over a 700-frame run (11.7 s;
  `n_ar_late`; Star Fox and the SA-1 games 0). Each time the ROM sequencer was in the last cycle
  (cnt 6) of a read started at k = 4 when the ARAM could have started, and the controller
  started ARAM operations only with the ROM side idle (case I) or 3 cycles into a read (case
  II), so such a read blocked both k = 0 edges of its run. Effect: an S-DSP/SPC700 read got the
  previous byte (phase C: 18 late, 11 wrong bytes). **Case III** now starts it in that last
  cycle (bank 3 vs the ROM's banks 0-2, its PRECHARGE was the edge before; from slot 1 on it is
  case I; a write goes as write I: the read's last word left DQ by slot 2 + tHZ, the WRITE drives
  it at slot 3). Phase C: 0 late, 0 wrong, ~1500 case III starts. Yoshi's Island, 360 frames:
  PASS, ARAM 0 late (v7.0: 2 by then, all 26 of its 700 frames at ROM `st 3 cnt 6`); SA-1
  regression PASS. Build: combined clk_mem setup -0.29 ns at slow 85 °C (SPC700 -> `upd_d`, the
  ARAM decision), which v7.2 addresses.
- **lane 0 after back-to-back reads**: a ROM read started right after an even-address read
  got lo_sel set again by the old read's copy to cap_lo (rd2[CPY] came at the new read's
  cnt = 1, after its clear), so rom_q[7:0], the GSU's lane, showed the old word until the next
  read (phase C: 336 wrong bytes). The ACT now drops the pending copy (the core has left that
  word). Yoshi's/Star Fox's traffic apparently never does this (their ROM histograms are the
  same with the fix). Star Fox, 460 frames with both fixes: PASS, ARAM 0 late.

**v7.2** (24 Oct morning, `TESTCORES/19-q-snes_load-v72.cor`): the ARAM port registered at
k = 2 (`s_*`, straight from the core's signals) and decided at k = 4, with case III and the
cap_lo fix. The SPC700 -> `upd_d` paths that limited the combined core are gone: **clk_mem
setup +0.58 ns at slow 85 °C**, hold met, pins checked, the combined SA-1 + Super FX core meets
timing. A read still starts at the next k = 0 (decided at k = 4 instead of 2, the same edge);
the k = 3 read completion checks the k = 2 sample itself (`rd_now`, `s_wnew`); write updates
reach ar_q one clk_sys later (8 clk after the address change, the DSP takes it >= 25 clk on).
SDC: `s_*` -> the decision registers two cycles. `make sim-sdram-rom8` and the SA-1 regression
pass; **Yoshi's Island 700 frames PASS, ARAM 0 late** (v7.0: 26), **Star Fox 460 frames PASS**,
ARAM 0 late; the frames checked (Yoshi 345-699, Star Fox 300-459) are pixel-identical to v7.0's.
Card's spc.cor since 24 Oct 08:10.

### v7 simulation

`make sim-snes-gsu-yoshi` / `sim-snes-gsu-starfox` (Verilator, own work dir
`SNES_GSU_SIM` = `~/scratch/snes-gsu/sim`; GSU.vhd goes through
`quartus/snes_load/sim/gsu_split.py`, which splits the GSU's three processes that have both a
`falling_edge` and a `rising_edge` branch into one process per edge: GHDL's synthesis rejects
the combined form, and no signal is assigned on both edges, so the split is equivalent).
Results (24 Oct, frames numbered from the start of the simulation; the game starts ~30 frames
in for Yoshi's Island, ~18 for Star Fox):
- **Yoshi's Island**: "Nintendo Presents" from frame ~110, then the Super FX-drawn stitched
  Nintendo logo at frame ~330, both as in Mesen2 (its frames 80-260 and 300)
  (`photos/sim-yoshi-logo-2026-10-24.png`). 0 SDRAM model errors, ROM bytes within 3 clocks.
- **Star Fox** (GSU-1, 10.7 MHz, with the refresh hint): the starfield with "NINTENDO PRESENTS"
  at frame ~320, as Mesen2's frame 300 (`photos/sim-starfox-title-2026-10-24.png`); long run
  (460 frames): the GSU-drawn 3D Arwings of the intro at frame 459
  (`photos/sim-starfox-arwings-2026-10-24.png`), PASS, ARAM 0 late; the ROM histogram has 6
  addresses left before their byte (5 after 2 clk_sys, 1 at once), the same with the case III /
  cap_lo controller: short-lived addresses the core moved past, not a controller fault.
- **Yoshi's Island** long run (700 frames): "A long, long time ago..." under the logo at frame
  ~620 (`photos/sim-yoshi-story-2026-10-24.png`).
- Before the ROM address hold, Yoshi's Island stayed black: the GSU never finished its first job.

`TB_ROMLAT=1` adds the ROM byte latency histogram (clk_sys edges from an address change to its
byte on rom_q[7:0], and addresses dropped before their byte came). Reference frames from
Mesen2 (headless test runner; see notes/snes-quartus.md for the setup; Lua io/os access needs
`{"Debug":{"ScriptWindow":{"AllowIoOsAccess":true}}}` in its settings.json now).

## v6 in short (23 Oct 2026)

- The PIC wakes on **SELECT alone** in 0x2000 (0x04), not on DOWN+SELECT (0x24): in v2/v3 it saw
  SELECT alone, or SELECT left alone as DOWN was let go first; v5 showed it only 0x24 and then
  0. So on a DOWN+SELECT press during a game (PIC asleep) the core shows the PIC a clean SELECT
  press of its own: 0x2000 = 0x04 for 300 ms (`SEL_PULSE_MS`), then 0, whatever is held. The
  PIC wakes, the core shows it (as v5) and gives it the real buttons once all are released. If
  the PIC is already awake behind the game, DOWN+SELECT just shows it (no pulse: SELECT there
  would be its BACK TO GAME).

## v5 in short (23 Oct 2026, superseded by v6)

- During a game the pad registers read 0 **except while DOWN+SELECT is held**: the PIC sees
  DOWN+SELECT and wakes, SELECT alone and L+R+SELECT (our pages) never reach it. The keys' menu
  view (L+R+SELECT+START) no longer passes buttons to the PIC either. Everything else as v4 (a
  PIC woken without DOWN+SELECT would still stay hidden; when its screen comes up it gets 0s
  until all buttons are released).

## v4 in short (23 Oct 2026, superseded by v5)

- **Player 2** on D6 (`pad_poll.sv` reads it in the same poll as T12; LATCH and CLOCK are shared),
  a second virtual 4021 for the SNES (`snes_sdram_core.sv` has separate port clocks and a
  `joy2_d0`). Without a pad, port 2 reads as empty. The scanner is gone from the build.
- **SELECT alone**: the PIC watches the controller lines itself and wakes on SELECT whatever the
  poll waveform (v3 run), and that can't be hidden from it. So the core now decides what is
  shown: a PIC that wakes while DOWN+SELECT is held (or was, within 1.5 s: `WAKE_MS`) is shown
  at once, as before; one that wakes on anything else (SELECT alone, L+R+SELECT for our pages)
  stays **hidden**: the game stays on screen and gets every button, the PIC's pad registers
  read 0 (so its browser can't act; OPTIONS shows `view GAME+PIC`), and DOWN+SELECT later shows
  it. Whenever the PIC's screen comes up during a game, the PIC gets 0s until all buttons are
  released (a held SELECT would be its BACK TO GAME). Poll timing is STOCK again by default
  (L+R+UP: FAST (v1)).
- Status page: the PORT 2 row shows `data D6`, port 2's 32 bits and std pad / no pad, and the
  two main keys.

## v3 in short (23 Oct 2026, superseded by v4)

- **SELECT alone opened the PIC's browser** in a game (Denley, v2 run): the PIC watches the
  controller lines itself, and its "playing" mode reacts to SELECT, so the JB combination
  DOWN+SELECT only worked because it contains SELECT. In the v1 run, with v1's fast poll waveform
  (1 kHz, 12 us latch, 6/6 us clocks), L+R+SELECT and L+R+START in Kirby never woke it; v2's
  stock waveform did. So v3's poll timing **AUTO** (default) uses v1's fast waveform while a game
  runs and the PIC is quiet, and switches to the stock waveform while DOWN+SELECT is held (and
  1.5 s after), so the PIC sees SELECT only with DOWN. Everywhere else (browser, loading, PIC
  active) it stays stock, as v2. The game gets the same bits either way. If the PIC turns out to
  follow the fast waveform too, L+R+UP on the status page cycles AUTO -> STOCK -> FAST (v1).
- **Player 2.** Port 2's data pin is unknown (spc.cor reads port 1 only; notes/controllers.md,
  "Port 2"). `pad_scan.sv` samples the 29 pins it could be (only read, weak pull-up as before) at
  the poll's sample points and takes the first that answers like a pad and independently of
  port 1 as port 2: a second virtual 4021 for the SNES (`snes_sdram_core.sv` now has separate
  port clocks and a `joy2_d0`). Without a pad, port 2 reads as empty. The status page's KEYS row
  is now **PORT 2**: pin, polarity, its 32 bits, std/no pad, and one character per candidate.

## v2 in short (23 Oct 2026)

- **Back to the menu.** v1's console run showed that after a file the PIC writes a few
  registers (`0x1000_0021` = F8 last) and then does nothing on the link (notes/pic-link.md,
  "After a file"). The stock spc.cor has no output that depends on the pad and no combination
  detector (decoded), so the PIC must watch the controller lines itself; the JB menu
  combination is **DOWN + SELECT**. v2 therefore polls the pad with the **stock core's
  waveform** (16.17 ms, latch 8.3 us, 33 clocks 0.6/18.7 us; v1: 1 kHz, 12 us, 32 x 6/6 us) and
  answers the pad registers **all the time** as spc.cor does (v1: only while its browser view was
  up), and **follows the PIC**: as soon as the PIC writes its screen or runs its UI loop again
  after a game started, the core shows the PIC's screen, gives it the pad (the game gets
  nothing) and accepts a new file; 600 ms after the PIC goes quiet (e.g. SELECT = "back to
  game") the game is shown again. L+R+SELECT+START (1 s) toggles the same view by hand.
  Options (status page, L+R+UP/DOWN/LEFT): v1 poll timing, v1 pad gating, follow off.
- **Save RAM 64 KB.** The SPC700's 64 KB ARAM moved from block RAM to SDRAM bank 3 (a new port
  of `sdram_rom8.sv` in command slots the ROM reads never use), which freed 64 M10Ks: BW-RAM/
  SRAM is now 64 KB of block RAM (v1: 8 KB). Super Mario RPG and Kirby's Dream Land 3 declare
  32 KB (header RAM size 05; Kirby Super Star 03 = 8 KB). ROMs up to 6 MB (banks 0-2).
- **Saves within a power-on.** BW-RAM/SRAM is kept when the game booted is the same as the last
  one (ROM CRC-32), cleared when it is another. Saving to the SD card isn't possible from the
  SPC player (below, "Saves").
- **Log.** Every link transaction but the file bytes (reads, UI loop and pad reads included) goes
  into a 512-entry log with times (first and last), shown on the status page (2 newest) and in a
  log view that pages through all entries by itself.

## What it does, start to finish

1. Power-up: answers the PIC's status poll at `0x2xx4_xxxx` with **02** from the first read
   (a constant in `link_ui.sv`), takes its set-up writes, and draws the player's screen
   (`0x1018_0000`) full-size: the **file browser**, with the cursor bar where the PIC puts
   attribute 0x60.
2. The pad (polled by the core, `pad_poll.sv`) goes to the PIC exactly as the stock core passes
   it (`0x2000` = buttons 7-0 = RIGHT LEFT DOWN UP START SELECT Y B, `0x2001` = R L X A,
   `0x2008` = 01 for a standard pad): the user moves with the D-pad and starts a file with the
   player's RUN button. hwtest v5/v6 found RUN = bit 1 and BACK = bit 0; with the bits passed
   straight through, that is **Y = RUN, B = BACK** on a real pad (the stock player's own
   behaviour, whatever its icons say).
3. The player checks the file is an SPC and writes the whole file to link address 0xFF00 +
   offset (hwtest v6b). From the first file byte the **diagnostics page** is on screen: bytes,
   CRC-32 of the file and of the ROM part as they arrive, the info block, the header.
4. End of the transfer: all ROM bytes the info block announces have arrived (or 250 ms without a
   file byte). The mapper comes from the ROM header, the ROM is read back from SDRAM and its
   CRC-32 compared with the info block's ("= INFO CRC: OK" in green, or "MISMATCH").
5. 4 s later (time to read or photograph the page) the SNES leaves reset and the picture
   switches to the game. On a mismatch it doesn't start (L+R+A held 0.5 s starts it anyway).
6. The PIC writes a few registers (`0x1000_0021` = F8 last), runs its UI loop once more and goes
   quiet on the link (v1 console run). The core keeps answering (pad registers = the pad, as
   spc.cor) and logs everything. If the PIC wakes up (its menu combination, DOWN + SELECT, by
   the v2 decode) and writes its screen or runs its UI loop, the core shows its screen, gives it
   the pad and accepts the next file (step 3 again).

Keys (v2, v3 the same except L+R+UP; exact combinations, nothing else held): **L+R+SELECT** (0.5 s) cycles the
diagnostics: status page -> log view -> off; **L+R+SELECT+START** (1 s) the menu view (the
PIC's screen; the PIC gets the pad, the game doesn't; RUN on a file loads it) on/off; **L+R+A**
(0.5 s) boot after a failed verify; on the status page **L+R+UP / DOWN / LEFT** (0.5 s) toggle
the options (pad poll STOCK/FAST; v3: AUTO -> STOCK -> FAST (v1), shown as AUTO:FAST /
AUTO:STOCK while AUTO; PIC pad ALWAYS/GATED, follow ON/OFF), shown on its OPTIONS line. (v1: L+R+SELECT page, L+R+START browser.) While a game runs, a file the PIC sends while
the menu view is down is ignored (counted as "lost ... ign"). The JB menu combination DOWN +
SELECT is the PIC's (if it watches the pad lines); the core only follows what the PIC does.

## Files

| File | What |
|---|---|
| `tools/rom2spc.py` | ROM → `.spc` wrapper (format below); prints the CRCs the page shows |
| `quartus/snes_load/snes_load_top.sv` | top: clocks, link, loader, SDRAM, SNES, views, video mux, audio |
| `quartus/common/link_ui.sv` | PIC32 link slave: status 02, pad registers, browser screen RAM, file stream, log |
| `quartus/common/rom_loader.sv` | file → SDRAM, CRCs, info block, header scoring, mapper, read-back, boot |
| `quartus/common/sdram_rom8.sv` | 8-bit SDRAM controller for chip B (from `sdram_rom.sv`) |
| `quartus/common/pad_poll.sv` | controller poller (PAD_CFG 0 wiring), port 1 on T12, v4: port 2 on D6 |
| `quartus/common/pad_scan.sv` | v3's port 2 finder (29 candidate pins, notes/controllers.md "Port 2"); not built since v4 |
| `quartus/common/overlay.sv` | browser and diagnostics text layers on snes_video's counters |
| `quartus/snes_load/diag.txt` | diagnostics page template (`tools/mkscreen.py`, now 64 status words) |
| `quartus/snes_load/sa1_vbp.patch` | SA1.vhd: VBP takes its ROM word one SA-1 cycle later (below) |
| `quartus/snes_load/snes_load_pll.v` | PLL: clk_sys 21.44196 MHz and the SDRAM clocks at 5 × (107.21 MHz) |
| `quartus/snes_load/sim/` | `tb_sdram_rom8.sv` (controller, iverilog), `tb.sv` + `tb_snes_load.cpp` (whole core, Verilator) |
| `quartus/snes_load/*.qsf/.qpf/files.tcl/pins.tcl/.sdc/sdram_cfg.tcl/sdram_params.tcl` | project |

Shared with `quartus/snes_sdram`: `snes_sdram_core.sv` (now with `rom_type`/`ram_mask` inputs
and `sysclkr_ce` out; snes_sdram passes its old constants; its simulation takes `TB_TYPE`, which
ran Gradius III as a 16-bit reference), the sim models
(`sdram_model.v`/`sdram_cyc.v` got a `COL_BITS` parameter: 9 = chip B's 512-column page).
`snes_video.sv` exports its counters (`cx`/`cy`) for the overlay.

Make targets: `out/q-snes_load.cor`, `load-spcs` (the test files), `sim-sdram-rom8`,
`sim-snes-load`, `sim-snes-load-gradius`, `sim-snes-load-kirby`, `sim-snes-load-kdl3`,
`sim-snes-load-smrpg`. v2: `snes_sdram_core.sv` has `ARAM_EXT` (ARAM through `ext_aram_*`
ports) and a BW-RAM clear port (snes_sdram ties them off); the SDRAM models end bursts only on
READ/WRITE/BST/PRE of the bank and flag a WRITE while read data is due.

## The file (`tools/rom2spc.py ROM OUT.spc [--title T] [--length S]`)

| file offset | link address | contents |
|---|---|---|
| 0x00000-0x101FF | 0xFF00-0x200FF | a complete, silent `.spc`: header "SNES-SPC700 Sound File Data v0.30", ID666 tag (song title = ROM name, length 999 s), 64 KB SPC700 RAM with `bra *` at $0400, DSP registers with FLG = mute and nothing keyed on |
| 0x10180-0x101BF | 0x20080-0x200BF | info block in the SPC format's unused 64 bytes: "SNTROM01", ROM size, ROM CRC-32, copier-header flag, the tool's mapper guess, header ROM/RAM size bytes, 32-byte name |
| 0x10200- | 0x20100- | the ROM (a 512-byte copier header is dropped when size % 32 KB = 512) |

ROM byte k arrives at link address 0x2_0100 + k and goes to SDRAM byte k. Test files
(`make load-spcs`; ROMs from the SD-card backup `~/scratch/sd-backup-2026-10-21/SNES`):

| file | size | CRC-32 file | ROM | ROM CRC-32 | header → mapper |
|---|---|---|---|---|---|
| `build/snes_load/sa1test.spc` | 0x18200 | AD3E85A3 | 32 KB | 8C5F7E54 | "SUPERNT SA1 TEST" map 23 type 35 → LoROM + SA-1, ROM_TYPE 60, masks 7FFF / 7FF |
| `build/snes_load/gradius3.spc` | 0x90200 | A70084ED | 512 KB | CD973979 | "gradius 3" map 20 type 00 → LoROM, ROM_TYPE 00, mask 7FFFF, no RAM |
| `build/snes_load/kirbyss.spc` | 0x410200 | 40E67CE5 | 4 MB | 89D0F7DC | "KIRBY SUPER DELUXE" map 23 type 35 → LoROM + SA-1, ROM_TYPE 60, mask 3FFFFF, RAM 1FFF (8 KB) |
| `build/snes_load/kdl3.spc` (v2) | 0x410200 | A776507C | 4 MB | EC8A48F6 | "KIRBY'S DREAM LAND 3" map 23 type 35 RAM 05 → LoROM + SA-1, mask 3FFFFF, RAM 7FFF (32 KB) |
| `build/snes_load/smrpg.spc` (v2) | 0x410200 | 8C4C439B | 4 MB | 1B8A0625 | "SUPER MARIO RPG" map 23 type 35 RAM 05 → LoROM + SA-1, mask 3FFFFF, RAM 7FFF (32 KB) |
| `build/snes_load/sa1test20.spc` (v2) | 0x18200 | AEB15DDA | 32 KB | 8C5F7E54 | the SA-1 test with a 20 s ID666 song length (`--length 20`) |

## SDRAM: chip B alone, 8 bits, 5 x clk_sys (`sdram_rom8.sv`)

Chip A never drives (`notes/sdram.md`), so the ROM lives in chip B: 4 banks × 4096 rows × 512
columns × 8 bits = **8 MB** (byte b → bank b[22:21], row b[20:9], column b[8:0]). Same command
set, MRS pattern (spc.cor's 0x037: CL3, full page), closed-page single accesses and refresh
policy as `sdram_rom.sv` (`notes/snes-sdram.md`); AB10 = chip B's DQM driven low as spc.cor
does; the DQM-candidate pins are not driven at all.

**Clock: 107.21 MHz = 5 × clk_sys** (`snes_load_pll.v`, VCO 750.47 MHz: clk_sys /35, the
SDRAM clocks /7), not 4 × as in snes_sdram. At 4 × the SA-1 has the address → ACT decision in
one clk_mem cycle and the data → core path in 1.5; with all 22 address bits live (a 4 MB ROM;
snes_sdram had `ROM_MASK` = $7FFF constant, which folded most of the compare away) and the mapper
chosen at run time, the first builds here missed setup by 1.6–3.8 ns however the logic was
arranged: the 8-cycle budget (address ~8 ns + compare + ACT→READ→data 5.5 cycles + data path ~16
ns) was simply over. At 5 × the SA-1's bus cycle is 10 clk_mem cycles (93.3 ns, unchanged) and the
SDRAM's fixed part shrinks from 64 to 51 ns:

| clk_mem edge after the address change at clk_sys edge E | what |
|---|---|
| k = 0 (E itself), 1 | the core's address may still be settling: no ROM read starts, address registers keep their value |
| 2 | ACT (the address path has 2 cycles = 18.7 ns) |
| 4 | READ A |
| 6 | (A even) READ A + 1 |
| 7 | PRECHARGE (tRAS 5 cycles); next ACT from 9 (tRC 7) |
| 8 (+0.83 ns) | byte A in `cap` (rise 4, `CAPTURE_HALF` 8) |
| 10 | the SA-1 / SNES CPU take it (2 clk_sys after E); A copied to `cap_lo` |
| 10 (+0.83 ns) | (A even) byte A + 1 in `cap`: rom_q = {A + 1, A} |

- `rom_q` = {cap, lo_sel ? cap_lo : cap}: until the copy both lanes carry byte A. Every byte
  consumer in main.v picks its lane by address bit 0 (SA-1 65C816, the SNES CPU through the
  SA-1, SA-1 DMA) or uses lane 0 (the Lo/HiROM mapper, `ROM_WORD` = 0), so each gets byte A.
  After an even start the word is complete, and the next byte (A + 1, the usual next instruction
  byte) needs no new read. Two bytes per read matter for refresh: sequential SA-1 code reads
  every other cycle, which leaves hidden refresh slots (byte-per-cycle reads would leave none).
  Both bytes go through the same I/O-cell capture register and capture point (a first version
  took beat 1 of the burst into a fabric register: its pin-to-register routing ate the window).
- The low lane switches from cap to cap_lo (two copies of byte A) at k = 10, the same edge where
  the core takes A, so nothing sees it change; the capture enable is taken over on clk_cap's
  falling edge (clk_cap's rising edge comes 0.83 ns after clk_mem's).
- A new read starts when rom_q doesn't hold the byte asked for: another word, or the same word
  after an odd start (only A valid), or any other byte with `ROM_WORD` = 0.
- The only consumer of a whole 16-bit word in the cycle it addresses it is the SA-1's
  **variable-length bit processing** (VBP: `VBP_BUF <= ROM_DI` at k = 10), so `sa1_vbp.patch`
  makes VBP take its word one SA-1 cycle later while VDA stays on the ROM address (and wait again
  if the SNES CPU takes the ROM bus in between). VBP refills then take one SA-1 cycle more; the
  SA-1 stalls on ROM accesses during VBP anyway, and the next VDP read from I-RAM code is >= 3
  cycles away, so programs can't see the difference. The SA-1 test ROM doesn't use VBP;
  `sim-sdram-rom8` checks the word timing.
- Capture point: with the datasheet window (tAC 5.4, tOH 2.7 ns at CL3) rise 4 with the capture
  clock 0.83 ns behind the SDRAM clock source takes the byte for board delays D (clock out +
  traces + data in) of 2.8–9.4 ns; hwtest v2/v3 (74.25 MHz) found chip B clean at fall 3.5 and
  rise 4, i.e. D = 4.0–8.1 ns, inside with >= 1.2 ns each side (the 4 × design's fall 3.5 +
  1.67 ns covered −1.0–7.9). `sim-sdram-rom8` (capture clock without offset) passes for D 2–7
  ns.
- Refresh: REF (7 cycles) only at k = 2–4 of a clk_sys cycle with `rfsh_ok` (no critical read can
  start at the next clk_sys edge: SA-1 carts `~ROM_OE_N & ~SYSCLKF_CE` as before, the Lo/HiROM
  mapper `~SYSCLKR_CE`, since `DSP_LHRomMap.vhd` registers the ROM address on SYSCLKR_CE only)
  and no read pending; it then ends before the earliest next read. Forced from 14 µs,
  unconditional at 15.4 µs.
- Timing structure: the address goes to the address pins and the bank/column registers with
  every idle cycle at k >= 2 (NOP and REF ignore them); only the state register and the command
  pins depend on the compare; what a read start records (last address, lane flags, statistics)
  is set one cycle later from registered copies; the phase k comes from registers (only `tog_d`
  samples clk_sys's toggle). The SDC gives clk_sys → controller paths 2 cycles (setup at k = 2,
  hold at k = 0).
- Writes and aux reads (the loader) only while ROM reads are off: one byte each (ACT, WRITE, BST,
  PRE: 7 cycles, both DQ bytes driven), from a 16-entry FIFO; the PIC's bytes come >= 300 ns
  apart (32 cycles). The read-back of 4 MB takes ~0.3 s.

## Loader (`rom_loader.sv`)

States: 0 waiting (browser), 1 loading, 2 parsing, 3 verifying, 4 verified (shown 4 s), 5
running, 6 verify failed, 7 not a ROM (a plain `.spc`, nothing after 0x10200). File bytes at
link 0xFF00-0x0FFF_FFFF only (the PIC's 0x1EAF-byte set-up block at 0x0000_0000 stays out).
Running CRC-32s of the whole file and of the ROM part in arrival order, and a count of bytes not
at the next expected offset ("order"; 0 when the PIC sends in order, as seen so far).

Mapper (as the Pocket's `rom_parser.sv` / MiSTer): the 32 header bytes at ROM 0x7FC0 (LoROM),
0xFFC0 (HiROM) and 0x40FFC0 (ExHiROM) are kept while they pass; scores +4 checksum +
complement = FFFF, +2 dev id 33, +1 each for type < 8, ROM size < 16, RAM size < 8, region < 14,
+2 for the matching map mode (20/22, 21, 25/35), ExHiROM +4 if any. LoROM if its score is >=
both others, HiROM if >= ExHiROM, ExHiROM if > 0. SA-1 = map 23 and type 32/34/35 → ROM_TYPE
6x; other chips (DSP, GSU, CX4, SDD1, SPC7110, S-RTC, OBC1) aren't in this core: shown as "(no
chip)" and started as plain Lo/HiROM. ROM mask = next power of two of the size - 1; RAM mask =
(1 KB << header RAM size) - 1. The tool's guess is in the info block and shown next to it.

BW-RAM/SRAM: **64 KB of block RAM** (v2, `BSRAM_AW` 16; v1 8 KB). The mask is the header's
(32 KB for Super Mario RPG and Kirby's Dream Land 3), so headers above 64 KB (RAM size 07, 128
KB) would mirror. Kept across a reload of the same game (ROM CRC-32 equal to the last game
booted: "KEPT" on the status page), cleared to zero in the SHOW state otherwise ("CLEARED").

ARAM (v2): 64 KB in SDRAM bank 3 at byte 0x600000 (sdram_rom8.sv's ARAM port), cleared to zero
through the write port in SHOW (64 K writes, ~4.3 ms) before every boot. ROM bytes at 6 MB and
above count as "lost ... 8MB" (n_big) and aren't verified.

## Saves (v2): not to the SD card

Saving BW-RAM/SRAM to the card would need the PIC to read it back and write a file. From the
SPC player there is no such path [likely]: in every session logged so far (hwtest v1-v6, snes_load
v1) the player read only the status (`0x2004`) and the pad registers; the stock core's read map
(notes/pic-link.md, "Read data") has no bulk memory window the player uses; and the JB
firmware writes saves (`/SAVES/SNES/`, with its "Save?" prompt) only for its own ROM loader /
cartridge core, not for the SPC player, which has nothing to save. So v2 keeps saves only while
the console is on: the RAM is left as it is when the same game (ROM CRC-32) is booted again,
and cleared when another game is booted (one game's saves at a time; a power cycle loses them).

## SDRAM ARAM port (v2, `sdram_rom8.sv`)

The S-DSP/SPC700 make one RAM access per DSP substep (CEGen at 4.096 MHz: every 5 or 6 clk_sys);
the address changes at a clk_sys edge, reads are taken at the next DSP CE edge (>= 25 clk_mem
later), writes are asserted for every clk_sys edge of the substep. The controller samples the
port at k = 4, keeps a 4-entry write queue (repeats dropped, a write to the address in `ar_q`
updates it, a read of a queued address is answered from the queue) and runs one bank-3
operation at a time, started only at k = 0 when the ROM sequencer is idle (case I) or three
cycles into a read (case II), in edges the ROM schedule never uses (slots after the start; a ROM
read with ACT at slot a uses a, a+2, a+4, a+5):

| operation | ACT | READ/WRITE | BST | PRECHARGE | data |
|---|---|---|---|---|---|
| read | 0 | READ 3 | – | 5 | captured in `cap` at 7, `ar_q` at 8 (k = 3) |
| write, case I | 0 | WRITE 3 | 4 (unless the ROM's READ is there) | 5 | bus driven at 3 |
| write, case II | 0 | WRITE 8 | 9 (unless the ROM's READ is there) | 10 | bus driven at 8 (the ROM's last word is due at 4) |

A ROM ACT is held off when its own edges (now, +2, +4, +5) would hit one of these (only reads
that were already late can); REF waits for the bank. `cap` is the shared I/O-cell capture
register: the ROM byte in it is copied to `cap_hold` just before an ARAM byte replaces it and
rom_q's high lane takes it from there until the next ROM capture (one more LUT on that path).
Latency: address at E, request seen at E + 4, start at E + 5 (or E + 10 if blocked), byte in
ar_q at E + 13 (E + 18). `sim-sdram-rom8` checks it against the timed model with an S-DSP
stand-in (55 % reads, half of recently used addresses, 35 % writes, every read checked at the
substep's end against a shadow copy) next to the SA-1 traffic, and the models now treat a WRITE
while read data is still due as an error and only end bursts on READ/WRITE/BST/PRE of the bank.

## Link (`link_ui.sv`)

Port as `link_logger.sv`/`link_loader.sv` (2-FF synchronisers on clk_mem, 107.2 MHz; reads
only after the port is armed). Status `0x2xx4` = 02; `0x2000`/`0x2001` = pad bits (v2: always,
as spc.cor; option GATED: 0 unless the menu view is up, as v1), `0x2008` = 01 (03 if no
standard pad answers); everything else 00. Screen writes (`0x1018_0000`-`0FFF`) go to a 4 KB
RAM the overlay reads. Counters: status, UI-loop and pad reads, all reads and writes, times of
the newest transaction, UI-loop write and screen write, and the newest byte written to
`0x1000_0021` (with its time and count).

The **log** (v2): a run = consecutive writes or reads at consecutive addresses (ended by any
other transaction or 2 ms without one); everything but the file bytes is logged. Entries (512,
M10K): {index, sequence number, kind 0 write / 1 read, address, bytes, first byte, repeats,
T first, T last}. Before the first file byte new entries go to a ring at 384-511; from the first
file byte on to 0-383 in order until those are full, then to the ring again. A run equal (kind,
address, bytes, first byte) to one of the 8 newest entries only bumps that entry's repeats and
T last, so the UI loop (D120 write, 2 x 2 pad reads) is a handful of entries, and a pad read with
a button held is a new one.

## Video

`snes_video.sv` as before (frame lock to the SNES, 3× lines); `overlay.sv` draws on its
counters and the top delays the SNES picture 3 clocks to line up:

- **Browser**: the 64 × 32 cells of `0x1018_0000` in 16 × 22-pixel cells (the VGA console font
  of hwtest, drawn twice as wide, glyph rows 3-18 of each cell), 1024 × 704 at (128, 8). The
  player's own 8 KB glyph set (`0x1006_0000`) never showed text in any of hwtest v5's formats
  (its "view 04" that rendered the screen legibly used our font), so the browser uses our font.
  Cursor bar (attribute bits 6-5) blue; characters 80-FF are the player's icons, drawn as
  yellow letters by guess from the captured screen: 81 B, 83 Y, 89 #, 8A +, 9E-A3 "START ",
  A4-A9 "SELECT", B2 <, others `*`.
- **Diagnostics** (v2): 80 × 22 cells of 16 × 32 (as hwtest's pages), `diag.txt`; the status
  page:

```
 SUPER NT SNES LOADER v2  T <ms>   state <n> <name>
 LINK  answer 02  status rd <n>  UI loops <n>  pad rd <n>
       reads <n>  writes <n>  addr <link address>  screen <bytes>
       last T <newest transaction>  UI <newest UI write>  scr <newest screen write>  0021=<byte> T <ms> n<count>
 FILE  bytes <n>  CRC-32 <file>  end <highest offset+1>  T <start>-<end>
       ROM bytes <n>  CRC-32 <ROM>  order <n>  lost <FIFO> <bytes>6MB:16 ignored:16>
 INFO  SNTROM01 ok  ROM size <n>  CRC-32 <crc>  tool type <guess>
       name <32 chars>
 HEADER <title>  map <> type <> ROM <> RAM <>
       checksum <sum>/<complement>  scores Lo <> Hi <> ExHi <>  loads <n>
       <LoROM/HiROM/ExHiROM [+ SA-1] [(no chip)]>  ROM_TYPE <>  ROM mask <>  RAM mask <>
 SDRAM read back: CRC-32 <crc>  = INFO CRC: OK | = TRANSFER CRC: OK | MISMATCH
       ROM reads <n>  REF forced <n> stalled <n>  late <n>  gap <max REF interval, cycles>
       ARAM rd <n> wr <n> fwd <n> late <n> drop <n> clash <n>
 SNES  boot T <ms>  frames <n>  pad <raw 32 bits> std pad|no pad polls <n>
       save RAM 64 KB: KEPT (same game as last boot) | CLEARED (another game)  game <CRC>
 OPTIONS UP poll STOCK|FAST (v1)  DOWN pad ALWAYS|GATED (v1)  LEFT follow ON|OFF  view GAME|MENU(PIC)|MENU(keys)
 KEYS ...
 PIC LINK LOG 2 newest below  entries <n>  after file <n in 0-383>
   IDX  SEQ K ADDRESS  BYTES D0 REPEATS T FIRST T LAST
   <2 rows>
```

  The **log view** (mode 3) shows the last three lines' layout: the two title rows, then 20
  entries per page: pages of entries 0-383 (in order, only as many as are used), then 7 pages
  of the ring (384-511); "pg NN/MM" at the top right; the page advances every 2.5 s by itself.

## Pins

86 user I/Os: the HDMI video/audio pins and controller port 1 as `quartus/snes`, the PIC32 link
as `quartus/hwtest` (data driven only while /RD is low), SDRAM command/address/BA/DQ/clock as
`quartus/hwtest`, AB10 constant low (spc.cor's level). Not used (weak pull-up inputs): the eight
DQM candidates / open-drain group, hwtest's 43 stock-constant pins, everything else.
`tools/checkpins.py` passes.

v3: + 29 inputs `p2c` (port 2 candidates: the 12 pins spc.cor leaves unconfigured and its 17
released open-drain pins, notes/controllers.md "Port 2"), with the weak pull-up they had as
unused pins: the board sees the same as with v2. Nothing new is driven.
v4: 87 user I/Os: v2's 86 + `pad_d6` (port 2 data, input, weak pull-up as in v3).

## Simulation

**v6 (23 Oct).** `make sim-snes-load`: **PASS**. The PIC stand-in wakes only on 0x2000 = 0x04
(SELECT alone), as the v5 run showed, and the test now requires exactly one wake. DOWN+SELECT at
+380 ms: the core's SELECT pulse woke it at +417, nothing before (keys' menu view, pages,
SELECT alone: 0 wakes), second file loaded and booted, SA-1 tests pass. The first v6 build of
the pulse ran its full 300 ms even after the PIC woke: the PIC, back in "playing" after the
second file, read SELECT again and woke over the new game (+661 ms); now the pulse ends as soon
as the PIC is active. `TB_DEBUG=1` prints every non-zero 0x2000 the playing PIC reads.

**v5 (23 Oct).** `make sim-snes-load`: **PASS**. The PIC stand-in now does what the v4 console log
showed: while "playing" it reads 0x2000/0x2001 every 33 ms and wakes when 0x2000 has SELECT (the
v4 model watched the lines instead, which is why v4's sim passed and the console didn't). The
keys' menu view at +40/+120, L+R+SELECT x 3 and SELECT alone at +362 woke it 0 times (the game
got SELECT); DOWN+SELECT at +380 woke it at +417 ms, the core showed it, no BACK TO GAME from
the held SELECT, second file loaded and booted, SA-1 tests pass; port 2 as v4.

**v4 (23 Oct).** `make sim-snes-load` (62 frames): **PASS**. The PIC stand-in wakes on SELECT in
two polls of any waveform and treats SELECT in its browser (pad registers) as BACK TO GAME.
The keys' menu combination at +40 ms woke it, and the core kept it hidden (the menu view
appeared only through the keys, `menu_t`); the second press, with the menu view up and the
buttons released in between, was its BACK TO GAME; L+R+SELECT at +200 woke it again, hidden:
0 frames of the PIC's screen without the keys before DOWN+SELECT, 0 pad reads with a button
for the hidden PIC, the game got SELECT alone at +362. DOWN+SELECT at +380 showed it; the held
SELECT didn't reach it (0s until the release), DOWN and Y then picked and sent the second file,
second boot, SA-1 tests pass again, save RAM kept. Port 2 on pad_d6: A reaches the SNES's port 2
latch, 512 port 2 clock pulses while the game had the pads.

**v3 (23 Oct).** `make sim-snes-load` (62 frames, ~7 min): **PASS**. The PIC stand-in now
behaves as the console did: it decodes only stock-shaped polls (LATCH < 10 us) and wakes on
SELECT alone (two polls). Every v2 check passes as before (SA-1 tests twice, menu view by keys,
status page, log view, second file, save RAM kept), and: the L+R+SELECT(+START) combinations
and a lone SELECT at +362 ms reach the game (`pad_raw`) while the PIC ignores the 369 fast polls
of the game; DOWN+SELECT at +380 switches to the stock waveform and the PIC wakes at +397.5 ms.
Port 2: of the candidates (p2c[0] noise, [3] a copy of port 1's line, [9] a second 4021 pad,
[20] flipping every 5 ms, the rest high) p2c[9] (E7) is taken, normal polarity, never another
pin; A on pad 2 reaches the SNES's port 2 latch (0xFF7F), 736 port 2 clock pulses (the SA-1
test's auto-read). Scan string at the end `T11c11111P1111111111T11111111` (the copy stays `c`).
Status page with the PORT 2 row: `build/sim/snes_load-25.png`.

**v2 (23 Oct).** `make sim-sdram-rom8`: the controller with the S-DSP stand-in on the ARAM port
next to the SA-1 traffic: PASS at D_CLK 1, 3.5 and 6 ns (rise 4), fall 3.5 and rise 5 fail as
they must; e.g. at 3.5 ns 1837 substep reads checked, 0 errors, 1134 writes, 0 dropped, 0
clashes, ARAM backdoor = shadow, 0 model errors (with the stricter models), no bus contention,
ROM phase A 0 errors / 0 late.

`make sim-snes-load` (62 frames; the PIC stand-in now behaves as the console did after a file
and then watches the controller lines for DOWN+SELECT, see `sim/tb_snes_load.cpp`): **PASS**.
First load and boot as before (SA-1 tests all pass, from SDRAM, with ARAM in SDRAM); L+R+
SELECT+START shows the menu view (frames 15-19) and hides it, the PIC stays silent; L+R+SELECT
x 3: status page (`-24.png`: v2 page, OPTIONS line, save RAM CLEARED for the first game), log
view (`-28.png`: the PIC's post-file writes ending with 0021 = F8 and one UI loop, times in
ms), off; DOWN+SELECT: the PIC model wakes, redraws its browser, the core follows it to the
menu view (from frame 34) and the game gets no buttons; DOWN, Y: the second file (the same ROM
under another name) is sent, loaded, verified, the save RAM line says KEPT, the SA-1 tests pass
again after the second boot (frame 48). ARAM port: 1.84 M reads, 706 writes, 0 late, 0 dropped,
0 command clashes; SDRAM 0 late reads, 0 model errors. The pad poller ran with the stock
timing throughout (the testbench's 4021 model and the PIC's line decoder both on its
LATCH/CLOCK).

`make sim-snes-load-kdl3` / `sim-snes-load-smrpg` (new; 45 ns link strobes, the v2 PIC model
without presses, 300 frames, ~40 min each): both 4 MB files load, verify (CRCs EC8A48F6 /
1B8A0625 = info), LoROM + SA-1, ROM_TYPE 60, ROM mask 3FFFFF, **RAM mask 7FFF** (32 KB, now in
the 64 KB block RAM), boot at T 933 ms and run ~4 s: Kirby's Dream Land 3 reaches the Nintendo
logo on white (`build/sim/snes_load_kdl3-299.png`), Super Mario RPG the Nintendo logo and then
the Square logo with the copyright lines (`snes_load_smrpg-195.png`, `-299.png`); PASS (load,
mapper, SDRAM 0 late / 0 model errors, ARAM 9.1 M reads, 0.53 M / 0.16 M writes, 0 late, 0
dropped, 0 clashes). Not compared with a 16-bit reference run (sim-snes-sdram has no 32 KB
BW-RAM build). These two ran before the last two timing-only changes (the log's compare and the
ARAM forward counter registered one cycle later); `sim-snes-load` and `sim-sdram-rom8` were
rerun after them. The write queue's read forwarding never triggered in any run (fwd 0: writes
are always done before the next substep's read); it is untested beyond that.

**v1:**

**Controller** (`make sim-sdram-rom8`, iverilog, `sim/tb_sdram_rom8.sv` + the timed model of
`quartus/snes_sdram/sim/sdram_model.v` with 512-column pages, clk = 5 × clk_sys): 2112 bytes
written (a block top-down, page ends incl. column 511, all banks, the last byte of the 8 MB),
backdoor check, 64 aux reads, then an SA-1 stand-in (one bus cycle per 2 clk_sys, data latched
10 clk after the address): 6000 cycles with new byte addresses, the other byte of the same
word, byte reads; VBP-style words held a second cycle and both lanes checked; 600 cycles with a
new address in every one (no hidden slot: forced refreshes); 2000 more. Rise 4 passes with
board delays D_CLK 1, 3.5 and 6 ns (+ D_IN 1 ns): 0 errors in phases A, 0 model errors, refresh
≤ 14.1 µs, forced refreshes only in the no-slot stretch (3, each making a read late there);
fall 3.5 and rise 5 fail as they must. Sweep: passes for D_CLK 1–7 ns (testbench D 2–8 ns,
capture clock without offset).

**Whole core** (`make sim-snes-load`, Verilator; `sim/tb.sv`, `sim/tb_snes_load.cpp`, the GHDL
netlists of `sim-snes` with SA1Map rebuilt from the VBP-patched SA1.vhd, `sdram_cyc.v` with
512-column pages and its read window at half cycle 8): a PIC32 stand-in holds /RD low for 250
µs, writes set-up registers and a 0x200-byte block at 0x0000_0000, polls `0x2004_0000` until 02
02, writes the reconfiguration block, a glyph block and the browser screen (layout and footer
bytes as captured on the console), then runs the UI loop every 8 ms; a 4021 pad model; the
"user" presses DOWN, then Y (RUN): the PIC redraws the screen with the cursor on the file and
sends `sa1test.spc` in 0x3000-byte runs at 1.7 MB/s; after the boot L+R+SELECT twice
(diagnostics on/off) and, 180 ms after the boot, the PIC sends the file again by itself.
Shortened waits: pad poll from 2 ms, 30 ms on the verified page, 20 ms combos. Result (28
frames): **PASS**: 02 02 at the first poll; browser with the cursor on GO BACK, then on the file
(`build/sim/snes_load-00.png`, `-02.png`); diagnostics while loading and verified (`-07.png`,
`-08.png`: file CRC AD3E85A3, ROM 8C5F7E54 = info = read-back, LoROM + SA-1, ROM_TYPE 60, masks
7FFF/7FF); the game from frame 9: **all 7 SA-1 tests pass from SDRAM through the 8-bit path**,
summary band green (`-11.png`), 750-line frames, no line-buffer conflicts; diagnostics over the
running game (`-16.png`); the PIC's UI loop goes on after the boot with pad reads 0 while
L+R+SELECT is held; the second transfer is ignored (98816 bytes counted) and the game goes on;
SDRAM: 0 late reads, 0 forced/stalled refreshes, 0 model errors.

**Gradius III** (`make sim-snes-load-gradius`, no gaps between runs, 70 frames): header "gradius
3" map 20, scores Lo 10 Hi 0 → LoROM, ROM_TYPE 00, ROM mask 7FFFF, no RAM; 590336 bytes,
read-back CRC CD973979 = info; the game runs from SDRAM through the Lo/HiROM mapper: 0 late reads,
0 model errors. Its picture (a static white grid from ~19 frames after the reset,
`build/sim/snes_load_g3-69.png`) is **pixel-identical** to the same ROM run in the 16-bit
`sim-snes-sdram` (ROM preloaded, `TB_TYPE=00`): whether that grid is what Gradius III shows
then or a wait (e.g. on the sound CPU) is the same in both.

**Kirby Super Star** (4 MB SA-1, `make sim-snes-load-kirby`, 120 frames): 4260352 bytes in 1.38 s,
read-back CRC 89D0F7DC = info (the whole 4 MB through banks 0-1), LoROM + SA-1, ROM mask
3FFFFF, RAM mask 1FFF (`build/sim/snes_load_kss-108.png`); boots, 0 late reads, 0 model errors.

The startup frame of 734 lines (frame 1) is snes_video aligning to the SNES PPU, which runs
while the core is held in reset; it happens once, ~40 ms after configuration (before the PIC
sets up the HDMI transmitter), and not again at the boot.

## Build results

**v6 (23 Oct 2026):** seed 2 (`.cor` sha1 bfac4b68ce3b…), **timing met** (worst setup +0.509 ns, hold
+0.103 ns; seed 3: -0.018), 87 user I/Os, pin check passes.

**v5 (23 Oct 2026):** seed 2 (`.cor` sha1 12ccded2c274…): 14,733 / 18,480 ALMs (80 %), 299 / 308
RAM blocks, **timing met** (worst setup +0.457 ns, hold +0.090 ns), 87 user I/Os. Seed 1 missed
by 0.45 ns (seed 3: +0.212). The 107 MHz SDRAM controller's slack swings by about ±0.5 ns from
seed to seed with nearly the same design (v4 seed 1 +0.54, v5 seed 1 -0.45), so a new build
that misses should first get another seed or two.

**v4 (23 Oct 2026):** Quartus 25.1 Lite, seed 1: `.cor` sha1 1055bef799a5…. 14,694 / 18,480 ALMs
(80 %), 14,646 registers, 299 / 308 RAM blocks, 19 DSP blocks. **Timing met at all four corners**
(worst setup +0.542 ns, hold +0.122 ns). Pin check: 87 user I/Os (v2's 86 + D6, input).

**v3 (23 Oct 2026, the console run):** with the 29-pin scanner the 107 MHz SDRAM controller's
paths missed by 0.02-0.40 ns at the slow corners in every build tried (seeds 1-4, "aggressive
performance" mode; a LogicLock region for the controller was silently ignored by Lite); the
seed-2 build (setup -0.070 ns at slow 85 C, -0.019 at slow 0 C) ran fine on the console. 115
user I/Os.

**v2 (23 Oct 2026):** `make out/q-snes_load.cor` (Quartus 25.1 Lite, ~25 min): `.cor` 2,632,660
bytes, sha1 017a65cb0041…. 14,666 / 18,480 ALMs (79 %), 14,493 registers, **299 / 308 RAM
blocks** (ARAM -64, BW-RAM +56, log +7), 19 DSP blocks. **Timing met at all four corners**
(worst setup +0.082 ns, hold +0.097 ns). Pin check: 86 user I/Os, all as assigned (the same pins
as v1; no new pin is driven). Two rounds were needed: first ar_q -> S-DSP/SPC700 combinational
outputs -> the ARAM port's sampling registers failed by 3.1 ns (one clk_mem cycle as analysed;
fixed by sampling at k = 2 with ar_q changing only at k = 3, and a 4-cycle multicycle in the
SDC), then the log's 8-entry compare and the ARAM forward counter by 0.5 ns (registered).

**v1:**

`make out/q-snes_load.cor` (Quartus 25.1 Lite, `quartus/snes_load/build.log`, ~20 min): `.cor`
2,632,660 bytes, sha1 da2832ef….

- Resources: 12,667 / 18,480 ALMs (69 %), 13,535 registers, 300 / 308 RAM blocks (the boot
  ROM of snes_sdram is gone; BW-RAM 8 KB, browser screen 4 KB, font, diagnostics template), 18
  DSP blocks, 2 PLLs (SNES/SDRAM at VCO 750.47 MHz, audio).
- **Timing met at all four corners** (worst setup +0.236 ns, hold +0.122 ns). Slow 85 °C slacks
  by path class: read data → capture register +1.17 ns (I/O-cell register); commands/address/
  write data → chips (tIS) +1.75; capture register → SA-1/SNES CPU +1.44; core address →
  controller decision +4.16; the worst overall is the link log ring (+0.24).
- Pins: `tools/checkpins.py` passes, 86 user I/Os, all as assigned.
- Build history worth keeping: at 4 × clk_sys (85.77 MHz) the same design missed setup by
  1.6–3.8 ns on the SA-1 address → ACT decision however it was arranged (fast compare before
  main.v's mapper mux, registered refresh flags, address pins loaded every idle cycle); 5 ×
  solved it with room to spare. A Quartus trap on the way: two PLL outputs with the same
  frequency and phase are merged, and the SDC's `*[2].*` clock name then matches nothing (all
  SDRAM I/O constraints silently dropped; warning 332174) — hence the 1-step SDRAM clock lead.

## Console test (v6): one run

As v4's below. If the browser doesn't come up on DOWN+SELECT, open the status page (L+R+SELECT)
and leave it up for a few seconds: its two newest log rows show what the PIC read last.

## Console test (v5): one run (done 23 Oct: DOWN+SELECT didn't wake the PIC)

As v4's below (v4 ran on 23 Oct: SELECT alone stayed with the game, but DOWN+SELECT didn't open
the browser either; notes/hardware-tests.md).

## Console test (v4): one run

Goal: SELECT alone stays with the game; DOWN+SELECT still opens the browser; player 2 still
works. A pad in each port; the capture dongle recording if it is plugged in.

1. Power on, Tools -> "Play SPC Files", load **2 Kirby Super Star**, start a game.
2. Press **SELECT alone** a few times, hold it 2 s once: the game stays on screen (the PIC
   may wake behind it). L+R+SELECT (status page): the OPTIONS row may say `view GAME+PIC`;
   L+R+SELECT twice more to close.
3. Play on a little with both pads (player 2 as in v3; SELECT on either pad goes to the game).
4. **DOWN+SELECT** (hold 1 s, let go): the PIC's browser appears. Pick **4 Super Mario RPG**
   (DOWN, Y): it loads and runs. DOWN+SELECT again, then SELECT in the browser (back to game):
   Mario RPG continues.
5. Power off (or leave v4 installed).

## Console test (v3): one run (done 23 Oct, notes/hardware-tests.md)

## Console test (v2): one run

Goal: find the way back to the player's menu without a power cycle, check 64 KB save RAM (Super
Mario RPG, Kirby's Dream Land 3) and the kept saves, and record everything the PIC does. The
capture dongle records all of it; read the pages from the recording afterwards.

**Prepare (homebox):** `make out/q-snes_load.cor load-spcs`; mount the card; `tools/sdcore
setup` (q-snes_load is **14**), `tools/sdcore use 14`, `tools/sdcore roms` ("0 SA1 TEST",
"1 Gradius III", "2 Kirby Super Star", "3 Kirby's Dream Land 3", "4 Super Mario RPG",
"5 SA1 TEST 20S"; 4.2 MB each for 2-4); unmount. Start `tools/capview.py` recording.

Hold every combination until something happens or for the time given; "page" = L+R+SELECT
(0.5 s), which cycles status page -> log view -> off.

1. Power on, Tools -> "Play SPC Files". The browser with the six files below GO BACK.
2. DOWN, Y on **0 SA1 TEST**: status page ("VERIFIED - STARTING", OPTIONS line `UP poll STOCK
   DOWN pad ALWAYS LEFT follow ON`), 4 s later the SA-1 test (7 green bars). Press a few game
   buttons (backdrop turns blue: the pad reaches the game with the stock poll timing).
3. Wait 5 s. **page** (status page): note `last T`, `UI`, `scr`, `0021=F8 T ..` (expected:
   nothing after the F8, as in v1). **page** again (log view): let it page through by itself
   (2.5 s per page, "pg NN/MM" top right) until it wraps; **page** again (off).
4. **The main test: DOWN + SELECT**, hold 2 s, then let go and wait 3 s. Expected if the decode
   is right: the PIC's own screen appears (the browser or the JB menu; the OPTIONS line would
   say `view MENU(PIC)`). Then:
   - browser: DOWN to **1 Gradius III**, Y -> it loads and runs (the way back works);
   - a menu: note its items (photo), pick the file browser / "back to game" (Y = confirm,
     B = back, SELECT = back to game) and continue as above.
   If nothing appears: hold DOWN + SELECT again for 5 s; then UP + SELECT 2 s and SELECT +
   START 2 s (other combinations other Analogue consoles use).
5. Only if step 4 showed nothing: **page** to the status page, **L+R+UP** (0.5 s: `poll FAST
   (v1)`), **page** twice (off), DOWN + SELECT 2 s again; then the status page again, **L+R+UP**
   back to STOCK.
6. **L+R+SELECT+START** (1 s): our menu view (the PIC's last screen, the game gets no buttons,
   the PIC gets them): press B, START, Y, DOWN (one each, 1 s apart) and watch whether the
   screen changes; **L+R+SELECT+START** again to close it.
7. **page** (status), **page** (log view): let it run through all pages once (this is the
   record of steps 4-6); **page** (off).
8. If the way back worked (step 4): from the browser load **3 Kirby's Dream Land 3** (~3 s
   transfer, status page: RAM mask 7FFF, "save RAM ... CLEARED"); play to the file select, start
   a game, enter the first level (the game saves). DOWN + SELECT, load **3 Kirby's Dream Land 3**
   again: the page must say "KEPT", and the file select must show the saved file. Then
   **4 Super Mario RPG**: title, new game, play a minute (Mario's house). Then **5 SA1 TEST 20S**:
   don't touch anything for 40 s (the song is 20 s long: does the player stop it, go back to its
   browser (our view follows it), or send the next file ("lost ... ign" counts up)?), then
   **page** twice for the log view.
9. Press the console's **RESET** button once (short) and note what happens (the PIC handles
   that button; if it returns to the Analogue menu, Tools -> "Play SPC Files" starts our core
   again: that is a way back too, without a power cycle).
10. If the way back didn't work: power off and on, Tools -> "Play SPC Files", load **3 Kirby's
    Dream Land 3** (play to the file select and into a level), power cycle, **4 Super Mario
    RPG** (title, new game), power cycle, **5 SA1 TEST 20S** (wait 40 s, then the log view).
11. Power off; `tools/sdcore use 00` restores the stock core.

What to note (or read from the recording): for each step whether the PIC woke (its screen, the
view on the OPTIONS line, the status page's `last T` / `UI` / `scr` times, new log entries);
each game's status page (CRC OK, ROM_TYPE 60, RAM mask 7FFF, save RAM line) and whether it
plays with sound; the ARAM line (`late`, `drop`, `clash` should stay 0); ROM `late` 0.

Interpretation: a PIC screen after DOWN + SELECT confirms that the PIC watches the controller
lines and the gap is closed. Nothing in steps 4-6 and no log entries means the PIC waits on
something the core doesn't do (one of the stock outputs listed in notes/pic-link.md, "After a
file"); step 8/10's 20 s file and step 9 then show whether the player ever comes back by itself.

## Console test (first run, v1)

Needs: the card on homebox (`notes/hardware-tests.md`), a pad in port 1, the projector or the
HDMI capture dongle with `tools/capview.py` (live view http://homebox.jaguar-munsell.ts.net:8765/,
recordings in `~/scratch/cap`).

1. `make out/q-snes_load.cor load-spcs`; mount the card; `tools/sdcore setup` (copies every
   test core; q-snes_load is **14**), `tools/sdcore use 14`, `tools/sdcore roms` (copies
   "0 SA1 TEST.spc", "1 Gradius III.spc", "2 Kirby Super Star.spc" into `SPC/`; other files in
   `SPC/` may stay, e.g. the chord). Unmount.
2. Power on, start `capview.py` recording, Tools → "Play SPC Files".
3. Expected: the player's file browser, our font, cursor bar on GO BACK; the three files right
   below it (the browser sorts case-sensitively: digits first), then the others. If instead the
   screen stays black: hold L+R+SELECT 0.5 s for the diagnostics page (status reads should
   count up, UI loops count).
4. **D-pad DOWN once** (cursor on "0 SA1 TEST.SPC"), press **Y** (RUN; if Y does nothing, try B
   and A and note which works). The diagnostics page appears, bytes count up to 18200 (0.06 s),
   then "VERIFIED - STARTING" with "= INFO CRC: OK"; 4 s later: green bar + 7 green bars,
   white and cyan squares moving (as `q-snes`).
5. Hold L+R+SELECT: the page over the game: note the PIC LINK LOG rows (what the PIC did after
   the file), "ROM reads", "late". Again to hide it.
6. L+R+START: the browser again; DOWN to "1 GRADIUS III.SPC", Y. The page: ROM size 80000, CRC
   CD973979, LoROM, ROM_TYPE 00; then the game (Konami logo, title). Then the same with
   "2 KIRBY SUPER STAR.SPC" (4 MB: ~2.5 s transfer, ~0.4 s read-back; LoROM + SA-1, RAM mask
   1FFF).
7. Power off; `tools/sdcore use 00` restores the stock core.

What to note: whether the browser looks right (and which button is RUN); the page's FILE/INFO/
SDRAM lines for each file (a mismatch: photograph the page, then try L+R+A); "order" and "lost"
(both should be 0); the log rows after a transfer; what each game does.

If the verify fails for every file but the bytes and transfer CRC are right: SDRAM writes or
reads are wrong (capture point, `sdram_cfg.tcl`; notes/snes-sdram.md, "Parameters to set from
hwtest"). If the transfer CRC is wrong already: the link (bit order, missed strobes).
