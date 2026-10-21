# PIC32 ↔ FPGA link (bank 4A), from spc.cor

Decoded from `build/spc.bt` with `tools/netlist.py` (gate-level netlist + simulation of the
extracted logic) and checked against the bus capture `notes/buslog-2026-10-21/`. Oct 2026.
Confidence per claim: **[confirmed]** (two independent lines of evidence), **[likely]** (clean
decode, one line of evidence), **[guess]**.

## Summary

An asynchronous 8-bit parallel slave port, PIC32 PMP style (master mode 2: separate active-low
read and write strobes, 3 address lines), sampled by the FPGA at 42.686 MHz:

- `A[2:0]` = AB20 AA20 AA19, `/WR` = U22, `/RD` = U21, `D[7:0]` = AB21 AB22 AA22 Y21 Y22 W21 W22
  V21 (bit 7 … 0).
- Behind it, a 32-bit address register (written a byte at a time) and a data port with
  post-increment: registers 0, 1, 4, 5 = address bytes 0–3, register 2 = data, register 3 =
  "latch address and increment" (read prefetch).
- Writes to register 2 are posted to the core's memory/register space at the 32-bit address;
  reads return a byte selected by the last latched address (SDRAM, internal registers, or 0).
- The capture contains only writes (U21 never went low). In true bit order they are a register
  set-up sequence at `0x1000_xxxx`/`0x1010_xxxx`/`0x111F_8100` followed by repeated writes to
  `0x1000_9018`/`0x1000_D218` whose data runs FF … FF, EE, DD, CC, … 11, 00. Nothing in it is the
  .spc file yet; the PIC wasn't stuck waiting on a read.

## Pins

| pin | role | evidence | conf |
|---|---|---|---|
| AB20 | A2 | address byte select (below) | [likely] |
| AA20 | A1 | " | [likely] |
| AA19 | A0 | " | [likely] |
| U22 | /WR, active low | low from idle → write path; latches the data register from the bus | [likely] |
| U21 | /RD, active low | low (with U22 high) → read path, the only path that sets OE | [likely] |
| V21 W22 W21 Y22 Y21 AA22 AB22 AB21 | D0 … D7 | address-counter carry chain + the EE…00 run in the capture | [confirmed] |

- **Data bit order is not the one the logger assumed.** buslog's DD byte (AB21 = bit 7 … V21 =
  bit 0) maps to the true byte by swapping bits 1↔4 and 5↔6 (`hw/buslog/buslog.v` order
  AB21 AA22 AB22 W22 Y22 W21 Y21 V21 vs true AB21 AB22 AA22 Y21 Y22 W21 W22 V21).
  Derivation: the four address bytes are loaded from the data pins into one 32-bit up-counter
  (`LAB.024.017` ALM0 top = bit 0, chain continues into `LAB.024.016` via TTO_DIS); all four
  bytes give the same pin→bit order. Check: the capture's tail data FC AF AC DB D8 8B 88 77 74
  27 24 53 50 03 00 becomes EE DD CC BB AA 99 88 77 66 55 44 33 22 11 00 in this order.
- Each input has a **single** synchroniser FF on the 42.686 MHz clock [confirmed]: AB20
  `MLAB.037.002.6:FFB1`, AA20 `LAB.025.017.1:FFB1`, AA19 `LAB.025.017.8:FFT1`, U21
  `LAB.025.017.7:FFT1`, U22 `LAB.050.001.6:FFB1`, data V21 `MLAB.023.016.8:FFT1` (through a
  buffer LUT), W22 `MLAB.028.017.4:FFB1`, W21 `MLAB.028.017.8:FFB1`, Y22 `LAB.025.017.6:FFB1`,
  Y21 `LAB.025.017.7:FFB1`, AA22 `LAB.026.013.7:FFT1`, AB22 `LAB.024.013.2:FFB1`, AB21
  `LAB.025.013.0:FFB1`. AB21's is on the LAB's CLK1, the rest CLK0; same clock source.
- Output: data FFs in `LAB.031.013` (D = registered read mux, loaded when `021.017.9.T` is
  high, see below); one OE FF `LAB.021.017.0:FFT0` drives all 8 OEIN.0 (inverter set, as on
  every output pin in spc). Pin driven when the FF is 1 [likely: unrouted inputs read as 1 and
  always-on outputs have OEIN.0 unrouted with the same inverter].
- U22 and T12 were not logged by buslog (only shown live). T12 → `LAB.029.003.2:FFB0` (= ~T12)
  → `LAB.024.015.0:E1`, not part of this interface as far as traced. P14 is an output driven
  from a counter/divider in the `CMUXHG.000.022.3` clock domain (dynamic clock switchover); not
  part of the link logic. Purpose of both unknown.

