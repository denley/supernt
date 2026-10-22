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

## Next session: hwtest v4 (prepared 22 Oct)

Starting the player: Tools → "Play SPC Files" (picking a file in the file browser didn't start
it for Denley). That player takes the whole `SPC/` folder, so for one-file tests only that file
stays in `SPC/` and the rest wait in `SPC-later/` on the card (22 Oct: chord only).

What v4 changes (v3 results below): it answers the status poll with **02 02 first** (what the
PIC took in v3; the emulated PLL and the other candidates follow only if the PIC keeps
polling), answers the **pad registers** `0x2000`/`0x2001` like the stock core (buttons, 1 =
pressed; `notes/controllers.md`, "Link registers") and, since the PIC sat in the player's UI
loop in v3 waiting for something, **presses buttons by itself**: once the UI loop has run 10 s
without a file transfer, one button at a time for 0.5 s, 3 s apart, in the order A, START, X,
Y, L, R, UP, DOWN, LEFT, RIGHT, SELECT, B (then round again), OR'd with the real pad, until a
write run of ≥ 256 bytes (the file) starts. The screen records which press came before it.
Pad reads aren't logged any more (counted), the log keeps its first 512 entries plus the newest
512, page 2 shows the newest big runs. Audio: I2S only, 24 dB quieter. No pin changes from v3
(same 138 I/Os, 4 mA on the 43 stock-constant pins).

Build (22 Oct): see "hwtest v4 build" below. `make sim-hwtest` passes (four link scenarios,
the UI loop waits for START and gets it from the second virtual press).

1. Put `out/q-hwtest.cor` (v4) on the card: mount it, `tools/sdcore setup`, `tools/sdcore use
   12`. Keep only the chord file in `SPC/`.
2. Power-cycle, start "Play SPC Files", film the screen with sound for **3 minutes, hands
   off** (no button presses needed; a pad in port 1 may stay plugged in and still works).
   Expected timeline (from the start of the core; the screen shows the real times): poll
   answered at ~0.4 s, video-PLL retune and set-up blocks within ~0.1 s (v3: 80 ms after its
   02), UI loop from ~0.5 s, virtual presses from ~10.5 s: A ~10.5 s, START ~14 s, X ~17.5 s,
   Y ~21 s, L ~24.5 s, R ~28 s, UP ~31.5 s, DOWN ~35 s, LEFT ~38.5 s, RIGHT ~42 s, SELECT
   ~45.5 s, B ~49 s, then again from A at ~52.5 s. Pages: overview 10 s, then five 8 s pages.
3. What to read off:
   - **PLAYER UI** (page 0): "pad reads" counting = the UI loop runs; "virtual press #NN =
     button N" plus the name while pressed; "state" (1 waiting, 2 pressing, 3 done); the
     "file:" line = press number and button (legend on the screen: 0 B … 8 A …) after which a
     write run of ≥ 256 bytes started, its T and how long after the press start. Also note
     anything that happens on screen/sound around each press (HDMI drop, the PIC's own
     reactions in the log).
   - **LINK**: "answer 02 candidate 1 steps 00", "fixed 1 cand 1" expected; page 2 = the
     newest big write runs (the file: CRCs in "Test files"); page 3 = the newest entries (the UI
     loop is one entry, `0x1000_D120` with a repeat count; anything new the PIC does after a
     press shows here).
   - **VIDEO PLL**: "waitrequest … (ever 0: N)": whether the emulated IP's waitrequest was ever
     low (v3's stuck waitrequest), "taken" = commits it accepted.
   - **SDRAM**, **AUDIO**: as v3 (nothing new expected; the tone should be quiet and clean).
4. If the file arrives, repeat with `Super Nt big 1MB.spc` and the Gradius ROM file (one file
   in `SPC/` at a time, power-cycle between).
5. `13-q-snes_sdram` is still built for 1024 columns and AB10 high: don't run it (it needs the
   512-column map, AB10 low and a decision on chip A; notes/snes-sdram.md, notes/sdram.md).

