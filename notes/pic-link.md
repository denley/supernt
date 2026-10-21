# PIC32 ↔ FPGA link (bank 4A), from spc.cor

Decoded from `build/spc.bt` with `tools/netlist.py` (gate-level netlist + simulation of the
extracted logic) and checked against the bus capture `notes/buslog-2026-10-21/`. Oct 2026.
Re-derived after two decode fixes to the tool ("Tool"): address register, register map and
data bit order unchanged; FSM table, read map and A=3 changed (marked "Changed").
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
  Re-checked after the tool fixes by simulating single-pin writes to A=0/1/4/5 from the pins:
  V21 W22 W21 Y22 Y21 AA22 AB22 AB21 land in ADDR bits 0–7 (8–15, 16–23, 24–31).
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
| 3 | latch ADDR into the request regs, ADDR += 1 (no data, no request pulse; changed) | |
| 4 | ADDR[23:16] ← D | |
| 5 | ADDR[31:24] ← D | |
| 6, 7 | nothing loaded, no request (changed: was "request flag only" [guess]) | |

[likely] for 0–7. Simulated end to end from the pins (synchronisers, FSM, memory-side `rdy`
all simulated; re-checked after the tool fixes): writes to 0,1,4,5,2,2,3 give ADDR
0x78561234 → …35 → …36 → …37, writes to 6/7 change nothing. A=3 and the end of every read
copy ADDR into the request latch that selects the read data, so A=3 is most plausibly "set up
the address for the next read" (prefetch) [likely]; only A=2 sends a request to the memory
side.

- Address register: `M023.017` (bits 0–7), `024.017.4–7` (8–15), `024.016.0/1/7/8` (16–23),
  `024.016.2–5` (24–31); sync-load from the data synchronisers when not incrementing. Bit
  order (incrementer carry chain from `LAB.024.017.0` T into `LAB.024.016`): `M023.017.2.FFT0`
  `.0.FFT0` `.5.FFB0` `.7.FFB0` `.3.FFB0` `.4.FFB0` `.3.FFT0` `.4.FFT0`, `024.017.4.FFT1`
  `.4.FFB1` … `.7.FFB1`, `024.016.8.FFB0` `.7.FFT0` `.8.FFT1` `.7.FFB1` `.0.FFT1` `.0.FFB1`
  … `.5.FFB0`.
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

**Changed (re-decoded with the corrected tool, see "Tool"):** the earlier table had dead-end
wait states (00001, 10000) that only left when `rdy` dropped, read rows marked [guess], and
"all writes raise the request". Those came from the F-pin misreading of the state LUTs (most
are `D_F`/`F_0` mode, i.e. they read their own register through the feedback line). Now the
whole link, including the memory-side FSM that drives `rdy`, simulates from the pins with
nothing forced (`~/scratch/netfix/link.py`, `flink.py`, `fsmtab.py`, throwaway; 567 registers
on the 42.686 MHz clock, inputs = the 13 link pins). The memory side holds `rdy` = 0 for
65 985 clocks (1.55 ms, a 16-bit power-on counter `026.020`) after configuration, then idles
with `rdy` = 1; no transaction below drops it (other clock domains idle). Table (state = q0 q1
q4 q7 q9, `rdy` = 1; the same table comes out of the exhaustive 32 states × 32 inputs
enumeration and of the transaction runs):

| state | condition | next | action |
|---|---|---|---|
| 00000 idle | /RD=1 /WR=1 | 00000 | OE ← 0, data-out regs track the read mux |
| 00000 | /WR=0 | 00011 | |
| 00000 | /RD=0, /WR=1 | 01100 | |
| 00011 | A=0/1/4/5 | 10010 | load ADDR byte 0/1/2/3 |
| 00011 | A=2 | 10010 | DATA ← D, latch request, ADDR += 1; next clock a one-clock request `021.017.8.FFT1` → `020.017.1.FFB0` |
| 00011 | A=3 | 00100 | |
| 00011 | A=6/7 | 10010 | – |
| 00100 | – | 00101 | latch request, ADDR += 1 (no request pulse) |
| 00101 | – | 10100 | |
| 10010, 10100 | /WR=0 | (stay) | wait for strobe release |
| 10010, 10100 | /WR=1 | 00000 | |
| 01100 | /RD=0 | 01100 | OE ← 1 (first clock); data-out regs keep tracking the read mux |
| 01100 | /RD=1 | 01101 | latch request, ADDR += 1 |
| 01101 | – | 00000 | OE ← 0 |
| any | rdy = 0 | 00000 | |

