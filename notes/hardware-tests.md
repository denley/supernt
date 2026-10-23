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

## Next session: q-snes_load (prepared 22 Oct)

The SNES core that loads its ROM over the link (`notes/snes-load.md`; procedure in its "Console
test" section): `tools/sdcore setup`, `tools/sdcore use 14`, `tools/sdcore roms` (three wrapped
ROMs into `SPC/`: "0 SA1 TEST.spc", "1 Gradius III.spc", "2 Kirby Super Star.spc"). Start "Play
SPC Files", record with `tools/capview.py`, DOWN once, Y (RUN). Expected: diagnostics page,
"= INFO CRC: OK", then the SA-1 test's 7 green bars. Then L+R+START for the browser, Gradius
III, Kirby Super Star. Note which button is RUN, the PIC LINK LOG rows after each transfer and
anything that differs from the notes.

| file | size | CRC-32 file | ROM CRC-32 |
|---|---|---|---|
| `0 SA1 TEST.spc` (`build/snes_load/sa1test.spc`) | 0x18200 | AD3E85A3 | 8C5F7E54 |
| `1 Gradius III.spc` (`gradius3.spc`) | 0x90200 | A70084ED | CD973979 |
| `2 Kirby Super Star.spc` (`kirbyss.spc`) | 0x410200 | 40E67CE5 | 89D0F7DC |

## Next session: hwtest v5 (prepared 22 Oct)

One hands-free run of ~3 minutes reads the SPC player's own screen and records what every
virtual press does to it. v4/v4b results below.

What v5 changes (everything else as v4b: same 138 I/Os and pin settings, I2S audio 24 dB down,
SDRAM hypotheses, ring log):

- **FIRST_CAND fixed**: the answer starts at 02 (v4/v4b started at candidate 0 and stepped
  after 5 s, see the results). Expected: "answer 02 candidate 1 steps 00", the PIC moves on at
  ~0.4 s.
- **The player's screen is captured** (`quartus/common/ui_capture.sv`): copies of every write
  to `0x1018_0000` (4 KB screen), `0x1006_0000` (8 KB, font?), `0x1001_3000` (0x300, palette?),
  the register blocks (`0x111F_81xx`, `0x1010_00xx`, `0x1000_D1xx/05xx/90xx/D2xx/00xx/80xx/C2xx/
  F0xx/D0xx`, last value per byte) and `0x1017_0000-3FFF`, in a 32 KB capture space (screen
  0x0000, font 0x1000, palette 0x3000, registers 0x3400-0x3EFF, 0x1017 block 0x4000). A
  scanner keeps CRC-32s per 4 KB block and of the logged regions, logs every settled screen
  change (no write for 30 ms; time, CRC, the virtual press current then) and, per press, the
  screen CRC just before the next press.