## Clock

All link logic runs on `CMUXVG.025.045.1` = `INPUT_SEL 0e` = PLLIN 6 = **FPLL.054.037 C6,
42.686 MHz** (23.4 ns) [confirmed: pllinfo wiring + notes/pll.md]. Minimum strobe ≈ 3–4 clocks
(sync FF + FSM step + action), i.e. ≥ ~100 ns to be safe [likely].

## Registers (A2..A0)

| A | write | read |
|---|---|---|
| 0 | ADDR[7:0] ← D | same byte for every A: the read mux (below) |
| 1 | ADDR[15:8] ← D | |
| 2 | DATA ← D; post request {ADDR, DATA}; ADDR += 1 (32-bit) | |
| 3 | latch ADDR into the request regs, post request, ADDR += 1 (no data) | |
| 4 | ADDR[23:16] ← D | |
| 5 | ADDR[31:24] ← D | |
| 6, 7 | request flag only, nothing loaded [guess] | |

[likely] for 0–5 (simulated end to end: writes to 0,1,4,5,2,2,3 give ADDR 0x78561234 → …35 →
…36 → …37 with DATA = last byte). The meaning of a "request" with A=3, and how reads use it, is
[guess]: most plausibly "start a read at ADDR" so that a following read of the data port
returns that byte.

- Address register: `M023.017` (bits 0–7), `024.017.4–7` (8–15), `024.016.0/1/7/8` (16–23),
  `024.016.2–5` (24–31); sync-load from the data synchronisers when not incrementing.
- Write data register: `LAB.025.016` (en `021.017.4.B` = FSM write state ∧ A=2), then
  `025.016.6.FFT0`… → fanned out to many register enables, an M10K data port
  (`M10K.022.022:DATAAIN.12`) and other clock domains.
- Request latch (en `021.017.1.B`): copies all 32 address bits (`019.017.x`, `021.018.x`,
  `024.019.x`, `M023.017.x`, `M023.019.x` …), then a second stage loaded by the memory-side
  FSM (`020.017.3.B`/`.4.B`).

## Transaction state machine

Five state bits in `MLAB.028.017` (q0 = ALM0 FFB0/FFB1, q1 = ALM1 FFT0/FFT1, q4 = ALM4
FFT0/FFT1, q7 = ALM7 FFT0/FFT1, q9 = ALM9 FFT1; the pairs are duplicates), plus `rdy` =
`M018.018.9.B` = "memory-side FSM (`M018.018/019`, `019.018/019`) in its idle state".
Simulated with `netlist.Sim` (state = q0 q1 q4 q7 q9, rdy = 1):

| state | condition | next | action |
|---|---|---|---|
| 00000 idle | /RD=1 /WR=1 | 00000 | OE ← 0, data-out regs track the read mux |
| 00000 | /WR=0 | 00011 | |
| 00000 | /RD=0, /WR=1 | 01100 | |
| 00011 | A=0/1/4/5 | 10010 | load ADDR byte 0/1/2/3 |
| 00011 | A=2 | 10010 | DATA ← D, latch request, ADDR += 1 |
| 00011 | A=3 | 00100 | |
| 00011 | A=6/7 | 10010 | – |
| 00100 | – | 00001 (00101 if /RD=0) | latch request, ADDR += 1 |
| 10010 | /WR=0 | 10010 | wait for strobe release |
| 10010 | /WR=1 | 00000 | |
| 01100 | /RD still 0 | 00001 | OE ← 1, data-out regs freeze |
| 01100 | /RD already 1 | 00001 | OE ← 1, latch request, ADDR += 1 |
| 00001, 00101, 10000 | – | (stay) | wait |
| any | rdy = 0 | 00000 | |

