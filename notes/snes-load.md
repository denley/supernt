# SNES core that loads its ROM from the SD card (quartus/snes_load, Oct 2026)

`make out/q-snes_load.cor` builds the SNES + SA-1 core (srg320's MiSTer core as in
`notes/snes-quartus.md`) with the cartridge ROM in SDRAM chip B, loaded from the SD card
through the SPC player: the core stands in for `SYSTEM/CORES/spc.cor`, the PIC32 runs the
player's file browser on it, and a "song" made by `tools/rom2spc.py` carries the ROM. After the
transfer the core checks the ROM in SDRAM against the file's CRC-32, shows the result for 4 s
and starts the game. Everything the PIC does stays visible on a diagnostics page.

**Status:** simulated end to end (Verilator: PIC32 stand-in, pad, SDRAM cycle model; the SA-1
test ROM passes from SDRAM through the 8-bit path; Gradius III and Kirby Super Star detected,
loaded, verified and booted); builds with timing met at all corners; pin check passes. **Not yet run on
the console.** Test procedure at the end.

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
6. The PIC keeps running its UI loop; the core keeps answering (pad reads return "nothing
   pressed" while the game has the pad) and logs everything else the PIC does.

Keys (hold 0.5 s): **L+R+SELECT** diagnostics page on/off (any time); **L+R+START** file
browser on/off while a game runs: the PIC gets the pad, the game doesn't, and RUN on a file
loads it (the game stops); **L+R+A** boot after a failed verify. While a game runs, a file the
PIC sends without the browser being open is ignored (counted on the page as "lost ... ign"),
so an auto-advancing player can't reset the game.

## Files

| File | What |
|---|---|
| `tools/rom2spc.py` | ROM → `.spc` wrapper (format below); prints the CRCs the page shows |
| `quartus/snes_load/snes_load_top.sv` | top: clocks, link, loader, SDRAM, SNES, views, video mux, audio |
| `quartus/common/link_ui.sv` | PIC32 link slave: status 02, pad registers, browser screen RAM, file stream, log |
| `quartus/common/rom_loader.sv` | file → SDRAM, CRCs, info block, header scoring, mapper, read-back, boot |
| `quartus/common/sdram_rom8.sv` | 8-bit SDRAM controller for chip B (from `sdram_rom.sv`) |
| `quartus/common/pad_poll.sv` | controller port 1 poller (PAD_CFG 0 wiring) |
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
`sim-snes-load`, `sim-snes-load-gradius`, `sim-snes-load-kirby`.

## The file (`tools/rom2spc.py ROM OUT.spc [--title T]`)

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

BW-RAM/SRAM: **8 KB of block RAM** (`BSRAM_AW` 13; 8 of the 308 RAM blocks are left). Games with more
(Super Mario RPG: 32 KB BW-RAM) will misbehave; Kirby Super Star (8 KB) fits. No saving.

## Link (`link_ui.sv`)

Port as `link_logger.sv`/`link_loader.sv` (2-FF synchronisers on clk_mem, 107.2 MHz; reads
only after the port is armed). Status `0x2xx4` = 02; `0x2000`/`0x2001` = pad bits (or 0 while
the game has the pad), `0x2008` = 01 (03 if no standard pad answers); everything else 00.
Screen writes (`0x1018_0000`-`0FFF`) go to a 4 KB RAM the overlay reads. The **log**: a run =
consecutive writes or reads at consecutive addresses; runs go into a 16-entry ring (address,
count, first byte, kind 0 write / 1 read, repeats, ms); a run equal to the newest entry only
counts a repeat. The UI loop (`0x1000_D120` writes, pad reads) and the file are only counted.
The page shows the newest 6 entries: after the transfer they are whatever the PIC does then
(not known yet: hwtest v6b's log ended without anything notable).

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
- **Diagnostics**: 80 × 22 cells of 16 × 32 (as hwtest's pages), `diag.txt`:

```
 SUPER NT SNES LOADER  T <ms>   state <n> <name>
 LINK  2004 answer 02  status reads <n>  UI loops <n>
       pad reads <n>  writes <n>  addr <link address>  screen <bytes>
 FILE  bytes <n>  CRC-32 <file>  end <highest offset+1>  T <start>-<end>
       ROM bytes <n>  CRC-32 <ROM>  order <n>  lost <FIFO> <bytes>8MB:16 ignored:16>
 INFO  SNTROM01 ok  ROM size <n>  CRC-32 <crc>  tool type <guess>
       name <32 chars>
 HEADER <title>  map <> type <> ROM <> RAM <>
       checksum <sum>/<complement>  scores Lo <> Hi <> ExHi <>  loads <n>
       <LoROM/HiROM/ExHiROM [+ SA-1] [(no chip)]>  ROM_TYPE <>  ROM mask <>  RAM mask <>
 SDRAM read back: CRC-32 <crc>  = INFO CRC: OK | = TRANSFER CRC: OK | MISMATCH
       ROM reads <n>  REF forced <n> stalled <n>  late <n>  gap <max REF interval, cycles>
 SNES  boot T <ms>  frames <n>  pad <raw 32 bits> std pad|no pad polls <n>
 KEYS ...
 PIC LINK LOG newest first ...  runs <n>  last UI <ms>
   #  K  ADDRESS   BYTES   D0  REPEATS  T ms        (6 rows)
```

All numbers hex; T in ms since configuration. Values are sampled once per frame.

## Pins

86 user I/Os: the HDMI video/audio pins and controller port 1 as `quartus/snes`, the PIC32 link
as `quartus/hwtest` (data driven only while /RD is low), SDRAM command/address/BA/DQ/clock as
`quartus/hwtest`, AB10 constant low (spc.cor's level). Not used (weak pull-up inputs): the eight
DQM candidates / open-drain group, hwtest's 43 stock-constant pins, everything else.
`tools/checkpins.py` passes.

## Simulation

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

## Build results (23 Oct 2026)

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

## Console test (first run)

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
