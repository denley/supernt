# Bus log, 22 Oct 2026: 12-q-hwtest, "Super Nt test chord.spc"

- Date: 22 Oct 2026. Core: `12-q-hwtest` (installed as spc.cor). Only the file
  `Super Nt test chord.spc` was loaded.
- Source: video `IMG_3058.mov` (64.6 s, projector in daylight). Transcribed from frames re-extracted at
  10 fps (`vNNNN`, t = (NNNN-1)/10 s). The frames of each page were aligned (per-tile phase
  correlation, affine fit) and averaged, which made every table cell readable. The 1 fps frames
  `fNNN` were used for a first pass.
- Frames per page:

  | page | content | 10 fps frames stacked | ≈ 1 fps frames |
  |---|---|---|---|
  | 0 | overview | single frames v0642 (end values) and v0102 (early) | f011, f065 |
  | 1 | write runs ≥ 32 B | v0152–v0207 (7 frames passed alignment) | f016–f021 |
  | 2 | write runs ≥ 32 B, cont. | v0212–v0254 | f022–f026 |
  | 3 | read runs | v0273–v0327 | f028–f033 |
  | 4 | all runs 0x00–0x13 | v0335–v0388 | f034–f039 |
  | 5 | all runs 0x14–0x27 | v0391–v0447 | f040–f045 |
  | 6 | all runs 0x28–0x3B | v0451–v0507 (5 frames rejected) | f046–f051 |
  | 7 | all runs 0x3C–0x4F | v0511–v0567 | f052–f057 |

  Page order in the video: page 0 runs until about v0148, then pages 1 to 7, then page 0 again from
  v0569 to the end. Page 4 does not come back at the end.