## hwtest v3 (12-q-hwtest, 22 Oct) results

Chord file only, video `IMG_3062.mov` (155 s, with sound; `IMG_3061.mov` an aborted first
try); frames `~/scratch/hwtest-videos/IMG_3062/`; transcription in
`notes/buslog-2026-10-22-hwtest.md`, third part.

- **LINK: 02 02 is the answer.** Candidate 0 (the emulated PLL + Altera reconfiguration IP)
  answered 03 03: its waitrequest never dropped after the PIC's write to register 0 (it does in
  simulation; open). After 5 s the fallback stepped to candidate 1 = 02 and the PIC moved on
  at once (fixed with candidate 1 at T 0x14AE). It then retuned the video PLL (25 commits to
  the `0x1000_05xx` block, 4 writes to `0x1000_00C4`; a short HDMI drop), wrote five more blocks
  (`0x1006_0000` 0x2000, `0x1010_0000` 0x28, `0x1001_3000` 0x300, `0x111F_8100` 0x80,
  `0x1018_0000` 0x1000; none is part of the .spc) and from ~5.5 s on ran a ~32 ms loop: write
  01 to `0x1000_D120`, read `0x2000_0000` and `0x2001_0000` (2 bytes each), twice. Those are the
  pad registers (decoded since, `notes/controllers.md`); v3 answered 00. **The file never
  came**: the player UI presumably waits for a button. The 1024-entry log was full after ~10 s.
- **AUDIO works** from ~4 s (once the poll passed): `tools/audiocheck.py` finds the I2S
  segments (440 Hz) clean, the left-justified ones harsh. **`AUD_FRAMING` = 0 (I2S)
  confirmed.** The full-scale tone was uncomfortably loud.
- **PADS**: raw FFFF0000 idle, FFFF0001 / FFFF0008 / FFFF0100 with B / START / A, named right.
- **SDRAM**: chip B 000000 errors at f3.5 and r4 in every hypothesis except 13 (AB10 high);
  chip A ~7F8000 (every word) in all 16: its enable is none of the 19 3A/3B constants nor the
  held 4A/7A ones (`notes/sdram.md`, "hwtest v3 result"). Next: a continuity check on chip A's
  CKE/DQM/CS#; fallbacks chip B alone (8-bit) or the x16 chip.
- Display bug: the table pages showed entry (start − 1) in their first row (page 2's first row
  a stale copy of big run 0); fixed in v4.

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

## hwtest v4 build (22 Oct)

- `out/q-hwtest.cor` sha1 eecebe77…, timing met (all slacks positive), pin check passes (138
  I/Os, the same pins and settings as v3, 4 mA on the 43 stock-constant pins). Map report: the
  only new constant registers are the expected ones (the fixed pad bytes, the fixed audio
  framing, constant fields of the log entries).
- `make sim-hwtest`: four link scenarios (default: 02 at once; `+cand0`: the emulated PLL
  answers 02; `+cand0 +noh16`: emulation 01, one step to 02; `+want=00`: three steps). In each,
  the PIC stand-in writes a 600-byte set-up block after the poll, then runs the UI loop with the
  pad holding Y and R (0x2000 = 02, 0x2001 = 08), sees A (0x2001 = 09) from the first virtual
  press and START (0x2000 = 0A) from the second, then sends the 1 KB file: recorded as "after
  press 2 = button 3". The UI loop is one log entry (`0x1000_D120`, repeats = loops), the 232
  pad reads are only counted, 1100 more entries wrap the log (the first 512 and the newest 512
  readable, the newest entry right). I2S only at 0.056 full scale, clean (`check.py`).

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
| 12 | q-hwtest | v4: status 02, pad registers with automatic virtual presses, ring log; SDRAM, pads, audio as v3 (see Next session) |
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