[likely] for all rows (one clean decode, two consistent simulations; not checked on
hardware). Only A=2 writes send the request pulse to the memory side; A=0/1/4/5/6/7 writes, A=3
and reads don't. Timing from the pin edges at 42.686 MHz: a write is acted on 2 clocks after
/WR falls; on a read OE rises 3 clocks (~70 ns) after /RD falls and falls 3 clocks after /RD
rises, so **the FPGA keeps driving the bus for ~70 ns after /RD goes high**. The byte driven is
the read mux output for the address latched by the previous read, A=2 write or A=3 (the
latch happens when a read ends), which fits "A=3 = latch ADDR for the next read" (prefetch).
A replacement core doesn't need to copy any of this; the PIC only sees the strobe/OE timing.

Full equations: `python3 tools/netlist.py build/spc.bt --back 2 --fwd 0 MLAB.028.017.0:FFB0
MLAB.028.017.1:FFT0 MLAB.028.017.4:FFT0 MLAB.028.017.7:FFT0 MLAB.028.017.9:FFT1 LAB.021.017.0:FFT0`.

## Read data (latched-address map)

The data-out FFs load from registered muxes (`025.018.x`, `026.017.x`, `025.019.4`) whose
selects decode the second-stage latched address. Sensitivity analysis over the decoded logic
(`~/scratch/linkre/readmap.py`, re-run with the corrected tool) [likely for the region split,
names only]:

| latched address | read byte |
|---|---|
| `0x0?xx_xxxx`, bit 24 = 0, bits 31–28 = 0 | bits 7…0 = regs `026.017.9.FFB1` `026.017.2.FFT1` `026.017.3.FFB1` `026.017.4.FFB1` `025.018.0.FFT1` `025.018.4.FFB1` `025.019.9.FFT1` `025.019.1.FFB1` |
| bit 24 = 1, bits 31–28 = 0 (`0x01xx_xxxx`) | the eight open-drain pins read back, bit 7…0 = B11 B12 C16 A12 A8 A9 B10 A10 (`notes/controllers.md`): IOE input register (`DATAIN.3`), then a fabric FF on `CMUXVG.021.000.3` (148.5 MHz, rising edge, enable `026.041.6.FFT1`), then the link clock |
| `0x2xx0_0000` … by bits 19–16 | internal status regs: `0x2000_0000`, `0x2001_0000`, `0x2002_0000` full bytes and `0x2003_0000` bits 2–0 from `025.015.x`/`025.018.x`/`026.017.x`; `0x2004_0000` bit 1 includes `M013.020.5.FFB0` (= FPLL.000.037 LOCK0, synchronised), bit 0 `014.016.2.FFT0`; `0x2006_0000` bit 3 `025.018.7.FFT1`, bit 1 as `0x2004`; `0x2008_0000` bits 1–0 `025.019.0.FFT1` `025.019.1.FFT1`; `0x2009_0000` full byte from `026.017.x`/`025.018.x`/`025.015.6.FFB1` |
| anything with bit 28, 30 or 31 set (`0x1xxx_xxxx` …) | 0x00 |

