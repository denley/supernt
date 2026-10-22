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

## Next session: hwtest v3 (prepared 22 Oct)

Starting the player: Tools → "Play SPC Files" (picking a file in the file browser didn't start
it for Denley). That player takes the whole `SPC/` folder, so for one-file tests only that file
stays in `SPC/` and the rest wait in `SPC-later/` on the card (22 Oct: chord only).

**Before flashing, note what v3 drives that v2 didn't** (notes/sdram.md, "spc.cor pins with a
constant level"): 43 pins that spc.cor drives to a constant and our cores so far left as
weak-pull-up inputs, only ever at spc.cor's level: the 19 of banks 3A/3B (R5 R6 U7 U8 T7 T8 V6
U6 V9 V10 U10 T10 P12 R12 N9 P9 low, M9 T9 U11 high) switched per SDRAM pass between that level
and released, and 24 held at it for the whole run (4A: T13 T14 U16 V14 V15 V16 V19 W19 Y14 Y15
Y16 Y17 Y19 low, R14 U15 U17 U20 V13 V18 V20 Y20 high; 7A: K19 K20 low, J17 high, next to the
audio pins). H16 is used as an input (spc.cor's video-PLL reference).

Build (22 Oct): see "hwtest v3 build" below. `make sim-hwtest` and `make sim-sdram` pass.

1. Put `out/q-hwtest.cor` (v3) on the card: mount it, `tools/sdcore setup`, `tools/sdcore use
   12`. Keep only the chord file in `SPC/`.
2. Power-cycle, start "Play SPC Files", and film the screen for **2 minutes with sound** (the
   pages now cycle in 50 s: overview 10 s, then five 8 s pages; two full cycles plus the
   handshake stepping, up to 10 × 5 s). During the first overview page hold B, then Start,
   then A on a pad in port 1 (v2's video had no button held while the overview showed).
3. What to read off:
   - **LINK** (page 0, lines 2–6): "answer", "cand" with its name (candidate 0 = "emulated":
     the real PLL + reconfiguration IP; then 02, 03, 01, 00, FF, toggle, busy1ms, lockdrop,
     00-1ms, 5 s each while the PIC only polls), "polling" (1 once ≥ 1000 status reads) and
     its T, "fixed 1 cand N at T" (the PIC wrote ≥ 4 KB after the first status read and the
     last step: candidate N is the answer it wanted), "after poll" bytes. Expected: fixed with
     candidate 0 (polling stays 0: the PIC shouldn't need 1000 reads), T ≈ 0x18D or a little
     later, and the file as a big run on page 2 (CRCs in "Test files").
   - **VIDEO PLL** (page 0): locked 1 and waitrequest 0 = the emulation answers 02; H16 kHz
     ≈ 01220A (74.25 MHz; 000000 = no clock on H16, then candidate 0 says 01 and the fallback
     goes on to 02), out kHz 024414 (148.5 MHz), out1 kHz 005460 (21.6 MHz); "reconfig writes",
     "last reg = data" and "C4" show what the PIC does to the block (v2: one write, reg 00 =
     00000000). If the PIC reprograms the PLL, the out kHz values change.
   - Pages 1–3: page 1 now shows the 19 entries up to two after the first status read (the
     set-up that precedes the poll), 2 the big runs (the file), 3 the newest entries.
   - **SDRAM** pages 4 (errors per chip and capture point, 16 hypotheses) and 5 (raw words).
     Chip B (columns "B") should be 000000 at r4 (and f3.5) in every row except 13 (AB10
     high). Chip A: which rows show 000000 in the "A" columns. If chip A is clean in 0 and
     12–15 and dirty in 1, the dirty rows among 2–6 give the index of the pin it needs (row
     2+k dirty ⇔ bit k = 1; rows 7–11 the opposite); the index list is on the page. Raw page:
     a driving chip changes its byte from r4 on (r4 = exp0, r5 = exp1 when right).
   - **AUDIO**: whether the test tone becomes audible once the handshake passes; which pitch
     is clean (440 Hz = I2S, 880 Hz = left-justified) → `AUD_FRAMING`.
   - **PADS**: the held button's name next to "held:".
4. If the file arrives, repeat 2–3 with `Super Nt big 1MB.spc` and the Gradius ROM file (one
   file in `SPC/` at a time, power-cycle between).
5. `13-q-snes_sdram` is still built for 1024 columns and AB10 high: don't run it (it needs the
   512-column map, AB10 low and chip A's enable; notes/snes-sdram.md).

## hwtest v2 (12-q-hwtest, 22 Oct) results

Chord file only, video `IMG_3059.mov` (84 s; frames `~/scratch/hwtest-videos/3059/`;
transcription in `notes/buslog-2026-10-22-hwtest.md`, second part).

- **LINK: the file never came again.** Same set-up as v1, then a ramp on `0x1000_D110/D114`,
  then **4 bytes of 0 to `0x1000_0500`** (the mode register of the video-PLL reconfiguration
  controller) and the status poll from T = 406 ms on. v2 answered `03 03` for the whole run:
  "fixed 1, steps 00, 1st read #000" were a **build problem** (Quartus' default *power-up don't
  care* folded `cand_locked` to 1 and `first_rd` to 0, see the map report's "Stuck at" list),
  so the fallback never stepped. Fixed for every Quartus core (`ALLOW_POWER_UP_DONT_CARE OFF`
  in `quartus/common/supernt.tcl`). Decode re-check (notes/pic-link.md, "After hwtest v2"):
  the block is Altera's `altera_pll_reconfig`; bit 0 = its waitrequest, idle answer **02 02**.
- **SDRAM: chip B works, the page has 512 columns, chip A never drives.** With AB10 low, chip
  B's words are those written to columns 512–515 of the same row: the 1024-word burst wrapped
  at 512. Capture point r4 / f3.5. AB10 high: nothing drives. The open-drain group made no
  difference. Chip A's byte stayed constant in every hypothesis (notes/sdram.md, "hwtest v2
  result").
- **AUDIO: silent** in both framings (`tools/audiocheck.py`), audio PLL locked. Most likely the
  PIC sets up the AD9889B's audio only after the file transfer.
- **PADS: not exercised** (no button held while the overview was on screen; raw FFFF0000
  throughout). cfg 0 stays confirmed from v1.

## hwtest v3 build (22 Oct)

- `out/q-hwtest.cor` sha1 8bed14a9…, timing met (all slacks positive), pin check passes
  (138 I/Os: v2's 94 + H16 + 19 switched + 24 held constant pins). The video-PLL stand-in was
  placed at FRACTIONALPLL_X0_Y38 (spc's FPLL.000.037 position, H16 reference) with a 1188 MHz
  VCO like spc's; the audio PLL at X54_Y1. Map report: no handshake register is "stuck" any
  more (`ALLOW_POWER_UP_DONT_CARE OFF`).
- `make sim-hwtest`: three link scenarios. (1) The PIC stand-in writes 0 to `0x1000_0500` and
  polls for 02 02: the real reconfiguration IP answers 02 02 on the first poll (waitrequest
  drops 415 clocks after reset, the PLL stand-in locks after 27 µs), the file arrives, fixed
  with candidate 0. (2) No H16 clock: emulation says 01 01, the fallback steps to 02 after one
  window and is fixed with candidate 1. (3) The PIC waits for 00: four steps, fixed with
  candidate 4. In all three the power-up /RD-low is ignored and the first read run is the
  status poll. Pads show START + A, I2S framing check passes, SDRAM table as in sim-sdram.
- `make sim-sdram`: the model has a 512-column page, chip B's DQM on AB10 and chip A's on tie
  index 5; chip B clean at r4/f4.5 except hypothesis 13, chip A clean exactly where index 5 is
  at its stock level, and hypotheses 2–6 decode index 5.

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
| 12 | q-hwtest | v3: link status from a real PLL + reconfiguration IP with fallback, SDRAM chip A enable search, pads by name, audio (see Next session) |
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