All writes also raise `021.017.8.FFT1` (one-clock request to the memory FSM via
`020.017.1.FFB0`). [likely] for the write rows; the read rows and the waits are [guess]: several
states only leave when `rdy` drops, i.e. they depend on the memory FSM, which I couldn't
simulate meaningfully (its counters didn't run in my model). A read: OE goes high ~2 clocks after
the synchronised /RD edge, together with the data-out load, and stays high until the FSM is
back in 00000. If /RD is still low then, the FSM re-enters the read path. A replacement core
doesn't need to copy any of this; the PIC only sees the strobe/OE timing.

Full equations: `python3 tools/netlist.py build/spc.bt --back 2 --fwd 0 MLAB.028.017.0:FFB0
MLAB.028.017.1:FFT0 MLAB.028.017.4:FFT0 MLAB.028.017.7:FFT0 MLAB.028.017.9:FFT1 LAB.021.017.0:FFT0`.

## Read data (latched-address map)

The data-out FFs load from registered muxes (`025.018.x`, `026.017.x`, `025.019.4`) whose
selects decode the second-stage latched address. Sensitivity analysis over the decoded logic
(`~/scratch/linkre/readmap.py`) [likely for the region split, names only]:

| latched address | read byte |
|---|---|
| `0x0?xx_xxxx`, bit 24 = 0, bits 31–28 = 0 | regs `026.017.7.FFB0`, `025.015.6.FFB0`, …; bit 6 = 1, bit 1 = 0 |
| bit 24 = 1, bits 31–28 = 0 (`0x01xx_xxxx`) | bits 7–2 captured from top-bank pins (A8, A12, B10, B11, HMC DQ) on the falling clock edge: the x16 SDRAM's DQ?; bits 1–0 read 0 here (incomplete trace?) |
| `0x2xx0_0000` … by bits 19–16 | internal status regs: `0x2000_0000`, `0x2001_0000`, `0x2002_0000`, `0x2003_0000` full bytes from `025.015.x`/`026.017.x`; `0x2004_0000` bit 1 includes `M013.020.5.FFB0` (= FPLL.000.037 LOCK0, synchronised), bit 0 `014.016.2.FFT0`; `0x2008_0000` = `0000_00x1`; `0x2009_0000` bits 6, 5, 2 = 1 |
| anything with bit 28, 30 or 31 set (`0x1xxx_xxxx` …) | 0x00 |

Which status bit the PIC polls (if any) is not known; nothing in the capture reads.

## The capture, decoded

Logger events `S:DD+TT`. S = {AB20 AA20 AA19 U21} = {A2 A1 A0 /RD}; the cycle 3 → 9 → B → 5 → 1
is A = 1, 4, 5, 2, 0 with /RD = 1 throughout (F and B-for-9 are skew between address bits).
The write strobes are invisible (U22 not logged). DD at an event is the byte left on the bus by
the phase that just ended (the PIC keeps driving its last write), and TT is that phase's length.
So one cycle = write ADDR[7:0] (A=0), ADDR[15:8] (A=1), ADDR[23:16] (A=4), ADDR[31:24] (A=5),
then one or more DATA writes (A=2, the long phase). [likely]

Page 1, rows 1–30 (event index, true bit order; "data" = last byte of the A=2 phase):

| events | address | data | A=2 phase |
|---|---|---|---|
| 0 | – | first event after ≥ 220 µs; S before it was 0 (all four low, i.e. /RD low until the PIC set up its port) | |
| 1–6 | `0x1000_00??` (byte 0 written before the first event) | 00 | short |
| 7–12 | `0x1010_0034` | 10, then 00 | short, ~1 µs |
| 13–17 | `0x1010_0000` | 00 | 21 µs: a burst of writes |
| 18–216 | `0x1000_80xx` (xx = 6B 22 60 1E 40 88 1A 69 18 4E 2C 2A 4C 44 46 50 58 28 61 24 26 2E 2B 4D 4A 48 65 67 55), `0x1000_C2{67,56,16}`, `0x1010_00{2A,28,32,40}`, `0x1000_F00{1,2}`, `0x1001_3000` | mostly 00/01/02/80, one 08, one 03 | 0–5 µs each |
| 225 | `0x111F_8100` | FF | ≥ 220 µs: long block write |
| 230–281 | `0x1010_0041`, `0x1000_0024`, `0x1000_D1{00,04,08,0A,22,25,28,26,24}` | 00 80 01 01 01 02 00 44 09 | short |
| 286–292 | `0x1000_901B`, `0x1000_9017` | 00 | |
| 297– | `0x1000_9018` (occasionally `0x1000_D218`) | FF | ~1 µs per cycle, repeated |

Repeating cycle (page 1 row 30 onward): `1:FF+01 3:0A+00 9:82+00 B:00+00 5:02+00` = ADDR ←
18, 90, 00, 10 → `0x1000_9018`, one ~1 µs data phase ending with FF. ~50 cycles of FF, then
(page 2) EE DD CC BB AA 99 88 77 66 55 44 33 22 11 00, alternating between `0x1000_9018` and
`0x1000_D218`, then 00 to the end of the capture (event 1023, 0.5–1.5 ms after the first; TT is a lower
bound).

Reading: the PIC first sets up registers in the core (`0x1000_xxxx`/`0x1010_xxxx`), writes a
long block at `0x111F_8100`, then steps a value from FF down to 00 in two registers (a fade or
volume ramp?). The stock core reads 0x00 at all these addresses (bits 28 set), so even a read
would not have mattered. Nothing here is the .spc file (no long sequential stream of varied
data), so the file probably comes later than the 1024-event window. [guess]

## What a replacement core must implement

1. The slave port above: single-FF synchronisers are enough at ≥ 40 MHz; act on the
   synchronised falling edge of /WR (load the address byte selected by A, or for A=2 store
   {ADDR, D} and increment ADDR); for /RD low (and /WR high) drive D and OE until /RD
   rises. Never drive while /RD is high. [likely]
2. A sink for the writes: at minimum a log or memory keyed by the 32-bit address, so we can see
   where the file goes (expect a long A=2 burst into one region).
3. Reads: until the PIC is seen reading, return the stock core's constants for `0x2008_0000`
   (`0x01` | bit 1) and `0x2009_0000` (bits 6, 5, 2 set) and 0x00 elsewhere. Unknown whether
   the PIC reads anything before sending a file.

**Next experiment** (buslog v2): log U22 edges as well, decode transactions in the FPGA
({ADDR, D, R/W} per strobe instead of raw S changes), and keep only address changes plus a byte
count per burst, so the window covers the whole session up to and including the file transfer.
Also drive OE on /RD with a constant (e.g. 0xA5) to see whether and when the PIC reads.

## Open questions

- U22 = /WR is from the logic only; never observed. Strobe widths/setup times unknown.
- What A=3 is for, and the exact read/prefetch timing (depends on the memory FSM's `rdy`).
- Write decode: where each `0x1000_xxxx`/`0x1010_xxxx`/`0x111F_xxxx` write lands (register
  enables `M018.016.1.T`, `024.020.x`, `024.022.x`, `M023.020.3.T` … decode a third address
  stage `021.019.x`, not traced).
- Read region `0x01xx_xxxx` bits 1–0 and the meaning of the `0x2xxx_xxxx` status bits.
- Whether the PIC waits on P14 or another pin.

## Tool (`tools/netlist.py`)

`netlist.py build/spc.bt [--back N] [--fwd N] [--names F] [--raw] SEED...` prints every LUT
half as a minimised equation and every FF with D/clock/enable/sync load/sync clear. As a
library: `Design.eval_comb`, `eval_arith`, `reg_next` and `Sim` (cycle simulation of a register
set). The alias file used here is `~/scratch/linkre/names.txt` (throwaway).

Conventions and the evidence for each (see the module docstring for the exact rules):

- LUT `f(s) = ~M[~s]`, unrouted inputs = 1: nextpnr's encoder; the decode reproduces all 201
  LUT cells of nextpnr-built `plltest` (L5, L6, LAB and MLAB). Quartus masks like
  `…00000001` with two routed pins only make sense if unrouted pins index as 0.
- PKREG mapping (FFT0↔TPKREG1, FFT1↔TPKREG0, FFB0↔BPKREG1, FFB1↔BPKREG0): nextpnr placement
  of plltest, plus in spc.cor every FF with its bit set has the selected E/F pin routed
  (721/721, 521/521, 996/996, 489/489).
- Clock/aclr groups {FFT0, FFB1} = T, {FFT1, FFB0} = B: in spc.cor every register-mode FFT1/FFB0
  output has BCLK_SEL set and every FFT0/FFB1 TCLK_SEL. Sync-load/clear enables per half from the
  same kind of count.
- Enables EN0/1/2 = DATAIN.2/3/0, NINV=0 active high: whenever ENn_EN=1 in spc.cor the matching
  DATAIN is routed (467, 409, 330 LABs); matches nextpnr.
- TMODE/BMODE as `<TA>_<TS>` with TF/BF = the half's own F: mistral's ALM schematic (TMODE muxes
  D/TF/E0 into TA/TS). Own vs other half's F decided by spc.cor: "other half" gives 6
  combinational self-loops in F_0/F_1 LUTs, "own" none; with "own" for D_F the link FSM settles
  for every constant input, with "other" it oscillates. Not checked against hardware.
- In 6-LUT mode the upper 32 bits are the bottom LUT addressed with the bottom half's inputs
  (D at bit 2, BA at bit 3): matches nextpnr's C/D swap and Quartus D_E/E_1 ALMs.
- Arithmetic: sum = LUT0 + ~LUT1 + cin (yosys `MISTRAL_ALUT_ARITH`), checked against nextpnr
  cells. Chain-start carry-in assumed 0: correct for the link address counter (bit 0 gets +1,
  the rest +0) but it makes one Quartus counter (`020.015`) look stuck, so something about
  chain starts in F_0 mode is still wrong.
- Not modelled: MLAB RAM mode, SHARE chains, async clears (only flagged), DSP/M10K blocks
  (leaves).
