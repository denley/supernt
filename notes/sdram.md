# SDRAM interface of spc.cor (JB7.2)

Reverse-engineered from `build/spc.bt` only (mistral decompile of Analogue's `spc.cor`), by gate-level
extraction (`tools/netlist.py`; the two decode fixes in "Method" are now part of the tool) and cycle
simulation of the extracted controller. Oct 2026. Init and refresh re-simulated from power-up with
the fixed tool (nothing forced); changes marked "Changed". Confidence tags: **[confirmed]** = read directly from the bitstream
or forced by the simulated command sequence; **[likely]** = the only reading consistent with several
independent checks; **[guess]** = plausible, not checked.

## Summary

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
| AB10 | 3B | constant output (`DATAOUT.0` inverted, nothing routed), same IOE pair as AB11 | CKE? | guess | |
| Y3 (2A), W9 W8 (3A), Y9 Y10 R11 R10 Y11 (3B) | | open-drain outputs, data not routed | DQM / tie-offs? | guess | constant; next to the SDRAM pins; value of an unrouted DATAOUT unknown |

Notes on the table:

- **The 128 Mbit x8 part has 12 row bits (A0–A11), not 13**: 4 banks × 4096 rows × 1024 columns
  × 8 (4K refresh) [datasheet, from memory; check]. So the 18 fabric outputs are exactly A0–A11 +
  BA0/BA1 + CS#/RAS#/CAS#/WE#, and nothing drives CKE or DQM.
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

## Top bank / x16 AS4C8M16SA

Top-bank pins driven through HMC bypass ports whose route line has no matching `i HMC …` inverter
line (`r X HMC.011.045:IOINT…DOUT.n ; PIN`) were missed by `pinmap.py`. Changed: fixed,
`build/spc-pinmap.txt` now lists all of the pins below (15 more fabric-driven top-bank pins; it
takes the bypass table from `tools/cvinfo hmc`). Following those routes, fabric drives many
top-bank pins, not just defaults:

- **Second memory controller, 148.5 MHz** (FPLL.054.000 C5 via CMUXVG.021.000.3; LABs x=19–21,
  y=20–24), with its clock out on **H8** (DDIO like AB11, IOE `CLKOUT.0` ← CMUXVG.021.000.2 =
  FPLL.054.000 C8, same PRESET 5 / PH_MUX 7 → −2.04 ns). That clock is why the earlier notes took H8
  for the x16 SDRAM clock. M22's HDMI pixel clock comes from FPLL.000.037 C1, not from this PLL.
  - 8-bit bidirectional bus with one shared OE FF (`LAB.020.021.0:FFB0`): N8 (3B), J7 J9 K7 (8A),
    H11 G12 F12 J11 (7A).
  - 17 outputs: N6 P6 M6 P7 R7 P8 R9 (3A/3B, plain GPIO) and H6 F7 E9 D7 C8 C9 H9 D12 E12 D13 (via
    HMC bypass). By ball position these all sit in one block (rows C–R, columns 6–13), which fits
    one TSOP. 10 of them are 4-way muxes of address-like registers, E9/C9 are a pair like AA15/AB15
    (bank?), H9 D12 E12 D13 are pure FSM outputs (command lines), and M6 is a sticky flag.
  - Simulated: idles 2^16 cycles (441 µs), then a short command sequence with two commands 17
    cycles apart, an all-zero step with N6 and R7 high (mode register?), and then a 2-command block
    every **1092 cycles (7.35 µs)**. That pattern is an SDRAM init + refresh, but no assignment of
    H9/D12/E12/D13 to CS#/RAS#/CAS#/WE# decodes it cleanly (with or without an assumed HMC-bypass
    inversion or per-pin skew). **Roles not determined** [guess: x16 SDRAM used 8 bits wide].
- Other fabric-driven top-bank pins, from unrelated logic: A7 C6 B6 B7 C13 C15 D17 (LAB.025.041), G8 L7
  (LABs y=44), F14 (025.024), H14 (026.023), J13 K16 (029.011), G13 (020.023.6), H15 (026.026),
  F10 (MLAB.013.033); the open-drain group A8 B10 A10 A9 B12 A12 C16 + B11 (`MLAB.023.040.2:FFT0`);
  G6 (open drain); H18 ← CMUXVG.025.045.0 (FPLL.054.037 C7, 12.29 MHz) and J19 ← CMUXVG.025.045.2
  (C5, 3.07 MHz) as clock outputs; inputs B12 C16 F12 J11 J18 via `IOINTDQDIN`.

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

- What drives CKE and DQM: board ties, AB10 (constant output next to AB11), or the undriven
  open-drain pins (Y3 W9 W8 Y9 Y10 R11 R10 Y11)? Their constant values are unknown (unrouted
  `DATAOUT` level not calibrated). A continuity check on U5/U16 (TSOP-54 x8: CKE pin 37, DQM pin 39; check the datasheet) answers it.
- BA0 vs BA1 on AA15/AB15; A11 = N2 is by elimination. Neither matters functionally.
- A0–A6 identity (needed only for a different MRS than Analogue's): verify on hardware.
- DDIO high/low data index (AB11/H8 polarity).
- Second controller (148.5 MHz, H8 clock): command decode, and whether it is the x16 chip.
- Client S's clock (`CMUXHG.000.022.3`, dynamic switchover) and what the stock core stores in the SDRAM.

## Recommendation for our controller (SNES ROM ≤ 6 MB)

- **Use the x8 pair** as one x16 bus: pins above, shared CLK AB11. One bank holds 4096 rows × 1024
  columns × 2 B = 8 MB, so a 6 MB ROM fits in bank 0 (word address = {row[11:0], col[9:0]}, or
  interleave banks for faster random access).
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
- Drive the second controller's pins (the x16 chip?) to a safe idle, or leave them as inputs.
  Until its decode is done, don't touch H8/N6–R9/the top-bank group.
