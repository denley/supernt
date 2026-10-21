# Hardware tests

The console loads only `SYSTEM/CORES/spc.cor` (when an `.spc` file is played), so each test
swaps that file. `tools/sdcore` manages it: `setup` copies every test core into
`TESTCORES/NN-name.cor` on the card, `use NN` installs one, `list` shows which is installed.

Mount the card on homebox with `sudo mount -o uid=1000,gid=1000,utf8 /dev/sdX1 /mnt/sd`
(it shows up as a ~30 GB removable vfat disk in `lsblk`), and `sudo umount /mnt/sd` before
pulling it.

## Card state (21 Oct 2026)

- The card came with an older jailbreak release: everything matched JB7.2 except
  `spc.cor` (sha1 b03566d6…, Feb 2021). It has the same pinout as JB7.2's core.
  It is kept as `TESTCORES/99-stock-old-card.cor`.
- Whole-card backup from before any change: `~/scratch/sd-backup-2026-10-21`.
- Added `snt_firmware_verJB7.2.bin` in the root. There is no prompt: the console flashes it
  silently on power-on (a few minutes, LED flickers red, HDMI blacks out), then boots the menu.
  Denley's first boot with the card was slow, which fits. JB7.2 (Jul 2023) is still the latest
  release (github.com/analoguejb/Analogue-Super-Nt-JB). Check: Tools has "Reload Save RAM"
  (new in 7.2). The `.bin` was deleted from the card after the update.
- Installed `01-spc-colortest` as `spc.cor`, then `05-vtest`, then `07-buslog` rebuilt with
  the fixed sync order, then `09-q-snes` rebuilt with the confirmed sync/colour map (21 Oct evening).
- The card had no `.spc` files. `tools/mkspc.py` makes `SPC/Super Nt test chord.spc`: a steady
  A major chord (440/554/659 Hz square waves; checked with libgme). Copied to
  the card 21 Oct; `tools/sdcore setup` copies it too.

## hwtest (12-q-hwtest) loading test files

`SPC/` on the card holds three files for the link logger (CRC-32 = zlib):

| file | size | CRC-32 whole | parts |
|---|---|---|---|
| `Super Nt test chord.spc` | 0x10200 | 68D8FB8F | header 0–FF ADACE265, RAM 100–100FF 0C96CDBE, DSP 10100–1017F 18EB6C01 |
| `Super Nt big 1MB.spc` (chord + pattern, `tools/mkbigspc.py`) | 0x100000 | F7596A77 | same first 0x10200 bytes; after 0x10200: BEC73C8F; extra RAM 101C0–101FF 758D6336 |
| `Gradius III ROM test.spc` (a ROM renamed) | 0x80200 | C5BCC3FF | without the 512-byte copier header CD973979; its first 64 KB 6D739ED0 |

## Next session (prepared 21–22 Oct overnight)

1. `12-q-hwtest` (installed as spc.cor): one core for audio framing, controller port 1, the x8
   SDRAM pair and the PIC32 link logger. For each of the three test files (chord, big 1MB,
   Gradius ROM), power-cycle, play it, and film the screen for a full minute **with sound**
   while pressing a few buttons on a pad in port 1 (B, then Start, then A). Read off:
   - AUDIO: which framing's pitch sounds clean (from the video's sound track: 440 Hz = I2S,
     880 Hz = left-justified) -> `AUD_FRAMING` in quartus/snes/snes_top.sv.
   - PADS: which cfg line reads FFFF0000 idle and changes with buttons -> `PAD_CFG`.
   - SDRAM: which capture point stays at 0 errors, and whether DQM-low/off matters.
   - LINK: big runs (address, byte count, CRC-32) vs the CRC table above: does the file
     arrive, where, and how much of it (whole file, or the .spc structure only).
2. `09-q-snes` rebuilt with audio (test ROM plays the chord after the SA-1 tests) and
   controller port 1 (backdrop turns blue while a button is held), using the settings from 1.
3. `13-q-snes_sdram` (on the card since 22 Oct, not installed): the same test ROM, copied into
   the x8 SDRAM pair at start-up and run from there (notes/snes-sdram.md). Same picture as
   q-snes if the SDRAM read timing is right; built for capture at fall 3.5, so set its
   parameters from hwtest's SDRAM page first if that point shows errors.

## Order

| # | core | look for |
|---|------|----------|
| 01 | spc-colortest | SPC player with scrambled colours, stable picture: modified cores load |
| 02–04 | spc-invert-ch1/2/3 | tint per core (cyan = red channel, magenta = green, yellow = blue) |
| 05/06 | vtest / q-vtest | 720p pattern in one of 6 sync orders, 8 s each; photo incl. corner boxes |
| 07/08 | buslog / q-buslog | hex log of the PIC32 link; film ~3 min |
| 09 | q-snes | green bar + 7 green test lines, white and cyan moving squares |
| 10/11 | plltest / blinky | only if 05/06 show nothing |
| 12 | q-hwtest | audio framing, pads, SDRAM capture, link log (see Next session) |
| 13 | q-snes_sdram | as 09, but the ROM runs from SDRAM |
| 00 | stock JB7.2 | restore |

## Results

- 21 Oct 2026, JB7.2, `01-spc-colortest`: **loads and runs.** The SPC player UI showed and the
  test chord played. So the loader accepts a modified `spc.cor` (no hash or signature check, at
  least for a patch this small), and mkcor's frame handling is good on hardware. (A first "black
  screen" report was the file not being started properly.) Denley's description: "a wave pattern that said
  'super nt test' with various colours" (the player's visualiser and the ID666 title). Whether
  the colours were scrambled can't be told from that; vtest (next) settles whether our bits run.
- 21 Oct 2026, `05-vtest` (open-source flow, our own design): **picture.** About once a minute
  (one of the 6 sync orders), 4 boxes = order 3: P16 = VSYNC, M16 = DE, M18 = HSYNC. Stripes:
  green, red, blue groups, each with the last stripe brightest, so each group's bits are
  reversed relative to the proposal (mapping now in `notes/spc-core.md`). White block white.
  Photo: `photos/vtest-2026-10-21.jpg`. So: our bitstreams configure the FPGA, the 74.25 MHz W16
  clock is right, and the AD9889B is left configured for 720p RGB with separate syncs.
- 21 Oct 2026, `07-buslog` (fixed sync order): **works**; 3 photos, one per page, log full
  (1024 events). Transcription in `notes/buslog-2026-10-21/`. Repeating 5-state strobe cycle,
  one state carrying varying data; long stretches look like polling for a reply.
- 21 Oct 2026, `09-q-snes` (first Quartus core on the console), first build: nothing at all.
  Rebuilt to free-run for 20 s before frame-locking: **the SNES + SA-1 core runs**: green summary
  bar and 7 green test bars (all SA-1 tests pass), white and cyan squares moving, colours right;
  rolling slowly while free-running (60.000 Hz output vs 60.0988 Hz SNES); at 20 s, when the
  748/749-line frame lock started, the projector dropped the signal (blue "HDMI" no-signal
  screen). So Quartus-built cores load, the PLL works, and this projector rejects varying
  vertical totals. Fix: SNES clock 21.44196 MHz (0.16% slow) so SNES frames match 720p60 exactly.
- 21 Oct 2026, `09-q-snes` with the 21.44196 MHz SNES clock (60.000 Hz, standard 720p60
  totals): **stable picture**, no rolling or dropouts. All 7 SA-1 tests green, both squares
  moving. Frames: `photos/q-snes-60hz-2026-10-21.jpg`. Milestone 1 done on hardware.
