# SDRAM interface of spc.cor (JB7.2)

Reverse-engineered from `build/spc.bt` only (mistral decompile of Analogue's `spc.cor`), by gate-level
extraction (`tools/netlist.py`; the two decode fixes in "Method" are now part of the tool) and cycle
simulation of the extracted controller. Oct 2026. Init and refresh re-simulated from power-up with
the fixed tool (nothing forced); changes marked "Changed". Confidence tags: **[confirmed]** = read directly from the bitstream
or forced by the simulated command sequence; **[likely]** = the only reading consistent with several
independent checks; **[guess]** = plausible, not checked.

## Which chip is which (revised 23 Oct 2026)

The sections below were written assuming the bottom-bank bus ("controller 1", AB11 clock) drives
the two x8 IS42S81600F, with "chip A" (DQ on 2A) and "chip B" (DQ on 3B) as the two chips. Two
independent results say that's wrong:

1. **Chip B's page has 512 columns** (hwtest v2). The IS42S81600F (16M × 8) has 4096 rows ×
   **1024** columns per bank; the **AS4C8M16SA** (8M × 16) has 4096 × **512**. So the
   bottom-bank bus is the x16 chip **U4**, 16 MB.
2. **The 148.5 MHz controller ("controller 2", H8 clock) decodes as two x8 chips with 1024
   columns** on a shared address bus with separate command and data lines ("Controller 2"
   below). That's the IS42S81600F pair, **U5 + U16**, 2 × 16 MB.

The pin positions agree. On the photo (`notes/hardware-research.md`) U5 sits by the FPGA's upper
left edge and U4 by its lower left edge (ball A1 top left); controller 2's pins are all in the
top-left quarter of the ball grid, controller 1's address pins on the lower left edge and its 3B
data pins on the bottom edge.

Consequences:
- **"Chip A" and "chip B" are the two bytes of U4**, not two chips. Chip B = the byte on 3B with
  AB10 as its DQM. Chip A = the byte on 2A, masked by **U4's other DQM**, which the stock core
  must drive low somewhere and our cores don't. It isn't one of the 3A/3B constants, Y3 or the
  4A/7A constants (hwtest v3). It isn't any controller-1 pin either. The candidates left are pins
  stock drives from logic that hwtest leaves as weak pull-up inputs. The best of these is
  **C13/C15** (one FF in controller 2, 0 except during controller 2's MRS). TSOP-54 x16: LDQM is
  pin 15 (between DQ7 and WE#), UDQM pin 39 (next to CLK). AB10 sits in the same IOE pair as
  the clock AB11, so it is probably UDQM, which would make chip B DQ8–15 [guess].
- **U5 + U16 (32 MB) are accessible**: controller 2's pin map is complete apart from the A0–A9
  bit order (not needed) and C13/C15. Each chip is an 8-bit memory with its own command lines,
  so they can run as one x16 memory (same command to both) or as two independent banks.
- Total: 16 MB (U4, 8 MB usable until chip A's DQM is found) + 32 MB (U5/U16), as the photos said.

## Summary

(Written before the revision above: "x8 pair" / "chip A/B" here = U4 and its two bytes.)

- The two x8 IS42S81600F chips are **one x16 memory**: all address/command lines are shared, the two
  8-bit DQ buses are driven and captured on the same cycles [confirmed]. Chip "A" on bank 2A, chip
  "B" on bank 3B. Which is the low byte is arbitrary (the stock core decides it in logic).
- Controller clock: **FPLL.054.037 C1 = 115.8626 MHz** (74.25 MHz × 142/13 / 7, H16 reference) via
  `CMUXHG.054.022.2` [confirmed]. SDRAM clock: AB11, a DDIO output with constant data clocked by
  **FPLL.054.037 C8** (same /7, phase-shifted) via `CMUXVG.025.045.3` [confirmed].
- Mode register **0x037: CAS latency 3, full-page burst, sequential, burst writes** [likely].
- Stock traffic: only 512-word full-page bursts starting at column 0, ended with BURST TERMINATE,
  then PRECHARGE ALL. tRP = tRCD = 3 cycles (25.9 ns). Refresh: one AUTO REFRESH every **2400
  cycles = 20.7 µs** (slower than the 15.6 µs that 4096 rows / 64 ms needs).
- CKE and DQM are not driven by the controller logic (tied on the board or by a constant pin) [likely].
  AB10, a constant output next to the clock, is **low** in spc.cor [likely]; **chip B drives
  only while AB10 is low** [confirmed: hwtest v1/v2], so AB10 is chip B's DQM (or another
  active-low enable) [likely].
- **The page has 512 columns** [confirmed: hwtest v2, "hwtest v2 result" below]: a full-page
  burst wraps after 512 words, which is why the stock controller only uses 512-word bursts.
  Chip B returns correct data with our 74.25 MHz controller at capture point r4 / f3.5.
  **Chip A (2A) has never driven the bus** in any run, also not with any of spc.cor's
  constant pins at their stock level (hwtest v3); chip B alone, or the x16 chip, are the
  fallbacks until a continuity check finds chip A's enable.
- A second, independent controller at 148.5 MHz drives top-bank and 3A pins (probably the x16
  AS4C8M16SA), partly decoded below.

## Pin table: x8 pair (both chips share everything except DQ)

Command encoding seen (CS# RAS# CAS# WE#): NOP 0111, ACT 0011, READ 0101, WRITE 0100, BST 0110,
PRE 0010, REF 0001, MRS 0000, deselect 1xxx.

| Pin | Bank | Driver (spc.bt) | Role | Conf. | How |
|---|---|---|---|---|---|
| AB17 | 4A | LAB.017.004.6:FFT0 | CS# | confirmed | 0 on every command cycle, 1 in all waits; only reading that decodes the init sequence |
| AA17 | 4A | MLAB.018.004.9:FFB0 | RAS# | confirmed | command decode (PRE/REF/MRS/ACT low, READ/WRITE/BST high) |
| AB18 | 4A | MLAB.018.004.9:FFT1 | CAS# | confirmed | command decode |
| AA18 | 4A | MLAB.018.004.6:FFT0 | WE# | confirmed | command decode |
| AA14 | 4A | LAB.014.004.4:FFB0 | A10 | likely | pure state function: 1 on every PRECHARGE (= PRE ALL), 0 on MRS, ACT, READ, WRITE |
| AB13 | 4A | LAB.017.003.6:FFB0 | A0 | likely | row-address bit 0 of both clients; 1 in MRS |
| AA13 | 4A | LAB.017.003.1:FFT0 | A1 | likely | row bit 1; 1 in MRS |
| AB12 | 4A | LAB.017.003.8:FFT0 | A2 | likely | row bit 2; 1 in MRS |
| AA12 | 3B | LAB.017.003.9:FFT0 | A3 | likely | row bit 3 |
| U2 | 2A | LAB.017.003.6:FFT1 | A4 | likely | row bit 4; 1 in MRS |
| U1 | 2A | LAB.017.003.1:FFB0 | A5 | likely | row bit 5; 1 in MRS |
| W2 | 2A | LAB.016.003.4:FFT0 | A6 | likely | row bit 6 |
| AA2 | 2A | LAB.016.003.4:FFB1 | A7 | likely | row bit 7 |
| AA1 | 2A | LAB.016.003.1:FFT0 | A8 | likely | row bit 8 |
| N1 | 2A | LAB.016.003.2:FFT0 | A9 | likely | row bit 9 (one client only), 0 outside ACTIVE |
| N2 | 2A | LAB.016.003.2:FFB1 | A11 | likely | row-only bit (0 outside ACTIVE); the only pin left for A11 |
| AA15, AB15 | 4A | LAB.016.005.2:FFT0 / FFB0 | BA0 / BA1 (order unknown) | likely | loaded at ACTIVE and held through READ/WRITE, BST, PRE; per-client bank select inputs |
| AB11 | 3B | GPIO DDIO (`OUTREG_MODE_SEL DDR`), no data routed, `DATAOUT.1` inverted | CLK | confirmed (clock); polarity likely | IOE `CLKOUT.0` ← CMUXVG.025.045.3 = FPLL.054.037 C8 |
| D3 E2 L2 L1 G2 G1 C2 C1 | 2A | out: M10K.011.004–007 port B; OE: fabric FFs | chip A DQ0–7 (bit order unknown, irrelevant) | confirmed | |
| AB5 AB6 AB7 AA7 AB8 AA8 AA9 AA10 | 3B | out: M10K.022.004–007 port B; OE: fabric FFs | chip B DQ0–7 (bit order unknown) | confirmed | |
| AB10 | 3B | constant output (`DATAOUT.0` inverted, nothing routed), same IOE pair as AB11 | constant **0** [likely]; DQM of both chips? (not CKE: see "Constant pins") | guess | |
| Y3 (2A), W9 W8 (3A), Y9 Y10 R11 R10 Y11 (3B) | | open-drain outputs, data not routed | released (output 1) [likely]; tie-offs? | guess | constant; next to the SDRAM pins; see "Constant pins" |

Notes on the table:

- **The 128 Mbit x8 part has 12 row bits (A0–A11), not 13**: 4 banks × 4096 rows × 1024 columns
  × 8 (4K refresh) [datasheet, from memory; check]. So the 18 fabric outputs are exactly A0–A11 +
  BA0/BA1 + CS#/RAS#/CAS#/WE#, and nothing drives CKE or DQM. **But chip B wraps its burst at
  512 columns** (hwtest v2), so the chips are not organised like that (a 64 Mbit x8, 4 × 4096 ×
  512, fits; whether there is a 13th row bit on some other pin is open). All 12 row pins and both
  bank pins select distinct storage (v2: bank 0 row 0 kept its own data while 16 383 other
  rows were written after it).
- A0–A9 order: both clients' row addresses are counters/adders, and their carry-chain bit order maps
  to the pins in the same order (AB13 AA13 AB12 AA12 U2 U1 W2 AA2 AA1 N1). Taking that as A0..A9,
  the MRS value (pins AB13 AA13 AB12 U2 U1 high) reads **0x037**: full page (A2..A0 = 111, which the
  observed 512-word bursts + BST require) and CL3 (A6..A4 = 011, which the read-capture timing below
  also requires). A wrong order would almost certainly give a nonsensical mode word. The pin
  pattern itself is certain, so copying it reproduces Analogue's mode exactly whatever the mapping.
- Row, column and bank bit order is otherwise irrelevant for our own controller (any bijection
  works) except for A10 (auto-precharge / precharge-all) and the MRS bits.
- No pin of the controller depends on anything but the FSM and address registers; no pull-ups
  (`USE_WEAK_PULLUP 0` everywhere).

## Clocks and phase

| Signal | Source | Frequency |
|---|---|---|
| controller FFs, DQ input registers, M10K port B | FPLL.054.037 C1 → CMUXHG.054.022.2 (`INPUT_SEL 09`) | 115.8626 MHz |
| AB11 DDIO | FPLL.054.037 C8 → CMUXVG.025.045.3 (`INPUT_SEL 0c`) | 115.8626 MHz, shifted |
| client "V" (reads, LABs y=27–33) | CMUXVR.025.045.2 = FPLL.000.037 C6 | 148.5 MHz |
| client "S" (writes, M10K port A) | CMUXHG.000.022.3 (`INPUT_SEL 20` = clock switchover) | unknown |

C8 settings: `DPRIO0_CNT_HI/LO 4/3` (÷7, odd-duty fix), `CNT_PRESET.8 05`, `CNT_PH_MUX_PRESET.8 7`;
C1 has default presets. Phase = (PRESET − 1) + PH_MUX/8 VCO periods: calibrated on the Pocket core
(PRESET 0x0f, no PH_MUX = 14 VCO = its declared 23280 ps) and on spc's FPLL.000.037, where the same
formula gives exactly 90° for C6 (PRESET 3) and 270° for C3 (PRESET 0x2a, PH_MUX 2, ÷55), so PH_MUX
adds. For C8: 4.875 × 1.2330 ns = **6.01 ns lag = 2.62 ns lead (−109°)** relative to C1. (FPLL.054.000
C8, the 148.5 MHz memory clock on H8, has the same PRESET/PH_MUX = −2.04 ns.) The M-counter presets
on FPLL.054.037 shift all outputs equally.

DDIO data: `DATAOUT.1` inverted, `DATAOUT.0` not, nothing routed. Which index is the high-phase
data isn't known; the non-inverting reading gives the consistent timing below, the inverting one
puts the SDRAM edge on top of the command transitions [likely non-inverting].

Timing check (C8 at the pin ≈ C1 edge + 6.0 ns + ~3 ns DDIO/output delay ≈ next C1 edge + 0.4 ns):
commands launched by fabric FFs at C1 edge n (pin delay ~4–7 ns) are sampled by the SDRAM ≈ 0.4 ns
after edge n+1 (setup ≈ 2–5 ns, hold ≈ 4 ns). READ issued in pin cycle r: the controller's input
clock enable is high in cycle r+3, so the IOE register samples at edge r+4. With CL3 and the SDRAM
edge at r+1 (+0.4 ns), word 0 is valid from about edge r+4 − 1.6 ns to edge r+4 + 4.4 ns (tAC 5.4,
tOH 2.7, ~1.2 ns input path): the capture edge sits in the window. CL2 would put it a cycle late.

## I/O settings (as printed in spc.bt)

- Every SDRAM pin: `DRIVE_STRENGTH V2P5_50OHM` (mistral's name for the I/O standard/drive; the same
  value is on every used pin of these banks, so read it as "bank default", meaning not verified),
  `USE_WEAK_PULLUP 0`. Output-only pins: `IOCSR_STD DIS`. Most pins: `RB_T9_SEL_EREG_CFF_DELAY 1f`
  (meaning unknown; also on unrelated pins).
- **Address/command outputs: fabric FFs → pin, no IOE output register** [confirmed]. Same for DQ
  output data (straight from the M10K port-B output register, `B_OUTPUT_SEL REG`, C1) and OE
  (fabric FFs, several duplicates).
- **DQ inputs: IOE input register** [confirmed]: `DATAIN.3` used, `CLKIN.0` ← C1, `CEIN` ← one
  combinational signal (`LAB.016.004.3:T`, a state decode) for all 16 DQ, `INPUT_PATH_CE_IN 1`,
  `RB_FIFO_WCLK_EN/INV 1`. Captured bytes go to LABs y=20–24 and on into the M10K read buffers
  `011.025–028`.
- AB11: `OUTREG_MODE_SEL DDR`, `OUTREG_OUTPUT_SEL SEL_SDR_DELAY`, `RBOE_LVL_FR_CLK_EN 1`.

## Controller behaviour (simulated)

Cluster: LABs x=12–24, y=3–8 (FSM state bits `016.005.0/1/4/7`, `017.003.4`, `016.005.3`), ~200 FFs
on C1. Two clients hand over requests by toggle synchronisers (inputs from the 148.5 MHz and the
switchover-clock domains).

Init (after configuration, FFs at 0):

1. 1 cycle of all-zero command pins (= MRS with A = 0) before the first update. Harmless, since the
   SDRAM isn't initialised yet.
2. NOP (CS# 0, A10 1, other address 0) until the first PRE ALL at cycle **2^20 + 2^11 = 1 050 624
   = 9.068 ms** (a 20-bit counter whose LSB is a toggle FF, then wait counters). Changed: was
   "2^20 + ≈1040 = ≈9.06 ms", from a run that forced the init counter's release and estimated
   the rest; the whole controller now runs from all-zero FFs to the end of init.
3. PRE ALL; 1 deselect; REF; 8 deselect; REF; 8 deselect; MRS 0x037 (BA = 00, A10 = 0); then
   deselect until the first periodic refresh (PRE ALL; NOP; REF), which from power-up comes
   **558 cycles** after the MRS (the refresh timer free-runs from configuration and requests at
   cycle ≡ 2 mod 2400). REF→REF = 9 cycles (77.7 ns ≥ tRC), REF→MRS 9 cycles. Changed: was
   "MRS; 9 deselect; PRE ALL; NOP; REF" – that PRE/NOP/REF is the periodic refresh, whose phase
   came out differently in the forced run.

Periodic refresh: request every **2400 cycles (20.71 µs)** from a free-running counter
(`MLAB.023.005`; all 20 intervals in a 1.1 M-cycle run from power-up are exactly 2400), served
when idle: PRE ALL, NOP, REF (PRE→REF 2 cycles = 17.3 ns, slightly under
tRP 18 ns for -6, but every burst already closes its bank), then ≥8 cycles before the next command.
4096 refreshes take 84.8 ms, outside the 64 ms spec.

Read request (client V): PRE ALL → 2 cycles → ACT (row, BA) → 2 deselect → READ (column 0, A10 0) →
input CE high 512 cycles starting 3 cycles after READ → BST (READ + 516) → PRE ALL 3 cycles later →
second row of the request (N2/A11 = 1) the same way. 512 words × 2 bytes = 1 KB per burst.
Write request (client S): PRE ALL → ACT → WRITE after 3 cycles with **OE and first data in the same
cycle** (write latency 0) → 512 data cycles → BST (held 3 cycles) → NOP → PRE ALL (5 cycles after
the BST) → second row. DQM is never toggled by logic.

Both bursts re-checked with the fixed tool from a post-init snapshot (client V: one request input
set; client S: two inputs of its toggle handshake set): same command sequences and spacings.

Timing in C1 cycles (8.631 ns): tRP 3, tRCD 3, CL 3, tRAS ≈ 522 cycles (4.5 µs), tRC for refresh 9.

## Controller 2: the IS42S81600F pair, U5 + U16 (decoded 23 Oct 2026)

Top-bank pins driven through HMC bypass ports whose route line has no matching `i HMC …` inverter
line (`r X HMC.011.045:IOINT…DOUT.n ; PIN`) were missed by `pinmap.py`. Changed: fixed,
`build/spc-pinmap.txt` now lists all of them (it takes the bypass table from `tools/cvinfo hmc`).

Changed (23 Oct): the first pass decoded only 17 of this controller's outputs and couldn't assign
the command lines. Listing **every** pin whose driver FF is on its clock (`~/scratch/memchips/
pinclk.py`, throwaway) found the missing ones: **G13** (CAS#, `LAB.020.023.6`, next to the other
command FFs) and a second command group in LABs y=40–41 (A7 B6 B7 C6 D17 C13/C15) with the
open-drain group as its data bus. The notes had filed both as "unrelated logic". With them
everything decodes (FastSim from power-up on the fixed `tools/netlist.py`, then each client
request input poked; scripts `~/scratch/memchips/c2*.py`, throwaway):

- Clock: everything on **FPLL.054.000 C5 = 148.5 MHz** (CMUXVG.021.000.3). SDRAM clock out on
  **H8**: DDIO like AB11, IOE `CLKOUT.0` ← CMUXVG.021.000.2 = FPLL.054.000 C8, PRESET 5 /
  PH_MUX 7 → leads C5 by 2.04 ns.
- **Two chips, one address bus, separate command and data lines** [confirmed: command decode].
  Group 1 (G1) and group 2 (G2) get init and refresh in the same cycles; client accesses can go to
  G1 alone, G2 alone, or both (G2 one cycle after G1, using the address G1 put out).

| signal | G1 | G2 | how |
|---|---|---|---|
| CS# | **D12** | **B6** | low for one cycle per command, high in the next (commands every 2nd cycle) |
| RAS# | **D13** | **C6** | |
| CAS# | **G13** | **A7** | |
| WE# | **E12** | **B7** | READ and WRITE differ only here |
| A10 | **H9** | **D17** | 1 at every PRECHARGE (= PRE ALL), 0 at READ/WRITE (no auto-precharge) and MRS; a row bit at ACT (H9) |
| A0–A9 (shared) | N6 P6 P7 R7 P8 R9 H6 F7 D7 C8 (order unknown except N6/R7 = A4/A5) | same pins | row at ACT, column at READ/WRITE: **10 column bits = 1024 columns** |
| A11 (shared) | **M6** | M6? | 1 at ACT with all address bits set, 0 at READ: a row-only bit. (The old notes' "sticky flag".) |
| BA0/BA1 (shared) | E9, C9 (order unknown) | same | set at ACT and held through READ |
| DQ0–7 | N8 J7 J9 K7 H11 G12 F12 J11 (push-pull, one OE FF `LAB.020.021.0:FFB0`) | **A8 A9 A10 A12 B10 B11 B12 C16** | G2: IOE input registers on all 8, captured into LABs y=39–41 on one enable (`LAB.026.041.6:FFT1`) |
| ? | – | **C13 = C15** (one FF, `LAB.025.041.1:FFT0`) | 0 except in the MRS cycle and the one after; DQM or CKE of the pair, or G2's own A11 [guess] |
| CLK | H8 | H8 (no other clock output on this domain) | |

- Command encoding (CS# RAS# CAS# WE#) as usual: PRE 0010 (+A10 = 1), REF 0001, MRS 0000, ACT 0011,
  READ 0101, WRITE 0100; deselect between commands.
- **Init**: all FFs 0 → deselect for 2^16 cycles (441 µs), PRE ALL, REF, REF (18 cycles apart),
  **MRS with N6 + R7 high**, then periodic refresh. **Refresh**: PRE ALL, REF every **1092 cycles
  (7.35 µs)**, both groups at once.
- **Access** (either group): PRE ALL, ACT, READ or WRITE, two cycles apart (tRP = tRCD = 2 cycles
  = 13.5 ns at 148.5 MHz). Read data: the capture enable is high 4 cycles after the READ for both
  groups, the same relation that gives CL3 on controller 1 (same C8 phase preset) → **CL3**; one
  byte per access → **burst length 1**. So the MRS is CL3/BL1 = A4 + A5 = **N6 and R7**
  [likely]. Write: OE on 2 cycles before the WRITE until 1 after.
- G2's data pins are **open drain from one FF, inverted on the HMC bypass** (`i HMC.011.045:
  IOINTADDRDOUT.32 1`): FF 0 = all eight released, FF 1 = all eight low. So the stock core only
  ever writes 0x00 to G2 (its "write" request), and otherwise only reads it. A real controller
  needs push-pull there (see "Open questions").
- Clients: requests and addresses come from two other clock domains, FPLL.054.037 C3 =
  36.87 MHz (CMUXHG.054.022.3) and C6 = 42.69 MHz (CMUXVG.025.045.1), i.e. the SPC player's own
  logic (probably the APU's 64 KB audio RAM and the like), not video.

Which chips: two x8 parts, 12 row bits (A0–A11), 1024 columns, 4 banks = 4096 × 1024 × 4 × 8 bit
= 128 Mbit each, exactly the **IS42S81600F**. The pin positions fit too: everything sits in the
top-left quarter of the FPGA (rows A–R, columns 6–17), toward U5 (top side, upper left of the
FPGA) and U16 (directly behind U5 on the underside), which share their address pins through
vias. Which group is which chip doesn't matter.

Other fabric-driven top-bank pins, from unrelated logic: G8 L7 (LABs y=44), F14 (025.024), H14
(026.023), J13 K16 (029.011, controller clock), H15 (026.026), F10 (MLAB.013.033); G6 (open
drain, 21.34 MHz domain); H18 ← CMUXVG.025.045.0 (FPLL.054.037 C7, 12.29 MHz) and J19 ←
CMUXVG.025.045.2 (C5, 3.07 MHz) as clock outputs; input J18 via `IOINTDQDIN`.

## memtest v1 (prepared 23 Oct 2026)

`quartus/memtest` (`make out/q-memtest.cor`, card slot 15; procedure in
`notes/hardware-tests.md`): one core that tests all three chips, results on two text pages.

- **U4**: `sdram_test.sv` unchanged except `FIXED_STOCK` (every pass at spc.cor's levels: AB10
  low, the 3A/3B/4A/7A constants at their level, the open-drain group released) and a `start`
  input, so passes line up with the hypotheses. Errors per byte at f3.5 r4 f4.5 r5.
- **U5/U16**: `quartus/common/mem2_test.sv`. Both chips get the same commands in the same
  cycles on the decoded pins, at 74.25 MHz with the clock on H8 as the inverted clk (DDIO), as
  AB11. MRS = N6 + R7 only (CL3, BL1 whichever of A4/A5 each is). Each pass: init, write all
  4 × 4096 rows × 1024 columns with one WRITE per clock, read them back with one READ per clock,
  then a column walk. Errors per chip at the same four capture points.
- **Group 2's data pins stay as spc.cor has them (open drain)**: a line is driven low or
  released to its weak pull-up, never driven high. So group 2 gets one byte per row, put on the
  pins 300 clocks (4 µs) before the row's writes; the byte is a different nonzero constant
  XORed in per bank/row bit, so any one- or two-bit row/bank aliasing shows. Group 1 (push-pull,
  as stock) gets a different byte per column. The column walk (bank 1 row 5: columns 0, 1, 2,
  4 … 512, each written with its own byte after the 4 µs wait, then read back) checks the column
  address pins for group 2 too.
- **Hypotheses**, one pass of both tests each: C13/C15 released / both low / C13 low / C15
  low. Low is spc.cor's level outside the MRS; released is what every earlier core did.
- Simulated: `make sim-mem2` (two x8 models, group 2's lines open drain with a 1 µs pull-up
  rise: clean at f3.5/r4; a 6 µs rise makes group 2 fail; a stuck column pin shows in the
  column walk) and `make sim-memtest` (whole core; models with U4 byte A's DQM on C15 and the
  pair's on C13: the tables attribute both correctly).

## memtest v1 result (23 Oct 2026) and the top-bank constants

On the console (`notes/hardware-tests.md`): U4 byte B clean, byte A and both U5/U16 chips
silent in all four C13/C15 hypotheses. G1 reads back the last byte the FPGA drove, G2 its
pull-ups: neither chip ever drives. Three silent chips that behave like DQM high (or CKE low)
point at pins our cores have never driven: **the top bank's constants**. hwtest v3 switched
only the 3A/3B constants and held 4A plus K19 K20 J17. `~/scratch/v3/pinclass.py` didn't follow
memory-controller bypass paths, so it missed most top-bank constants and got J17's level wrong.
Redone (`i` lines of `build/spc.bt`, top-bank pins without a fabric driver):

| level | pins | evidence |
|---|---|---|
| 0, GPIO path | A14 B5 G16 H13 (K19 K20 already held) | DATAOUT unrouted, inverter set (as AB10, confirmed 0 by hwtest v2) |
| 0, bypass path [likely] | A13 A15 B15 C11 E14 E15 E16 F13 F15 G15 G17 G18 (HMC DQDOUT), A5 (BADOUT), B13 (CKEDOUT), B16 J17 (DMDOUT), J8 (ADDRDOUT) | HMC `IOINT*DOUT` unrouted with its inverter set (`i HMC.011.045:IOINT…DOUT.n 1`), the same pattern as the GPIO zeros. The bypass inverter is real: G2's data FF reaches its pins inverted. The HMC port names are the bypass slot's DDR role, not the board net. |
| 1, GPIO path | **D9 E10** | OE on, DATAOUT unrouted, no inverter: same as M9/R14 |
| tri-state | K9 J18 | OE from an unrouted bypass port with no inverter = off |

J17 was held at **1** in hwtest v3–v5 and memtest v1 (pinclass's reading); by the pattern
above stock drives it 0. memtest v2 drives all of these at the levels in the table and
binary-codes which ones matter for each chip.

## Constant pins: AB10 and the open-drain group (after hwtest v1, Oct 2026)

hwtest v1 on the console (22 Oct, `notes/hardware-tests.md`): all eight capture points wrong on
16 776 960 of 16 777 216 words every pass (256 matches = chance for a 16-bit compare against a
constant), with the open-drain pins low or released alike: the chips never answered. v1 drove
AB10 **high** as "CKE".

What spc.cor does with these pins (`build/spc.bt`, the `i`/`s` lines):

| pin(s) | OE | DATAOUT | other |
|---|---|---|---|
| AB10 | `OEIN.0` unrouted, inverter set (always-on output, like every output) | `DATAOUT.0` unrouted, **inverter set** | `IOCSR_STD DIS`, same IOE pair as AB11 |
| Y3 W9 W8 Y9 Y10 R11 R10 Y11 | same | `DATAOUT.0` unrouted, **no inverter** | `USE_OPEN_DRAIN 1` |
| AB11 (clock) | same | DDIO, `DATAOUT.1` inverted, `.0` not, both unrouted | clock = the two levels alternating |

- Fabric convention: an unrouted input reads 1 (LUT indexing, checked cell by cell against
  nextpnr designs that run on the console), and the inverters are real (data pins that work,
  e.g. the link data and our video, have no DATAOUT inverter). With that, the OE inverter turns
  the unrouted 1 into the active-low output enable (consistent with the link OE FF driving the
  pins when it is 1), **AB10 is a constant 0** and **the open-drain pins output 1, i.e. are
  released** [likely]. AB11's two DDIO levels differ either way.
- Check against v1: under the opposite convention (unrouted = 0) the stock levels would be AB10
  = 1 and the open-drain pins driven low, which is exactly v1's "DQM low" passes, and those
  failed completely. So v1 never ran the stock configuration; the decode above has not been
  tried [likely].
- The stock core needs a working SDRAM, so whatever AB10 is, low is its working level: not CKE
  (CKE low = power-down/clock suspend, nothing would work; CKE is then tied high on the board),
  but plausibly the **shared DQM** of both x8 chips (TSOP-54: DQM pin 39 is next to CLK, 38,
  and AB10 shares the IOE pair with AB11 = CLK) [guess]. DQM high masks writes and turns the
  read outputs off, which is what v1 saw.
- Other pins with AB10's pattern (constant output, unrouted DATAOUT, inverter set, i.e.
  constant 0): R5 R6 U8 U7 T8 T7 V6 U6 V10 V9 U10 T10 P12 R12 N9 P9 (3A/3B), T13 Y15 Y14 V15
  V14 Y17 Y16 T14 W19 V16 Y19 V19 U16 (4A), H13 B5 A14 G16 K20 K19. Unknown roles; not driven by
  our cores.
- The "first f4.5 miss at 000000 got 0000 expected 0000" line of v1: pass 0 expected word for
  bank 0 row 0 column 0 was the hash of 0, i.e. 0000, and the miss was counted while the
  recorded word equals the expected one. With the chips not driving, the falling-edge capture
  FF samples a floating bus; a metastable sample can resolve differently in the compare and in
  the "got" register one stage later [guess]. v2 adds a register stage before the compare,
  uses a pattern that is never 0000 for the first word, and shows raw words instead.

hwtest v2 (`quartus/common/sdram_test.sv`) runs one hypothesis per pass, re-initialising the
chips each time: 0 = AB10 low + open-drain released (stock as decoded), 1 = AB10 low +
open-drain low, 2 = AB10 high + released, 3 = AB10 high + low (v1's two), with per-hypothesis
error counts at the eight capture points and the raw bus words after the first READ. All four
only use levels spc.cor or v1 already put on these pins.

## hwtest v2 result (22 Oct 2026): 512-column page, chip B works, chip A silent

Console run of hwtest v2 (`notes/buslog-2026-10-22-hwtest.md`, second run). Four pin
hypotheses (AB10 low/high × open-drain group released/low), 1024-word bursts, 16-bit compare.

- AB10 high: nothing drives (raw words constant, FFFEFE/FFFF02 errors of 0x1000000).
- AB10 low (open-drain group released or low alike): the **high byte (chip B, bank 3B)** changes
  every cycle from rising edge 4 after the READ, the **low byte (chip A, 2A)** stays constant
  (5E, 02; idle 7F). At r4 and f3.5 ~33 000 words per pass matched, at the other points ~250.
- The raw high bytes at edges 4–7 (C5 DD F6 E8 in hypothesis 0, 72 6C 9B 23 in 1) are exactly
  the high bytes of the pattern written to **columns 512–515 of the same row** in that pass
  (`~/scratch/v3/alias.py`, throwaway: exhaustive search over bank, row and column). The
  1024-word write burst wrapped after 512 columns and overwrote columns 0–511 with the data of
  512–1023; reads wrap the same way, so columns 512–1023 read back right. Count check: half of
  the 2^24 words have the right high byte; chip A's floating byte equals the expected low byte
  1 time in 256 → 32 768 expected, 33 019 and 32 257 seen. So chip B, the command/address
  pins, the MRS pattern (CL3, full page), our inverted 74.25 MHz clock and the r4 capture point
  all work; only the page is 512 columns, not 1024. [confirmed]
- Chip A never drives, with the open-drain group (incl. Y3, the only spare pin in its bank 2A)
  released or low. Every logic-driven stock pin in banks 2A/3A/3B is accounted for (SDRAM
  pins, the 148.5 MHz controller's pins, M8 = cart-ADC LRCK, `notes/controllers.md`), so if chip
  A has an FPGA-side enable it is one of the **constant** pins below, which spc.cor drives and
  our cores leave as weak-pull-up inputs (Quartus `RESERVE_ALL_UNUSED_PINS_WEAK_PULLUP`).

### spc.cor pins with a constant level (all banks, `~/scratch/v3/pinclass.py`, throwaway)

spc.cor configures all 224 user I/Os. Besides the logic-driven pins, the open-drain group and
the inputs, these are outputs with OE always on and DATAOUT unrouted, i.e. constants:
**inverter set = 0**, **no inverter = 1** (same convention that made AB10 = 0, which v2
confirmed). Pins in the top banks (y = 045) can also be driven through HMC bypass routes; the
ones listed there have no route in `build/spc-pinmap.txt`.

| bank (Quartus `.pin` report for the pins hwtest v3 uses) | level 0 | level 1 |
|---|---|---|
| 3A (GPIO.010/012.000) | R5 R6 U7 U8 T7 T8 V6 U6 | – |
| 3B (GPIO.016–029.000) | AB10, V9 V10 U10 T10 P12 R12 N9 P9 | M9 T9 U11 |
| 4A (GPIO.033–052.000) | T13 T14 U16 V14 V15 V16 V19 W19 Y14 Y15 Y16 Y17 Y19 | R14 U15 U17 U20 V13 V18 V20 Y20 |
| top (y = 045; K19 K20 J17 are 7A per Quartus) | A14 B5 G16 H13 K19 K20 | B13 B16 J17 (others in the raw list are HMC-driven) |

Tri-stated in spc.cor (OE off) on the bottom edge: M7 U12 U13 (and W16, the clock input).

### hwtest v3 (prepared 22 Oct)

- 512-word bursts (4 banks × 4096 rows × 512 columns = 16 MB tested per pass, ~0.25 s).
- Errors counted **per chip** (A = low byte, B = high byte) at f3.5, r4, f4.5, r5.
- The 19 constant pins of 3A/3B are index 0–18 (R5 R6 U7 U8 T7 T8 V6 U6 V9 V10 U10 T10 P12 R12
  N9 P9 at 0, M9 T9 U11 at 1) and are switched per pass between spc.cor's level and released
  (weak pull-up, as in v1/v2). 16 hypotheses (`sdram_test.sv`): 0 stock, 1 all released, 2–6
  stock except the pins whose index has bit k set released, 7–11 the same with bit k clear,
  12 stock + Y3 low, 13 stock + AB10 high, 14 stock + whole open-drain group low, 15 stock. If
  chip A needs one of them at its stock level, it is clean in 0 and 12–15, fails in 1, and
  hypotheses 2–6 spell the pin's index in binary (fail in 2+k ⇔ bit k = 1; 7–11 the complement).
  `make sim-sdram` checks exactly this with chip A's DQM on index 5 in the model.
- The 4A constants and K19 K20 J17 are held at spc.cor's level for the whole run (not
  switched: 4A is the PIC link's bank; K19/K20/J17 sit next to the audio pins).
- Only spc.cor's levels are ever driven on these pins; "released" is what v1/v2 already did.

## hwtest v3 result (22 Oct 2026): chip A's enable is none of the constant pins

Console run of hwtest v3 (`notes/buslog-2026-10-22-hwtest.md`, third run; page 4 at f044 of
`IMG_3062.mov`), 512-word bursts, errors per chip in each hypothesis's last pass:

- **Chip B (high byte): 000000 errors at f3.5 and r4 in every hypothesis except 13** (AB10
  high). So chip B works completely with 512-column pages, AB10 low, our controller and capture
  point r4 (f3.5 equally) [confirmed]; none of the 19 3A/3B constant pins (stock level or
  released) and none of the open-drain states affect it.
- **Chip A (low byte): ~7F8000 errors (every word, apart from chance matches of a constant
  byte) in all 16 hypotheses**: it never drives with any of the 19 3A/3B constants at its stock
  level or released, nor with Y3 or the whole open-drain group low, and the 24 4A/7A constants
  were held at their stock level throughout. So its enable (CKE/DQM/CS or a missing supply/
  strap) is not an FPGA pin that spc.cor drives to a constant [likely].
- What is left: the chip's CKE/DQM/CS# may be strapped or wired to a pin that spc.cor drives
  from logic we misattributed, or chip A may be unpopulated/unused by the stock core (spc.cor's
  DQ OE logic does drive its DQ pins, so the stock core at least writes them). **A continuity
  check on chip A's CKE, DQM and CS# pins** (TSOP-54 x8; see "Open questions") is the direct
  answer.
- Fallbacks for the SNES core: **chip B alone as 8-bit memory** (half the bandwidth of the
  pair, two accesses per 16-bit ROM word; still enough for a SNES ROM at 74.25 MHz), or the
  x8 pair on the top bank. Changed (23 Oct): "chip A/B" are the two bytes of the x16 U4, and
  the top-bank controller drives the x8 pair U5 + U16, now decoded ("Which chip is which",
  "Controller 2").

## Method

- Seeds: the 18 outputs + DQ OE/CE. `tools/netlist.py` cone back to C1 FFs in the region; other
  domains become inputs. A compiled cycle simulator on top of `netlist.Design` (`~/scratch/sdramre/`,
  throwaway: `fsim.py`, `run.py`, `c2.py`) runs it from all-zero FFs. Client requests were found
  by poking each foreign-domain input. Re-run with the fixed `tools/netlist.py`
  (`~/scratch/netfix/sdram.py`, throwaway): the full C1 cone is 195 FFs whose only inputs are 16
  client-request FFs (10 on 148.5 MHz client V, 6 on client S's clock); with those at 0 it runs
  init + refresh from power-up with nothing forced.
- **Two decode fixes to netlist.py were needed** (now in `tools/netlist.py`, evidence in
  `notes/pic-link.md` "Tool"); without them the FSM deadlocks:
  1. LAB clock select: the bit mistral calls `CLKn_INV` selects clkb (`CLKIN.1`), and
     `CLKn_SEL CLKB` is the real inversion. Evidence: in spc, 89 LABs route only `CLKIN.1` and set
     `CLKn_INV` on every clock they use; LABs routing only `CLKIN.0` set it only on unused clocks.
     Under mistral's reading those 89 LABs would clock from an unrouted input.
  2. `TF`/`BF` in `TMODE`/`BMODE` (`D_F`, `C_F`, `F_0`, `F_1`) are the **register feedback lines**
     (`T_FEEDBACK_SEL`/`B_FEEDBACK_SEL` 0/1 = FF?0/FF?1, inverted like routed inputs), not the
     F inputs. Evidence: the init counter's LSB (`LAB.014.007.0`, `D_F`, `T_FEEDBACK_SEL 1`) becomes
     a toggle FF and the counter reaches terminal count at exactly 2^20; with the F-input reading it
     sticks and the FSM never leaves init. Every state FF of this FSM is fed by a `D_F` LUT.
- pinmap.py also missed HMC-bypass ports without inverter lines (above), and netlist.py's pin seeds
  ignored GPIO `DATAIN.3` (registered input path). Both fixed.

## Open questions

- **U4's second DQM** ("chip A"'s enable). Not a constant pin (hwtest v3), not a controller-1
  pin. Candidates: C13/C15 (stock: 0 outside controller 2's MRS), then the other logic-driven
  pins hwtest leaves as weak pull-ups (G6, G8, F14, H14, H15, L7, F10). A test core that runs
  controller 2 at stock idle levels and switches C13/C15 per pass answers the first. A
  continuity check on U4 (TSOP-54 x16: LDQM pin 15, UDQM pin 39) answers it directly.
- C13/C15's role on the U5/U16 side (DQM, CKE or G2's A11). Driving them low (their stock level
  outside MRS) is the safe default.
- **G2's data pins are open drain in stock** (the stock core only writes 0x00 there). A real
  controller needs them push-pull. Push-pull on an SDRAM DQ line is what G1 and controller 1
  already do, but it isn't a setting spc.cor uses on those pins (see the pin-safety rule in
  `notes/STATUS.md`). A rule-compliant first test can write through open drain plus weak
  pull-ups (release the 1-bits, wait a few µs for the pull-ups, then issue the WRITE).
- Controller 2's A0–A9 order (only N6/R7 = A4/A5 known, enough to copy the MRS) and BA0/BA1 on
  E9/C9. Neither matters functionally.
- BA0 vs BA1 on AA15/AB15; A11 = N2 is by elimination. Neither matters functionally.
- A0–A6 identity on controller 1 (needed only for a different MRS than Analogue's): verify on
  hardware.
- DDIO high/low data index (AB11/H8 polarity).
- Client S's clock (`CMUXHG.000.022.3`, dynamic switchover) and what the stock core stores in
  the SDRAM.

## Recommendation for our controller (SNES ROM ≤ 6 MB)

- **Use the x8 pair** as one x16 bus: pins above, shared CLK AB11. **Columns are 9 bits (512 per
  page, hwtest v2)**: one bank holds 4096 rows × 512 columns × 2 B = 4 MB, so a 6 MB ROM needs
  two banks (word address = {bank[0], row[11:0], col[8:0]}). Until chip A works, only the high
  byte (chip B) is usable: 8 MB as an x8 memory.
- **Clock 85.909 MHz** (4 × SNES master clock; `pllpatch.py solve 85.90908` → frac8, C=7). Use
  **CL2** if the -6 datasheet allows CL2 at 11.6 ns (check tCK(CL2)), else CL3; the stock core runs
  the same chips at 115.9 MHz/CL3. A random 16-bit read (PRE-less, banks closed: ACT, tRCD 2, READ,
  CL 2–3) takes ~6–7 cycles ≈ 80 ns, far inside one SNES CPU cycle (24 SDRAM clocks).
- **MRS**: BL1 or BL2, sequential. Under the likely mapping: CL2/BL1 = 0x020 (U1 high only),
  CL3/BL1 = 0x030 (U2, U1), add AB13 for BL2. For a first bring-up you can copy Analogue's exact
  pattern (AB13 AA13 AB12 U2 U1 high = full page/CL3) and stop every read with BST, which works
  whatever the A0–A6 order is.
- **A10 = AA14**: 0 for READ/WRITE (no auto-precharge until A10 is confirmed), 1 for PRE ALL.
- **Init**: CKE is presumably tied high; NOP ≥ 100 µs (stock: 9 ms), PRE ALL, 2 × REF ≥ tRC apart,
  MRS, ≥ 2 cycles, then normal operation. **Refresh every ≤ 15.6 µs** (4096 / 64 ms). Don't copy the
  stock 20.7 µs.
- **No byte writes**: DQM isn't under logic control, so write whole 16-bit words. ROM loading is
  fine; keep SNES WRAM/SRAM/BSRAM in M10K.
- **SDRAM clock out**: nextpnr has no DDIO or PLL-to-pin path. Options, in order of effort: (a)
  drive AB11 from fabric as an inverted copy of the controller clock (`~clk` through a LUT; ≈180°
  plus an unknown routing delay, fine at ≤ 50–86 MHz if read capture uses a tuned edge or cycle);
  (b) a post-route bitstream patch copying spc's AB11 setup (`OUTREG_MODE_SEL DDR`,
  `DATAOUT.1` inverter, IOE `CLKOUT.0` from a CMUXVG fed by a phase-shifted fPLL counter), like
  `pllpatch.py` does for clocks. Start (a) at 42.95 MHz with a memory test core, then raise it.
- **Read capture**: in fabric (no IOE input registers in nextpnr). Make the capture cycle offset
  after READ (CL + 0/1) and the capture clock edge configurable, and sweep them with a test pattern
  on hardware.
- Drive the second controller's pins to a safe idle, or leave them as inputs. Changed (23 Oct):
  decoded ("Controller 2"); a core that uses U5/U16 drives them as listed there.
