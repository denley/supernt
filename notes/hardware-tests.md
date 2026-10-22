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

## Test files

`SPC/` on the card holds three files for the link logger (CRC-32 = zlib):

| file | size | CRC-32 whole | parts |
|---|---|---|---|
| `Super Nt test chord.spc` | 0x10200 | 68D8FB8F | header 0–FF ADACE265, RAM 100–100FF 0C96CDBE, DSP 10100–1017F 18EB6C01 |
| `Super Nt big 1MB.spc` (chord + pattern, `tools/mkbigspc.py`) | 0x100000 | F7596A77 | same first 0x10200 bytes; after 0x10200: BEC73C8F; extra RAM 101C0–101FF 758D6336 |
| `Gradius III ROM test.spc` (a ROM renamed) | 0x80200 | C5BCC3FF | without the 512-byte copier header CD973979; its first 64 KB 6D739ED0 |

## Next session: hwtest v2 (prepared 22 Oct)

Starting the player: Tools → "Play SPC Files" (picking a file in the file browser didn't start
it for Denley). That player takes the whole `SPC/` folder, so for one-file tests only that file
stays in `SPC/` and the rest wait in `SPC-later/` on the card (22 Oct: chord only).

Build (22 Oct): `out/q-hwtest.cor` sha1 9c3a6424…, timing met, pin check passes (94 I/Os, as
v1). `make sim-hwtest` passes: the PIC stand-in polls `0x2004_0000` and sends its 1 KB file after
the first answer (03 03); a second run where it waits for 00 finds it after three 5 s steps
(150 µs in simulation); pad model holding START + A shows both names; SDRAM model with AB10 as
DQM: hypotheses 0/1 clean at r4/f4.5, 2/3 fail everywhere; I2S framing check passes.
`make sim-sdram` passes.

1. Put the new `out/q-hwtest.cor` (v2) on the card: mount it, `tools/sdcore setup`, then
   `tools/sdcore use 12`. Keep only the chord file in `SPC/`.
2. Power-cycle, start "Play SPC Files", and film the screen for **70 s with sound**. Hold B for
   a moment, then Start, then A on a pad in port 1 during the first page. Frame the whole screen
   with a margin (v1's top row and left column were cut off) and avoid direct daylight on it.
3. Pages (cycle 34 s, so the film shows each twice): 0 overview (10 s), 1 link log from two
   entries before the first status read, 2 write runs of 32+ bytes, 3 the newest log entries
   (8 s each). What to read off:
   - **LINK** (page 0, line 2): "0x2004 answer" and "candidate" (0 = 03, 1 = 02, 2 = 01, 3 = 00,
     4 = FF); it steps every 5 s while the PIC only polls, "fixed 1" means the PIC then sent
     ≥ 4 KB ("after 1st read" counts those bytes): that answer is the one. If the file arrives,
     page 2 shows it as big write runs: compare the CRCs with the table below (where it goes:
     address; whether whole file or only parts). Page 1 shows what the PIC does right after the
     handshake (watch for writes to `0x1000_00C4`/`0x1000_05xx`, the video-PLL reconfiguration
     block, and for further status polls); the REPEATS column counts merged identical runs.
   - **AUDIO**: whether the test tone becomes audible once the handshake passes (v1 was silent;
     the PIC may set up HDMI audio only afterwards). Which pitch is clean (440 Hz = I2S, 880 Hz
     = left-justified) → `AUD_FRAMING`.
   - **PADS**: the held button's name appears next to "held:" (B, Y, SELECT, START, UP, DOWN,
     LEFT, RIGHT, A, X, L, R); raw word as before.
   - **SDRAM**: four hypothesis rows (AB10 low/high × open-drain pins released/low), errors at
     the eight capture points in that hypothesis's last pass (of 0x1000000 words). Expected: rows
     0 and/or 1 (AB10 low, spc.cor's level) show 000000 at one or more capture points (r5/f4.5
     likely), rows 2/3 stay at ~FFFF00 as in v1. The raw rows show the bus words at rising edges
     2–7 after a READ next to the two expected words (a clean hypothesis shows them a few columns
     in) and the idle bus. → `AB10_LEVEL`, `DQM_LOW` and the capture point for
     `quartus/snes_sdram` (notes/snes-sdram.md).
