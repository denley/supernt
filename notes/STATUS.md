# Where the project stands (handoff, 23 Oct 2026)

Start here when picking the project up again. Details live in the notes linked below;
`notes/hardware-tests.md` has every console run in order.

## What works on the console

**Our own SNES + SA-1 core runs games from the SD card** on Denley's Super Nt (JB7.2 firmware):
`quartus/snes_load` (v2, commit dd820dc, `out/q-snes_load.cor`, card slot `14-q-snes_load`,
installed as `SYSTEM/CORES/spc.cor`). Played on 23 Oct: SA-1 test ROM, Gradius III, Kirby Super
Star, Super Mario RPG (new game into Bowser's Keep); Kirby's Dream Land 3 is on the card and
boots in simulation but wasn't in the recorded part of the run. Photos:
`photos/snes-load-2026-10-23.jpg`, `photos/snes-load-v2-2026-10-23.jpg`.

How it's used:
- Console menu Tools → "Play SPC Files" loads our core instead of the SPC player; the PIC32
  draws its file browser in our core's memory and our core shows it. Pick a game with the
  d-pad and **Y** (= RUN; B = up a folder, START = settings menu, SELECT = cancel).
- Games are ROMs wrapped as `.spc` "songs" by `tools/rom2spc.py` (the PIC only sends files it
  accepts as SPCs). `tools/sdcore roms` copies the wrapped set into `SPC/` (names start
  with digits so they sort right under GO BACK): 0 SA1 TEST, 1 Gradius III, 2 Kirby Super Star,
  3 Kirby's Dream Land 3, 4 Super Mario RPG, 5 SA1 TEST 20S. To add a game: a `Makefile`
  `load-spcs` entry (ROMs come from `SNES_ROMS` = `~/scratch/sd-backup-2026-10-21/SNES`, a copy of
  the card's `SNES/` folder) and a line in `tools/sdcore roms`.
- **DOWN+SELECT** (the JB menu combo; the PIC watches the pad lines itself) brings the browser
  back to load another game without a power cycle. **L+R+SELECT** shows our status/log page.
  In v2/v3, SELECT alone did that too (the PIC reacts to SELECT in our pad registers); v5
  fixes it (below).
- After the transfer the core checks the ROM in SDRAM against the file's CRC-32 and shows
  "INFO CRC: OK" before booting.

**Player 2 works** (v3, 23 Oct: port 2's data line is D6, found by a pin scan; v4 reads it
directly). While a game runs the PIC polls our pad registers over the link and wakes on SELECT
(v4 run); **v5** (built 23 Oct, not yet on the console; test: `notes/snes-load.md`, "Console test
(v5)") passes the pad to it during games only while DOWN+SELECT is held, so SELECT alone is the
game's.

Limits now: saves are kept only while powered and only for the last game loaded (the SPC
player context has no way to write files to SD); 64 KB save RAM, ROMs up to 6 MB; no Super FX,
DSP, CX4, SDD-1, SPC7110 (DSP-1..4, CX4, OBC1, ST010/11 already work with JB's own "Browse SD
Card" loader, BIOS files are on the card in `/BIOS`).

## The hardware as we now know it

- FPGA 5CEBA4F23C8; `.cor` = bit-reversed `.rbf`, no signature check (`notes/spc-core.md`).
- Video: 720p60 RGB to the AD9889B (pins and sync order in `notes/spc-core.md`, colour map
  confirmed); SNES clock 21.44196 MHz so SNES frames lock to exactly 60 Hz
  (`notes/snes-quartus.md`).
- Audio: I2S into the AD9889B, confirmed (`notes/audio.md`).
- Controller port 1: T12 data, P14 latch, J13+K16 clock (`notes/controllers.md`, "Link
  registers" for the pad bytes the PIC reads). Port 2: data on D6 (same LATCH/CLOCK).
- PIC32 link (bank 4A, `notes/pic-link.md`): 8-bit slave port; status poll at `0x2004_0000`
  must read 02; PIC UI loop reads the pad at `0x2000/0x2001`; its screen is a 64×32 2-byte-cell
  text map at `0x1018_0000`; **a run file arrives verbatim at link address `0x0000_FF00` + file
  offset** (1 MB in ~0.6 s); after a file the PIC goes silent until DOWN+SELECT.
- SDRAM (`notes/sdram.md`): of the x8 pair only **chip B** responds (8-bit, 8 MB used,
  512-column pages, AB10 = its DQM, held low). **Chip A never drives** in any of 16 pin
  hypotheses: probably a missing enable signal, not a dead chip (the stock core uses both).
  The board's third chip (x16 AS4C8M16SA on the top bank, 148.5 MHz controller in the stock
  core) is not brought up yet.

## Next steps (agreed direction)

1. **Super FX 1/2** (Star Fox, Yoshi's Island, both on the card): the vendor core has the GSU;
   the work is memory. M10K is full (299/308: WRAM/VRAM live in block RAM), logic at 79 %, and
   GSU games need 32–64 KB RAM plus fast ROM/RAM access that one 8-bit chip may not give.
   Plan: a test core that brings up the **x16 SDRAM** (pin map partly decoded in
   `notes/sdram.md`, second controller) and retries **chip A's** enable from a deeper decode,
   in one console run; then move WRAM/GSU RAM there and add the GSU. Estimate: 3–5 console runs.
2. Optional: DSP-1 in our core (small; vendor `DSPn`), larger ROMs, more games.
3. Not possible (decoded): saves to SD from the SPC player context.

## Console test workflow (keep runs few: each costs Denley a card swap and menu navigation)

1. Card into homebox: `sudo mount -o uid=1000,gid=1000,utf8 /dev/sdb1 /mnt/sd`; install with
   `tools/sdcore use NN` / `tools/sdcore roms`; `sync; sudo umount /mnt/sd`.
2. Start `tools/capview.py` (HDMI capture dongle MS2109 on homebox: records
   `~/scratch/cap/rec-*.mkv` with sound, live view http://homebox.jaguar-munsell.ts.net:8765/
   for Denley's phone; it fetches frame by frame and survives app switches without a reload). Stop it with `pkill -INT -f "^python3 tools/capview.py"` (a plainer
   pattern kills your own shell).
3. Denley: card in the console, Tools → Play SPC Files, then whatever the test needs. Read
   results from the recording (`tools/frames.sh`, ImageMagick crops); design test cores so one
   hands-off run answers everything (on-screen diagnostics, virtual presses, screen capture).
4. Record the result in `notes/hardware-tests.md`.
`tools/sdcore use 00` restores the stock JB7.2 core.

## Rules this project follows

- Quartus licence (`notes/quartus.md`): never decode/decompile/diff bitstreams *we* built with
  Quartus; don't publish Quartus benchmark results. Decoding Analogue's stock `spc.cor`
  (`build/spc.bt`, `tools/netlist.py`) is how most of the above was found.
- Pin safety: only drive pins the stock core drives, with its settings; `tools/checkpins.py`
  runs in every Quartus build.
- Quartus ignores initial values written in ANSI port declarations: use internal registers.
- Long Quartus builds and sims run in the background; the repo has no remote (local commits).
- Throwaway data: `~/scratch/cap` (~17 GB of recordings), `~/scratch/hwtest-videos`, decode
  scripts in `~/scratch/*`; all safe to delete.