- The projected image is bigger than the screen. The top half of the header line ("page N from X
  of Y") and the first two digits of the `#` column are cut off. Only the last hex digit of `#` can
  be read. It counts up without gaps on every page, so the entry numbers below come from the page
  position.
- Columns: `#` entry index (hex). K is the kind: 0 write run, 1 read run (D0 = the value we
  returned), 2 A=3 latch, 3 A=6/7 write. ADDRESS is the 8-hex start address. BYTES is the run length
  (hex). D0 is the first data byte. CRC-32 is the CRC of the run's bytes. T is the start time in
  units of 1.024 ms (hex). T ms = T × 1.024.
- CRC check: for every run of 4 bytes or fewer, the full data bytes were solved from (length, D0,
  CRC-32). Every row came out consistent, so D0 and CRC-32 for those rows are confirmed. The
  "data" column shows the solved bytes. Runs longer than 4 bytes can't be checked this way.
  Addresses and T are not covered by the CRC check, but they read cleanly in the stacked images. No
  digit is uncertain.

## Page 0: overview

End of video (v0642, t ≈ 64.1 s):

| field | value |
|---|---|
| AUDIO | now playing framing 0 (it switches every 4 s), time 3B s, 12.288 MHz PLL locked 1 |
| PADS | T12 now 0 (flickers 0/1 between frames), polls 0E2? (counting) |
| pad cfg 0 (latch P14, clock J13/K16) | FFFF0000 |
| pad cfg 1 (latch P14, clock J13/K16 inverted) | FFFF0000 |
| pad cfg 2 (latch J13/K16, clock P14) | 00000001 |
| pad cfg 3 (latch J13/K16, clock P14 inverted) | 00000000 |
| data writes | 00004B41 |
| reads | 022A08C7 |
| other writes | 039B6DE1 |
| runs logged | 400 (log full) |
| big runs | 004 |
| read runs | 400 (log full) |
| address now | 20040000 |
| time | 038CE9E0 µs (59.6 s) |
| last strobe | 038CE9E0 µs (same as time, so the bus is still active) |
| SDRAM | 32 MB, pass 0080, DQM pins low 1, best errors: low 3FFFC000, off 3FFFC00? |
| errors per capture | r3 7FFF8000, f2.5 7FFF8000, r4 7FFF8000, f3.5 7FFF8000 |
| "one should stay 0" | r5 7FFF8000, f4.5 7FFF8000, r6 7FFF8000, f5.5 7FFF8000 |
| first f4.5 miss | at 000000, got 0000, expected 0000 |

Other snapshots:

- v0580 (t ≈ 57.9 s): reads 01EFC637, other writes 033A5447, address now 20040003, time 032DFD4E,
  last strobe 032DFD4E. SDRAM pass 0072, DQM low 1, best errors low 38FFC6FC off 38FFC6F?.
- v0600: reads 0202915D, other writes 0359A6DC, address now 20040000, time and last strobe
  034C9C33. SDRAM pass 0076, DQM low 1, best low 3AFFC3FE off 3AFFC4F?. Every error-per-capture
  field reads 76FF88FB.
- v0610: DQM low 0, best low 3CFFC2FE off 3BFFC40?. Every error field reads 78FF86FE.
- v0640: reads 022827AA, other writes 03984C05, address now 20040004, time 0389D9FD, last strobe
  0389D9FC. SDRAM pass 007F, DQM low 0, best low 3FFFC000 off 3EFFC10?.
- v0646: reads 022DCB01, other writes 03A1B19A, time and last strobe 039309A8, pass 0080.
- v0102 (early, t ≈ 10.1 s): data writes 00004B41 (already final), reads 002E?BD1, other writes
  004D??4A, runs logged 400, big runs 004, read runs 400, address now 20040000, time 0052??C0 µs
  (≈ 5.4 s), SDRAM pass 000B, DQM low 0, best low 05FFFA01 off 04FFFB0?. Audio time 05 s, polls 013D.
- Rates worked out from v0580 to v0640 (6.02 s of core time): reads ≈ 611 k/s, other writes
  ≈ 1.02 M/s. Data writes stay at 0x4B41 (19265 bytes) from the earliest snapshot on.
- The SDRAM error fields are yellow on a washed-out screen. Within one frame all eight fields show
  the same value, and that value changes every pass. Their low digits are often mid-update and
  unreadable, so take them as rough values only.

## Pages 1–2: write runs of 32+ bytes

Page 1 has 4 entries. Page 2 is empty: only the column header shows. This matches "big runs 004".

| # | K | address | bytes | D0 | CRC-32 | T (hex) | T ms |
|---|---|---|---|---|---|---|---|
| 000 | 0 | 00000000 | 001EAF | ED | 3F05C007 | 00000 | 0.000 |
| 001 | 0 | 10100000 | 000028 | 03 | 7B4EDA37 | 00003 | 3.072 |
| 002 | 0 | 111F8100 | 000080 | 00 | FCB64B27 | 00004 | 4.096 |
| 003 | 0 | 10170800 | 002500 | 00 | B1883CCD | 00008 | 8.192 |

(The earlier quick look read the 111F8100 CRC as FC864B27. The stacked images of page 1 and page 5
both show FCB64B27.)

## Page 3: read runs

All 20 rows shown (entries 000–013) are identical:

| # | K | address | bytes | D0 | CRC-32 | T (hex) | T ms |
|---|---|---|---|---|---|---|---|
| 000–013 | 1 | 20040000 | 000002 | 02 | 73EF707D | 0018D | 406.528 |

- The CRC solves to data `02 00`, so every read run returned 02 00.
- The address does not alternate: all 20 are at 20040000.
- All 20 have the same T (0x18D), so they all started within one 1.024 ms tick.

## Pages 4–7: all runs in order (entries 0x00–0x4F)

| # | K | address | bytes | D0 | CRC-32 | T (hex) | T ms | data (from CRC) |
|---|---|---|---|---|---|---|---|---|
| 000 | 0 | 00000000 | 001EAF | ED | 3F05C007 | 00000 | 0.000 | – |
| 001 | 0 | 10000034 | 000001 | 00 | D202EF8D | 00003 | 3.072 | 00 |
| 002 | 0 | 10100034 | 000003 | 00 | FF41D912 | 00003 | 3.072 | 00 00 00 |
| 003 | 0 | 10100000 | 000028 | 03 | 7B4EDA37 | 00003 | 3.072 | – |
| 004 | 0 | 1000806B | 000001 | 00 | D202EF8D | 00003 | 3.072 | 00 |
| 005 | 0 | 10008022 | 000002 | 8D | CFF4F4F9 | 00003 | 3.072 | 8D 00 |
| 006 | 0 | 10008060 | 000001 | 01 | A505DF1B | 00003 | 3.072 | 01 |
| 007 | 0 | 1000801E | 000003 | 2E | 14745DDB | 00003 | 3.072 | 2E EF 00 |
| 008 | 0 | 10008040 | 000004 | 10 | D591FBFE | 00003 | 3.072 | 10 00 10 02 |
| 009 | 0 | 10008088 | 000002 | 59 | C4AE95CE | 00003 | 3.072 | 59 02 |
| 00A | 0 | 10008067 | 000001 | 01 | A505DF1B | 00003 | 3.072 | 01 |
| 00B | 0 | 1000801A | 000002 | F0 | 5565F342 | 00003 | 3.072 | F0 00 |
| 00C | 0 | 10008056 | 000002 | 00 | AC6191DF | 00003 | 3.072 | 00 80 |
| 00D | 0 | 10008069 | 000001 | 00 | D202EF8D | 00003 | 3.072 | 00 |
| 00E | 0 | 10008016 | 000004 | 00 | C5F2400A | 00003 | 3.072 | 00 80 17 00 |
| 00F | 0 | 1000804E | 000002 | 00 | 41D912FF | 00003 | 3.072 | 00 00 |
| 010 | 0 | 1000802C | 000002 | 00 | 41D912FF | 00003 | 3.072 | 00 00 |
| 011 | 0 | 1000802A | 000001 | 00 | D202EF8D | 00003 | 3.072 | 00 |
| 012 | 0 | 1000804C | 000001 | 00 | D202EF8D | 00003 | 3.072 | 00 |
| 013 | 0 | 10008044 | 000004 | 03 | 157BF3CD | 00003 | 3.072 | 03 00 F2 00 |
| 014 | 0 | 10008050 | 000002 | 00 | AC6191DF | 00003 | 3.072 | 00 80 |
| 015 | 0 | 10008058 | 000002 | 00 | 41D912FF | 00003 | 3.072 | 00 00 |
| 016 | 0 | 10008028 | 000002 | E0 | 68A0D185 | 00003 | 3.072 | E0 01 |
| 017 | 0 | 10008061 | 000001 | 00 | D202EF8D | 00003 | 3.072 | 00 |
| 018 | 0 | 10008024 | 000004 | 00 | DE28B300 | 00003 | 3.072 | 00 00 1D 00 |
| 019 | 0 | 1000802E | 000002 | 00 | 41D912FF | 00003 | 3.072 | 00 00 |
| 01A | 0 | 1000802B | 000001 | 00 | D202EF8D | 00003 | 3.072 | 00 |
| 01B | 0 | 1000804D | 000001 | 00 | D202EF8D | 00003 | 3.072 | 00 |
| 01C | 0 | 1000804A | 000002 | 03 | 6AF4413C | 00003 | 3.072 | 03 00 |
| 01D | 0 | 10008048 | 000002 | E2 | 5A96B307 | 00003 | 3.072 | E2 01 |
| 01E | 0 | 1010002A | 000008 | F0 | 1D012520 | 00003 | 3.072 | – |
| 01F | 0 | 10100028 | 000002 | 05 | 3CAEE6BA | 00004 | 4.096 | 05 00 |
| 020 | 0 | 10008065 | 000002 | D0 | B7E6E776 | 00004 | 4.096 | D0 01 |
| 021 | 0 | 10100032 | 000001 | 08 | DCD967BF | 00004 | 4.096 | 08 |
| 022 | 0 | 10100040 | 000001 | 01 | A505DF1B | 00004 | 4.096 | 01 |
| 023 | 0 | 10008067 | 000001 | 00 | D202EF8D | 00004 | 4.096 | 00 |
| 024 | 0 | 1000F001 | 000002 | 03 | 1DF371AA | 00004 | 4.096 | 03 01 |
| 025 | 0 | 10008055 | 000001 | FF | FF000000 | 00004 | 4.096 | FF |
| 026 | 0 | 111F8100 | 000080 | 00 | FCB64B27 | 00004 | 4.096 | – |
| 027 | 0 | 10100041 | 000001 | 00 | D202EF8D | 00006 | 6.144 | 00 |
| 028 | 0 | 10000024 | 000001 | 00 | D202EF8D | 00006 | 6.144 | 00 |
| 029 | 0 | 1000D100 | 000002 | DF | 4779CB2F | 00006 | 6.144 | DF 00 |
| 02A | 0 | 1000D104 | 000002 | 13 | CD8ED04D | 00006 | 6.144 | 13 80 |
| 02B | 0 | 1000D108 | 000001 | 01 | A505DF1B | 00006 | 6.144 | 01 |
| 02C | 0 | 1000D10A | 000001 | 01 | A505DF1B | 00006 | 6.144 | 01 |
| 02D | 0 | 1000D122 | 000001 | 01 | A505DF1B | 00006 | 6.144 | 01 |
| 02E | 0 | 1000D125 | 000001 | 02 | 3C0C8EA1 | 00006 | 6.144 | 02 |
| 02F | 0 | 1000D128 | 000002 | 04 | 25B5D7FB | 00006 | 6.144 | 04 00 |
| 030 | 0 | 1000D126 | 000001 | 44 | A3B36A04 | 00006 | 6.144 | 44 |
| 031 | 0 | 1000D124 | 000001 | 09 | ABDE5729 | 00006 | 6.144 | 09 |
| 032 | 0 | 1000901B | 000001 | 00 | D202EF8D | 00006 | 6.144 | 00 |
| 033 | 0 | 10009017 | 000004 | 00 | 0C463091 | 00006 | 6.144 | 00 00 00 FF |
| 034 | 0 | 10009018 | 000003 | 00 | D243369F | 00006 | 6.144 | 00 00 FF |
| 035 | 0 | 10009018 | 000003 | 00 | D243369F | 00006 | 6.144 | 00 00 FF |
| 036 | 0 | 10009018 | 000003 | 00 | D243369F | 00006 | 6.144 | 00 00 FF |
| 037 | 0 | 10009018 | 000003 | 00 | D243369F | 00006 | 6.144 | 00 00 FF |
| 038 | 0 | 10009018 | 000003 | 00 | D243369F | 00006 | 6.144 | 00 00 FF |
| 039 | 0 | 10009018 | 000003 | 00 | D243369F | 00006 | 6.144 | 00 00 FF |
| 03A | 0 | 10009018 | 000003 | 00 | D243369F | 00006 | 6.144 | 00 00 FF |
| 03B | 0 | 10009018 | 000003 | 00 | D243369F | 00006 | 6.144 | 00 00 FF |
| 03C | 0 | 10009018 | 000003 | 00 | D243369F | 00006 | 6.144 | 00 00 FF |
| 03D | 0 | 10009018 | 000003 | 00 | D243369F | 00006 | 6.144 | 00 00 FF |
| 03E | 0 | 10009018 | 000003 | 00 | D243369F | 00006 | 6.144 | 00 00 FF |
| 03F | 0 | 10009018 | 000003 | 00 | D243369F | 00006 | 6.144 | 00 00 FF |
| 040 | 0 | 10009018 | 000003 | 00 | D243369F | 00006 | 6.144 | 00 00 FF |
| 041 | 0 | 10009018 | 000003 | 00 | D243369F | 00006 | 6.144 | 00 00 FF |
| 042 | 0 | 10009018 | 000003 | 00 | D243369F | 00006 | 6.144 | 00 00 FF |
| 043 | 0 | 10009018 | 000003 | 00 | D243369F | 00006 | 6.144 | 00 00 FF |
| 044 | 0 | 10009018 | 000003 | 00 | D243369F | 00006 | 6.144 | 00 00 FF |
| 045 | 0 | 10009018 | 000003 | 00 | D243369F | 00006 | 6.144 | 00 00 FF |
| 046 | 0 | 10009018 | 000003 | 00 | D243369F | 00006 | 6.144 | 00 00 FF |
| 047 | 0 | 10009018 | 000003 | 00 | D243369F | 00006 | 6.144 | 00 00 FF |
| 048 | 0 | 10009018 | 000003 | 00 | D243369F | 00006 | 6.144 | 00 00 FF |
| 049 | 0 | 10009018 | 000003 | 00 | D243369F | 00006 | 6.144 | 00 00 FF |
| 04A | 0 | 10009018 | 000003 | 00 | D243369F | 00006 | 6.144 | 00 00 FF |
| 04B | 0 | 10009018 | 000003 | 00 | D243369F | 00006 | 6.144 | 00 00 FF |
| 04C | 0 | 10009018 | 000003 | 00 | D243369F | 00006 | 6.144 | 00 00 FF |
| 04D | 0 | 10009018 | 000003 | 00 | D243369F | 00006 | 6.144 | 00 00 FF |
| 04E | 0 | 10009018 | 000003 | 00 | D243369F | 00006 | 6.144 | 00 00 FF |
| 04F | 0 | 10009018 | 000003 | 00 | D243369F | 00006 | 6.144 | 00 00 FF |

## Observations

- All 80 entries are K=0 write runs with T ≤ 6. There are no read runs and no K=2 or K=3 entries
  among the first 80. The 2-byte read runs at 20040000 (T = 0x18D) appear only on the read-run page.
- T values are only 0, 3, 4 and 6. Nothing was logged at T=1, 2 or 5.
- The fourth big run (10170800, 0x2500 bytes, T=8) is not among entries 0x00–0x4F, so it comes
  after entry 0x4F. That means more of the 10009018 repeats, or other writes, follow entry 0x4F.
- 28 consecutive identical runs (entries 0x34–0x4F) write `00 00 FF` to 10009018–1000901A. Just
  before them, entry 0x33 writes `00 00 00 FF` to 10009017–1000901A. The repetition probably goes
  on past entry 0x4F.
- The 1000Dxxx writes (entries 0x29–0x31) are not in address order: D100, D104, D108, D10A, D122,
  D125, D128, D126, D124.
- Some addresses are written twice: 10008067 (entry 0x0A `01`, entry 0x23 `00`). Runs at 10008028,
  1000802B and 1000802E overlap or sit next to 10008024 (4 bytes) and 1000802A/1000802C.
- 1000806B is a 1-byte write in the 100080xx range above 0x7F, alongside 10008088 (2 bytes).
- Entries 0–0x4F add up to 0x2008 bytes. Adding the 0x2500-byte big run at 10170800 gives 0x4508.
  The "data writes" total is 0x4B41, so 0x639 (1593) bytes are in runs after entry 0x4F that the
  pages don't show (if "data writes" counts exactly these bytes).
- Both run logs are full: runs logged 400 and read runs 400. Big runs is 004.

## Reading (decode in `notes/pic-link.md`, "Status 0x2004_0000")

- Sequence: set-up writes to the `0x1000_xxxx`/`0x1010_xxxx` registers and the blocks at
  `0x0000_0000` (0x1EAF bytes), `0x111F_8100` (0x80) and `0x1017_0800` (0x2500), the `00 00 FF`
  write to `0x1000_9018` repeated (0x639 bytes unaccounted for ≈ 531 more of these 3-byte
  writes), then from T = 406.5 ms only the status poll. None of the shown writes touches the
  video-PLL reconfiguration block (`0x1000_00C4`, `0x1000_05xx`).
- The poll: address bytes, A=3 latch, two reads (`0x2004_0000`, `0x2004_0001`); ~305 000 polls/s
  ("reads" 611 k/s, "other writes" 1.02 M/s ≈ 3.3 per poll: some address bytes + A=3). Our answer
  was `02 00`. The 1024-entry logs filled with poll runs within milliseconds, which is why the
  entries after 0x4F (and any A=3 entries) never showed: hwtest v2 merges identical runs and
  doesn't log A=3 latches.
- The stock core answers the same byte at both addresses: 0x03 or 0x02 by the decode (bit 1 =
  video PLL locked; bit 0 is ambiguous), so v1 differed from the stock core at least in the
  second byte. hwtest v2 answers 0x03 and steps through 0x02, 0x01, 0x00, 0xFF while the PIC
  keeps polling.
- The file (`build/test-chord.spc`, CRC 68D8FB8F) never came: none of the four big-run CRCs
  matches it or any part of it.