- **Views** (pages listed below): the screen as text in our font (2-byte cells, character
  first, 64 per 128-byte row, as v4b's partial writes show; also 1 byte per character), as
  tile maps drawn with the captured 8 KB in nine glyph formats (`quartus/common/gfx_render.sv`;
  the glyph is the cell's first byte), glyph sheets of the 8 KB, a hex dump of the first 0x540
  bytes, and **bit images** of each 4 KB block that `tools/bitdump.py` decodes from the video
  (every screen state, the font and the rest, byte exact; checked on simulated frames and mock
  photos with keystone, barrel distortion, blur, noise, uneven light and JPEG).
- **Virtual presses** (`quartus/common/vpress.sv`): from 4 s after the UI loop starts, one press
  every 4 s (0.5 s pressed), 48 in this order: A, START, START,
  A, DOWN, DOWN, A, UP, A, RIGHT, A, LEFT, Y, Y, X, X, L, R, SELECT, START, SELECT, B, B, A,
  DOWN, START, B, RIGHT, RIGHT, START, DOWN, A, START, UP, UP, A, START, Y, A, SELECT, X, A, L,
  START, R, START, B, START (~44 fit in 3 minutes). From 2.95 s to 3.95 s after each press
  starts (and in the second before the first press), page 1D (the screen's bit image) is
  shown and the page cycle pauses. Pressing stops only for the file: a single write run of
  16 KB outside the UI's blocks (`0x1018`, `0x1006`, `0x1017`), or 64 KB of writes outside all
  known UI regions; the press before it is recorded ("file:" line). (v4b stopped after 32 KB of any writes, i.e. eight screen redraws.)

Pages (numbers in hex as the screen shows them; cycle ~101 s plus 1 s per press):

| page | s | view |
|---|---|---|
| 00 | 5 | overview (new line SCREEN: CRC, changes, last change T, bytes written, bytes outside the UI regions) |
| 01 | 4 | screen changes: CRC now, font/palette/0x1017 CRCs (expected B5CFAF0C, D0C0DF2A, B1883CCD), the newest 18 changes (T, CRC, press #, button) |
| 02, 03 | 3 | screen as text, 2-byte cells (the character byte), rows 00+ / 0B+; codes 80-FF yellow, 01-1F cyan as '@' + code |
| 13, 14, 15, 16 | 3 | screen as text, 1 byte per character: rows 00+ / 0B+ / 0B+ / 00+, columns 00+ / 28+ / 00+ / 28+ (hex) |
| 04 | 3 | tile map in our font, 2-byte cells, x2 wide (all 64 x 32) |
| 05 / 06 / 07 | 2.5 | 2-byte cells, captured glyphs 16x16 at 1 bpp: 1:1 (all) / x2 rows 00+ cells 00+ / x2 rows 0B+ cells 18+ |
| 08 | 2.5 | 2-byte cells, 8x16 2 bpp, x2 wide |
| 09 / 0A | 2.5 | 2-byte cells, 8x8 4 bpp (x2) / 8x16 4 bpp (x2 wide) |
| 0B / 0C | 2.5 | 2-byte cells, 8x16 2 bpp SNES planar / 8x16 1 bpp (x2 wide) |
| 0D | 2.5 | 1-byte entries, 8x16 2 bpp, 1:1 |
| 0E | 2.5 | our font, 1-byte entries, 1:1 (120 x 32) |
| 0F-12 | 2 | glyph sheets of the 8 KB: 16x16 1 bpp, 8x16 1 bpp, 8x16 2 bpp, 8x8 4 bpp |
| 17, 18 | 3 | hex dump of the screen, 0x000-0x29F and 0x2A0-0x53F, 32 bytes per row |
| 19 | 4 | press table: per press #, button, start T, screen CRC just before the next press |
| 1A, 1B, 1C | 2, 4, 4 | link log: up to the first read, newest big writes, newest entries (as v4) |
| 1D-23 | 2 | bit images of capture blocks 0-6 (1D = the screen, 1E/1F the 8 KB, 20 palette + registers, 21-23 the 0x1017 block) |
| 24, 25 | 2 | SDRAM errors, raw words (as v4) |

Graphics view headers: `VIEW nn mode glyph WxH (hex) bpp b planar(1)/own font(F) e entry bytes
s x/y scale r first row c first column blk block CRC T #press`; mode 1 map, 2 sheet, 3 bits.
Dark blue = outside the map, dark red = glyph number past the 8 KB.

1. Put `out/q-hwtest.cor` (v5) on the card: `tools/sdcore setup`, `tools/sdcore use 12`; only the
   chord file in `SPC/`.
2. Power-cycle, start Tools → "Play SPC Files", film the screen **for 3 minutes, hands off**
   (sound not needed; a pad may stay plugged in).
3. Reading: extract frames at 2-4 fps as PNG (`ffmpeg -i IMG_xxxx.mov -vf fps=4
   frames/f%04d.png`; `tools/frames.sh` gives 1 fps JPEGs for reading the text pages). Run
   `python3 -I tools/bitdump.py --text 128 --cells frames/f*.png` (about 1 s per frame that is
   not a bit image, 5-20 s per bit image): every frame of a bit-image page decodes to its 4 KB
   block; each distinct block (by CRC) is printed once, as 32 rows of 64 characters (the
   cells' character bytes). Page 1D's blocks are the screen before each press: their CRCs
   should match the page header, the press table (page 19) and the change list (page 01);
   1E-23 give the rest of the capture (`--out base` saves `base-<CRC>.bin` per block for
   offline rendering, `--hex` shows bytes). Text pages 02/03 are readable directly; the
   tile-map page that shows clean text gives the glyph format of the 8 KB.

## hwtest v5 build (22 Oct)

- `out/q-hwtest.cor` sha1 b74158a4…, timing met in every corner with 50 ps of extra hold margin
  on the board clock (`hwtest.sdc`; the first build missed hold by 1 ps into the M10K holding
  the screen-change history, now in MLABs), pin check passes (the same 138 I/Os and settings as
  v3/v4). 148 of 308 RAM blocks. The map report's Inverted Register Statistics now list
  `cand_q[0]`, vpress's `btn_q`/`xbtn_q` and the SDRAM command register: they power up high.
- `make sim-screen` (new, Verilator, ~3 min): the PIC stand-in writes 2-byte cells and 16x16
  1 bpp glyphs; every page rendered once (`build/sim/screen-PP-FFF.png`, PP = page, decimal):
  text views, tile maps (05-07 show the text), sheets, hex, history and press table match
  the stand-in; all 24 bit-image frames decode with `tools/bitdump.py` to the capture's CRCs,
  and so does a mock photo (keystone, blur, noise, JPEG). The bit-image decoder was also
  checked on a harsher mock (barrel distortion, light gradient, JPEG 50).
- `make sim-hwtest` (iverilog): the four link scenarios pass, with the candidate register
  forced to 0 at power-up as on the console (the post-configuration load restores 02), the
  file (a 1 KB run, FILE_RUN in the testbench) recorded after press 2 = START; I2S check passes.

## hwtest v4 / v4b (12-q-hwtest, 22 Oct) results

Chord file only. v4 (commit 9f37a27): video `IMG_3063.mov`; v4b (c2ae39b, presses go on after
the first big write, order A, START, A, START, DOWN, A, RIGHT, A, X, Y, L, R, UP, LEFT, SELECT, B):
`IMG_3064.mov`; 1 fps frames in `~/scratch/hwtest-videos/IMG_306x/`. Transcription of the
pages in `notes/buslog-2026-10-22-hwtest.md` (fourth part).

- **LINK: both started at candidate 0 again.** Page 1 (IMG_3064 f020): `0x2004_0000` answered
  03 (the emulated IP, waitrequest stuck as in v3) for 0x114D57 polls from T 0x18D, then 02 at
  T 0x14A2 and the PIC moved on: "answer 02 candidate 1 steps 01, fixed 1 cand 1 at T 014AE",
  the same as v3. **Root cause: Quartus ignores initial values in ANSI port declarations.**
  `output reg [3:0] cand = FIRST_CAND` powered up 0, and so did vpress's `btn = 4'hF` and
  `xfer_btn = 4'hF` (the overview at f009 showed "press #00 = button 0" and "file: after press
  #00 = button 0", not F). Evidence in the reports: synthesis warning 10030 "no driver or
  initial value, using a default initial value '0'" for `i2s_test`'s `mode` (declared the same
  way), `sdram_test`'s `sd_cs_n = 1'b1` "stuck at GND", and none of these registers in the map
  report's Inverted Register Statistics (where Cyclone V power-up-high registers appear,
  NOT-gate push-back). v4b's `(* preserve *)` only stopped the merge with `n_steps[0]`. Fixed in
  v5 (internal registers + a 256-clock post-configuration load of FIRST_CAND; the same pattern
  fixed in vpress, i2s_test, sdram_test, sdram_rom; `notes/quartus.md`, "Power-up values").
- **The player redraws a 4 KB screen at `0x1018_0000` after button presses.** Page 2 (IMG_3064
  f180, newest big runs; press n of v4b started at 16.05 + 3.5 (n - 1) s, T in 1.024 ms):

  | T | CRC-32 (0x1000 bytes) | after |
  |---|---|---|
  | 014F1 | CE6B18CC | the set-up (first screen) |
  | 04C43 / 04C45 | 37118BEB / 960EF583 | press 2 START, +437 / +439 ms |
  | 04E8D | 960EF583 | START + 1037 ms (same screen again) |
  | 072AB | FC96DD53 | press 5 DOWN, +5 ms |
  | 0B71B | A60352C7 | press 10 Y, +445 ms |
  | 0DD7E | 8059CE1D | press 13 UP, +8 ms |
  | 0F9C8 | CE6B18CC | press 15 SELECT, +424 ms: back to the first screen |
  | 105AC | 3596478E | press 16 B, +41 ms |

  A (presses 1, 3, 6, 8), the second START, RIGHT, X, L, R and LEFT changed nothing. v4
  (IMG_3063) shows the same START response (37118BEB, then 960EF583 twice). Nothing else
  wrote 4 KB or more: data writes 0x112C8 in all, 0xC7ED after the poll (f163); no .spc data.
- **The screen is a map of 2-byte cells: character (ASCII), then an attribute byte.** Page 3
  (f187, newest entries) shows B's update in detail: `0x1000_D129` = 01, 16 bytes at
  `0x1018_0DE8` starting 0x54 ('T'), then 16 bytes at `0x0DE8` and 8 at `0x0E6C`, both `20 00`
  repeated (by their CRCs), `0x1000_D129` = 00, then the whole 4 KB. With 64 cells per 128-byte
  row, 0x0DE8 is row 27, cells 52-59, ending exactly at cell 60 = 1920 / 32 (32-pixel cells at
  1080p, e.g. 16x16 glyphs drawn twice as large: 256 glyphs x 32 bytes would be the 8 KB at
  `0x1006_0000`) [likely]; 0x0E6C is row 28, cells 54-57. `0x1000_D129` brackets partial
  updates (a "hold display" flag?) [guess]. Before that, `0x1000_D110` (04 03 02 01 00) /
  `0x1000_D114` (0C 08 06 04 02 00) ramp down at T 0xFB2E-0xFBCF, after SELECT (a fade; v4 showed
  one after START). The UI loop (`0x1000_D120` = 01 every 32 ms) went on throughout.
- **Pressing stopped after 16 presses** (overview "press #10" is hex) because vpress counted the
  eight 4 KB redraws towards its 32 KB "file" limit (state 3 at the eighth, T 0x105AC); fixed
  in v5 (only writes outside the UI's regions count).
- PADS: IMG_3064 "port 1 raw 00000000, std pad 0" (no pad plugged in; the virtual presses
  don't need one). AUDIO: I2S tone, quiet, fine. SDRAM: as v3 (chip B fine, chip A dead).
- Stock core, briefly: the link's write data go through a 40-bit FIFO (`M10K.022.021`/`.022`,
  address + data) into other clock domains; where `0x1006`/`0x1018` land wasn't traced (v5
  captures them instead).

## hwtest v4 plan (22 Oct)

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
| 12 | q-hwtest | v5: the player's screen captured and shown (text, tile maps, bit images for tools/bitdump.py), a press every 4 s; answer 02 from the start; pads, SDRAM, audio as v4 (see Next session) |
| 13 | q-snes_sdram | as 09, but the ROM runs from SDRAM (built for 16 bit/1024 columns/AB10 high: superseded by 14) |
| 14 | q-snes_load | v2: the way back to the player's menu (DOWN+SELECT), 64 KB save RAM (Kirby's Dream Land 3, Super Mario RPG), kept saves, the full PIC log (`notes/snes-load.md`, "Console test (v2)") |
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


- 22 Oct 2026, hwtest v5 (exploring presses) and v6/v6b (scripted presses), HDMI capture dongle
  on homebox (`tools/capview.py`): **the SPC file arrives over the link.**
  - v5's screen capture (`tools/bitdump.py`) showed the player's UI: a file browser opening in
    `0:/SPC` (GO BACK, SPC README.TXT, SUPER NT TEST CHORD.SPC, SPC2_FILE_SPECIFICATION_V1.TXT;
    cursor = attribute 0x60, on GO BACK), footer NAVIGATE/PAGE, RUN/MENU, BACK/BACK TO GAME;
    START = MENU (Video/Audio/System/About/Save-Clear settings); pad bit 1 (our "Y") =
    RUN/CONFIRM, bit 0 (our "B") = BACK (up a folder), SELECT = CANCEL in the menu; A, X, L, R,
    LEFT, RIGHT did nothing there. v5's exploring toggled "-3dB output cut" in the Audio menu and
    then cancelled (not saved); later presses in the root folder lost the picture.
  - v6: DOWN, DOWN, RUN with 0.5 s presses: the first DOWN auto-repeated, RUN hit the .txt:
    "ERROR: NOT AN SPC!" (the PIC checks the file).
  - v6b (0.1 s presses): RUN on the chord; the PIC wrote the **whole file verbatim to link
    address 0x0000_FF00 + file offset** (so the SPC RAM at file offset 0x100 lands at 0x1_0000),
    in runs of 0x1000 at 0xFF00 then 0x2000 each and 0x1200 at 0x1EF00, all within 36 ms
    (T 0x2F13–0x2F37); every run's CRC matches `build/test-chord.spc`.
  - v6b with `Super Nt big 1MB.spc` in place of the chord (the browser sorts names
    case-sensitively, so it took the chord's row): **the whole 1 MB arrived**, again at
    0x0000_FF00 + file offset, in 0x3000-byte runs (last run 0x10DF00, 0x2000 bytes), in about
    0.6 s (T 0x2F.. – 0x3164). Five runs checked against `build/test-big-1m.spc`, all match. So
    files much larger than an SPC are sent whole as long as the PIC accepts them as SPCs
    (header check: a .txt gave "ERROR: NOT AN SPC!"); a ROM can be loaded wrapped in an SPC.

- 23 Oct 2026, `14-q-snes_load` (first console run, files from `tools/sdcore roms`): **SNES games
  load from the SD card and run.** The user picked each file in the PIC's browser with the real
  pad (Y = RUN worked). 0 SA1 TEST: INFO CRC OK, all 7 SA-1 tests green, squares moving, pad
  turns the backdrop blue. Gradius III (512 KB LoROM): Konami logo, intro, weapon select,
  gameplay. Kirby Super Star (4 MB SA-1): CRC 89D0F7DC verified, Nintendo/HAL logos, title,
  game select, Spring Breeze, gameplay. SDRAM at 107 MHz (chip B, 8-bit) fine: late 0, forced
  refresh 0.
  - Problem: L+R+START back to the browser shows a frozen browser (power-cycle needed). The
    PIC link log (L+R+SELECT, Kirby) shows after the file (T 0x1DCA): a screen update
    (0x1018_0F6C, 8 bytes; 0x1000_D129 = 00), 0x0000_00FE = 06, 0x1000_0102 = 00,
    0x1000_0010 = 00, then 0x1000_0021 = F8 at T 0x1DFD, and the UI loop stops for good (last
    UI T 0x1DFE): after a run the PIC no longer reads the pad or redraws, i.e. it treats the
    core as running; how the stock core gets back to the PIC's menu (menu button combo detected
    by the core and signalled through a status register?) is the next thing to decode.
  - Recording: `~/scratch/cap/rec-20261023-082437.mkv` (test at the end, ~62–67 min).

- 23 Oct 2026, snes_load **v2 built** (not yet run): stock pad-poll waveform, pad registers
  always answered, the core follows the PIC's screen when it wakes (DOWN+SELECT expected, by the
  decode in notes/pic-link.md, "After a file"), ARAM in SDRAM, 64 KB save RAM, full PIC log.
  One-run test script: notes/snes-load.md, "Console test (v2)".

- 23 Oct 2026, `14-q-snes_load` v2 (dd820dc): **works really well** (user). Recording
  `~/scratch/cap/rec-20261023-115135.mkv` (from 11:51; earlier play not recorded): Kirby Super
  Star played (The Great Cave Offensive), back to the PIC's browser without a power cycle
  (DOWN+SELECT, the JB menu combo: the PIC watches the pad itself, v2 polls with the stock
  waveform and follows the PIC's screen), then Super Mario RPG: new game, naming screen, intro,
  Bowser's Keep. Kirby's Dream Land 3 not in the recorded part (not confirmed). RESET not tried.
  Photo: `photos/snes-load-v2-2026-10-23.jpg`.

- 23 Oct 2026, `14-q-snes_load` v3 (port 2 pin scan, AUTO poll timing; built from seed 2, setup
  slack -0.07 ns at the slow corners, 115 user I/Os, pin check passes; v2 kept on the card as
  `TESTCORES/90-q-snes_load-v2.cor`). Recording `~/scratch/cap/rec-20261023-165658.mkv`, status
  page `photos/snes-load-v3-2026-10-23.jpg`:
  - **Port 2's data line is D6** (8A), normal polarity (line low = pressed, as T12): PORT 2 row
    `pin D6 normal pad FFFF0000 std`, scan `110110P10000111…` (M7 1, U12 1, U13 0, G11 1, H10 1,
    L8 0, **D6 P**, D9 1, E10-G10 0, all open-drain pins 1). **Player 2 works** in Kirby Super
    Star (user). So J13/K16 do clock port 2 too.
  - **SELECT alone still woke the PIC** in the game, with AUTO (fast waveform in the game) and with
    FAST (v1) forced: the PIC decodes the fast waveform too; v1's "L+R+SELECT never woke it" was
    not evidence about the waveform. Fix in v4: the core keeps a PIC that wakes without
    DOWN+SELECT hidden (notes/snes-load.md, "v4").
- 23 Oct 2026, snes_load **v4 built** (not yet run): port 2 on D6 directly, a PIC woken without
  DOWN+SELECT stays hidden behind the game; timing met (+0.542 ns), 87 user I/Os. Test:
  notes/snes-load.md, "Console test (v4)". Installed on the card as `14-q-snes_load` (and
  spc.cor); v2 and v3 kept as `TESTCORES/90-q-snes_load-v2.cor`, `91-q-snes_load-v3.cor`.
- 23 Oct 2026, `14-q-snes_load` **v4** on the console (recording
  `~/scratch/cap/rec-20261023-183420.mkv`): Kirby Super Star, then Super Mario RPG after a power
  cycle. SELECT alone no longer opened the browser, but **DOWN+SELECT didn't either** (user had to
  power cycle to change games). The status page during Kirby (T 0x1094B) showed why: `last T`
  0x1093B, `UI` 0x208E (before the boot), `pad rd` 0x20B4, newest log entries `20000000` and
  `20010000`, 2 bytes, 0x70F repeats from T 0x208E to 0x1093B: **the PIC polls the pad registers
  over the link while a game runs** (notes/pic-link.md, "Correction"), and v4 answered 0.
- 23 Oct 2026, snes_load **v5 built** (seed 2, timing met +0.457 ns): pad registers pass
  DOWN+SELECT during games (else 0).
