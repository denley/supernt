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
  In v2/v3, SELECT alone did that too (the PIC reacts to SELECT in our pad registers); v6
  fixed it (below).
- After the transfer the core checks the ROM in SDRAM against the file's CRC-32 and shows
  "INFO CRC: OK" before booting.

**Player 2 works** (v3, 23 Oct: port 2's data line is D6, found by a pin scan; v4 reads it
directly). While a game runs the PIC polls our pad registers over the link and wakes on SELECT
(v4 run) but only on SELECT alone (v5 run: DOWN+SELECT held didn't wake it). **v6 works on the
console** (23 Oct): it answers 0 during games and sends the PIC a short SELECT-alone press when
DOWN+SELECT is pressed, so DOWN+SELECT opens the browser and SELECT alone is the game's.

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
- SDRAM (`notes/sdram.md`, "Which chip is which" and the memtest results, 23 Oct): three
  chips, 48 MB.
  - **U4** (AS4C8M16SA x16, bottom-bank bus, AB11 clock): the bus our SNES core uses. Byte B
    (3B, AB10 = its DQM, low) works, 8 MB; byte A (2A) has never answered (enable not found).
  - **G1** (one IS42S81600F of U5/U16, top-bank bus, H8 clock): **works**, 16 MB, every byte
    (memtest v3); needs **J8 low** (a top-bank constant no earlier core drove); data one clock
    earlier than U4.
  - **G2** (the other one): its own command pins, open-drain data pins and address pins;
    enabled by **B13 low**; data path works; address pins found (13 + D17), bank/odd-one-out
    still to tell apart.

## Next steps (agreed direction)

1. **Super FX 1/2: done** (24 Oct). snes_load v7.2 (`notes/snes-load.md`, "v7 in short" and
   "v7.2") runs the GSU next to the SA-1 in one core, timing met; on the console Yoshi's Island,
   Star Fox and the SA-1 games all work (`notes/hardware-tests.md`, "snes_load v7.2 results";
   `TESTCORES/19-q-snes_load-v72.cor` is the card's spc.cor).
2. Optional: DSP-1 in our core (small; vendor `DSPn`), larger ROMs, more games.
3. Not possible: saves to SD from the SPC player context. Decoded, and the last way in (an SPC
   file that looks like a ROM with save RAM, the "save probe") failed on the console 24 Oct
   (`notes/hardware-tests.md`, "Save probe ... results").

## Console test workflow (keep runs few: each costs Denley a card swap and menu navigation)

1. Card into homebox: `sudo mount -o uid=1000,gid=1000,utf8 /dev/sdb1 /mnt/sd`; install with
   `tools/sdcore use NN` / `tools/sdcore roms`; `sync; sudo umount /mnt/sd`.
2. Start `tools/capview.py` (HDMI capture dongle MS2109 on homebox: records
   `~/scratch/cap/rec-*.mkv` with sound, live view http://homebox.jaguar-munsell.ts.net:8765/
   for Denley's phone; it fetches frame by frame and survives app switches without a reload).
   If the live view says "no signal" while the console shows a picture, check `pgrep -a
   ffmpeg`: a phone disconnecting can kill capview's ffmpeg without a restart (23 Oct);
   restart capview. Stop it with `pkill -INT -f "^python3 tools/capview.py"` (a plainer
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
- Long Quartus builds and sims run in the background; the repo is backed up to a private
  GitHub repo (`denley/supernt`, since 26 Oct; push `main` and branches worth keeping).
  Work done on a branch/worktree can go straight into `main` (fast-forward) without asking
  (Denley, 23 Oct).
- Throwaway data: `~/scratch/cap` (recordings; `capview.py` deletes them after 7 days and stops
  recording below 80 GB free, so copy one elsewhere if a note must keep it), `~/scratch/hwtest-videos`, decode
  scripts in `~/scratch/*`; all safe to delete.