**Changed:** the earlier table had constant bits (region `0x0?` bit 6 = 1 and bit 1 = 0;
`0x2002` bit 0 = 1; `0x2008_0000` = `0000_00x1`; `0x2009_0000` bits 6, 5, 2 = 1). They were
artefacts of reading an unrouted F pin (= 1) where the LUT really reads its own register
through the feedback line; all of them are registers. The `0x01xx_xxxx` row said "falling
clock edge, x16 SDRAM DQ?, bits 1–0 read 0": the falling edge was the clock-select misreading,
and bits 1–0 (A9, B10, A10) were missed because the tool ignored `DATAIN.3` and HMC-bypass
routes without inverter lines.

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
   rises. Never drive while /RD is high. [likely] (The stock core releases OE only ~70 ns
   after /RD rises, see the FSM section; releasing sooner is safer and can't hurt the PIC.)
2. A sink for the writes: at minimum a log or memory keyed by the 32-bit address, so we can see
   where the file goes (expect a long A=2 burst into one region).
3. Reads: until the PIC is seen reading, return 0x00 (or a recognisable pattern) and log the
   read addresses. **Changed:** this used to say "return the stock core's constants for
   `0x2008_0000`/`0x2009_0000`", but those constants were a decode artefact; the stock status
   bytes are registers whose contents aren't decoded. Unknown whether the PIC reads anything
   before sending a file.

**Next experiment** (buslog v2): log U22 edges as well, decode transactions in the FPGA
({ADDR, D, R/W} per strobe instead of raw S changes), and keep only address changes plus a byte
count per burst, so the window covers the whole session up to and including the file transfer.
Also drive OE on /RD with a constant (e.g. 0xA5) to see whether and when the PIC reads.

## Open questions

- U22 = /WR is from the logic only; never observed. Strobe widths/setup times unknown.
- A=3 and read timing are now simulated (FSM section); what the memory side does with the
  latched read address (it gets no request pulse) and when `rdy` drops in real operation
  (with the SDRAM/video domains running) is not.
- Write decode: where each `0x1000_xxxx`/`0x1010_xxxx`/`0x111F_xxxx` write lands (register
  enables `M018.016.1.T`, `024.020.x`, `024.022.x`, `M023.020.3.T` … decode a third address
  stage `021.019.x`, not traced).
- What the open-drain group read back at `0x01xx_xxxx` is for, and the meaning of the
  `0x2xxx_xxxx` status registers.
- Whether the PIC waits on P14 or another pin.

## Tool (`tools/netlist.py`)

`netlist.py build/spc.bt [--back N] [--fwd N] [--names F] [--raw] [--hmc F] SEED...` prints
every LUT half as a minimised equation and every FF with D/clock/enable/sync load/sync clear.
Seeds: pins, ports, registers (`LAB.x.y.a:FFT0`) or comb halves (`LAB.x.y.a:T`/`:B`). As a
library: `Design.eval_comb`, `eval_arith`, `reg_next`, `reg()` (now also `clk_sig`/`clk_inv`)
and `Sim` (cycle simulation of a register set). The alias file used here is
`~/scratch/linkre/names.txt` (throwaway).

**Changed (Oct 2026, second pass):** two conventions were wrong and are fixed (register
feedback in F modes; LAB clock select vs inversion), plus pin seeds now follow `DATAIN.3` and
HMC-bypass routes. The link conclusions above were re-derived with the fixed tool; what moved
is marked "Changed" in each section. Experiment switches: `Design.FEEDBACK` and
`Design.CLK_SWAP` (set False for the old readings).

Conventions and the evidence for each (see the module docstring for the exact rules):

- LUT `f(s) = ~M[~s]`, unrouted inputs = 1: nextpnr's encoder. Checked cell by cell against
  three nextpnr-built designs whose netlists we know (`~/scratch/netfix/npcheck.py`, using the
  routed JSON, with constant and inverter pin states nextpnr folds taken from the yosys JSON):
  every comb cell (ALUT2–6, BUF, NOT, CONST, and sum and carry-out of every ALUT_ARITH) for
  every input combination, every FF's next-state function, every clock net. `plltest` 659
  comb cells + 187 FFs, `buslog` 432 + 164 (including M10K read ports), `vtest` 314 + 60:
  100 %. (The earlier check covered plltest's 201 non-arith LUT cells.) Quartus masks like
  `…00000001` with two routed pins only make sense if unrouted pins index as 0.
- PKREG mapping (FFT0↔TPKREG1, FFT1↔TPKREG0, FFB0↔BPKREG1, FFB1↔BPKREG0): nextpnr placement
  of plltest, plus in spc.cor every FF with its bit set has the selected E/F pin routed
  (721/721, 521/521, 996/996, 489/489).
- Clock/aclr groups {FFT0, FFB1} = T, {FFT1, FFB0} = B: in spc.cor every register-mode FFT1/FFB0
  output has BCLK_SEL set and every FFT0/FFB1 TCLK_SEL. Sync-load/clear enables per half from the
  same kind of count.
- Enables EN0/1/2 = DATAIN.2/3/0, NINV=0 active high: whenever ENn_EN=1 in spc.cor the matching
  DATAIN is routed (467, 409, 330 LABs); matches nextpnr.
- **F modes read the register feedback line (changed).** TMODE/BMODE are `<TA>_<TS>`; in
  `F_0`/`F_1` the LUT's TA/BA input and in `D_F`/`C_F` the 6-LUT select is TF/BF, and TF/BF
  are the outputs of the `T_FEEDBACK_SEL`/`B_FEEDBACK_SEL` muxes, i.e. the ALM's own FFT0
  (sel 0) or FFT1 (sel 1), FFB0/FFB1 for the bottom, not the F0/F1 pins (bit 4 is still the
  F pin). Evidence: mistral's ALM schematic (`~/src/vendor/mistral/docs/lab-cell.pdf`) draws
  exactly this (the feedback muxes pick between the two FFs of a half and wire to the
  TMODE/BMODE TF/BF inputs). spc.cor: in the 1829 F-mode halves the FF picked by the select
  bit is always clocked (sel 0 → FF?0, sel 1 → FF?1; the same FF of the other half only
  953/1829), no F-mode half lacks a clocked FF, and the select bit is never set outside F
  modes. Polarity (indexed like a routed pin, `~Q`): every counter that uses it becomes a
  counter (the opposite polarity turns each toggle bit into a hold). The `020.015` counter
  that looked stuck is a free-running modulo-42 down-counter (41 … 0, ≈1.016 MHz tick for
  the memory-side FSM); the SDRAM init counter, the poller's power-on counter and the link
  FSM's hold terms work the same way. nextpnr never uses F modes (it writes E_0/E_1 or the
  6-LUT defaults), so there is no nextpnr check of this. The earlier "own vs other half's F
  pin" question (decided by self-loop counts) is moot. [confirmed]
- In 6-LUT mode the upper 32 bits are the bottom LUT addressed with the bottom half's inputs
  (D at bit 2, BA at bit 3): matches nextpnr's C/D swap and Quartus D_E/E_1 ALMs.
- Arithmetic: sum = LUT0 + ~LUT1 + cin (yosys `MISTRAL_ALUT_ARITH`), checked against every
  nextpnr arith cell (sum and carry-out). Chain-start carry-in 0: right for every chain
  checked; the counter that contradicted it was the F-mode bug above.
- **LAB clocks: mistral's `CLKn_INV` / `CLKn_SEL` are swapped (changed).** The bit mistral
  calls `CLKn_INV` selects clkb (CLKIN.1, or DATAIN.1 with `CLKB_SEL DIN1`/MLAB `GIN3`) instead
  of clka (CLKIN.0, or DATAIN.0 with `CLKA_SEL DIN0`/`GIN2`); `CLKn_SEL CLKB` inverts. Evidence
  (spc.cor, 1898 used LAB clocks, `~/scratch/netfix/clkcheck.py`): with the swap every clock
  comes from a routed input; with mistral's names 397 don't (364 in LABs that route only
  CLKIN.1). The 12 clocks with `CLKn_SEL CLKB` are all the 3.072 MHz I2S/ADC bit clock
  (`CMUXVG.025.045.2`), the one place inverted clocks are expected; under mistral's names 527
  clocks in every domain would be inverted. `LAB.021.044` routes only that clock and uses two
  slots without enables, one with `SEL CLKB`, which only makes sense if that bit inverts.
  CLK2 has no special default (the controller-port note's "CLK2 → clkb" was this swap). nextpnr
  sets neither bit in our designs (no negedge clocks; it always uses clka), so it can't
  arbitrate; its encoder would mis-clock a negedge FF under this reading. [confirmed for the
  select, likely for the inversion]
- Pins: seeds follow GPIO `DATAIN.0–3` (`.3` is the IOE input-register path, printed `PIN.3`)
  and top-bank pins through HMC bypass ports. mistral prints the bypass link only on HMC
  inverter lines, so `tools/cvinfo hmc` dumps the full IOINT ↔ GPIO table from mistral's
  database (`build/hmc-bypass.txt`, used by `netlist.py` and `pinmap.py`; it agrees with all
  56 inverter-line comments).
- Not modelled: MLAB RAM mode, SHARE chains, async clears (only flagged), DSP/M10K blocks
  (leaves).