4. If the handshake works, repeat 2–3 with `Super Nt big 1MB.spc` and the Gradius ROM file (one
   file in `SPC/` at a time, power-cycle between).
5. `09-q-snes` (with audio and controller port 1, built with `PAD_CFG` 0 = confirmed and
   `AUD_FRAMING` 0): the backdrop should turn blue while a button is held. Its audio will
   probably stay silent like hwtest v1's (no handshake in that core either: it has no link slave).
6. `13-q-snes_sdram` on the card is built with AB10 high (v1's setting, no SDRAM response): don't
   run it until it is rebuilt with v2's SDRAM result.

## hwtest v1 (12-q-hwtest, 21–22 Oct) loading test files

v1's plan was: for each of the three test files, power-cycle, play it and film a minute while
pressing B, Start, A; read audio framing, pad cfg, SDRAM capture point and link runs. Only the
chord file was run (results below); the link part showed why nothing else could work yet.

## Order

| # | core | look for |
|---|------|----------|
| 01 | spc-colortest | SPC player with scrambled colours, stable picture: modified cores load |
| 02–04 | spc-invert-ch1/2/3 | tint per core (cyan = red channel, magenta = green, yellow = blue) |
| 05/06 | vtest / q-vtest | 720p pattern in one of 6 sync orders, 8 s each; photo incl. corner boxes |
| 07/08 | buslog / q-buslog | hex log of the PIC32 link; film ~3 min |
| 09 | q-snes | green bar + 7 green test lines, white and cyan moving squares |
| 10/11 | plltest / blinky | only if 05/06 show nothing |
| 12 | q-hwtest | v2: link handshake answer, SDRAM pin hypotheses, pads by name, audio (see Next session) |
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
- 22 Oct 2026, `12-q-hwtest` (v1), chord file only, video `IMG_3058.mov` (frames in
  `~/scratch/hwtest-videos/3058/`; transcription and reading in
  `notes/buslog-2026-10-22-hwtest.md`):
  - **PADS: confirmed.** cfg 0 (and cfg 1) read FFFF0000 idle, FFFF0001 with B, FFFF0008 Start,
    FFFF0100 A: `PAD_CFG` = 0 (P14 = latch, J13/K16 = clock, as decoded). cfg 2 reads 00000001,
    cfg 3 00000000.
  - **AUDIO: silent** in both framings (`tools/audiocheck.py`: noise only), audio PLL locked.
    The stock player's audio works on this projector, so the AD9889B is probably not set up for
    audio until the PIC gets past the handshake below [guess].
  - **SDRAM: no response.** All eight capture points wrong on 16 776 960 of 16 777 216 words
    every pass (0x0A passes → 0x09FFF601, 0x80 → 0x7FFF8000), DQM pins low or released alike:
    the reads return a constant. v1 drove AB10 high; spc.cor drives it low
    (notes/sdram.md, "Constant pins"). The "first f4.5 miss … got 0000 expected 0000" line is
    explained there too.
  - **LINK: the file never came.** The PIC did its set-up writes (4 big runs: 0x1EAF bytes at
    0, 0x28 at 0x1010_0000, 0x80 at 0x111F_8100, 0x2500 at 0x1017_0800; none is the .spc file),
    then from 406 ms on polled `0x2004_0000` (two bytes) ~305 000 times a second for the rest
    of the minute. v1 answered `02 00`. Decode (notes/pic-link.md, "Status 0x2004_0000"): it is
    the status of a reconfiguration block for the video PLL, same byte at every `0x2xx4_xxxx`
    address, idle value 0x03 or 0x02 depending on one ambiguous clear polarity. → hwtest v2.

