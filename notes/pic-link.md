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
- **The PIC polls `0x2004_0000` (2 bytes) before it sends a file** (22 Oct console runs, section
  "Status 0x2004_0000"), right after writing 0 to `0x1000_0500`. It is the status of the video
  PLL's (FPLL.000.037) reconfiguration controller, which is Altera's `altera_pll_reconfig`:
  bit 1 = PLL locked, bit 0 = the controller's `mgmt_waitrequest`; the same byte at every
  `0x2xx4_xxxx` address. **The PIC wants 0x02 0x02** [confirmed: hwtest v3 on the console,
  22 Oct, the fallback's 02 got it past the poll at once]. hwtest v1 answered `02 00`, v2
  `03 03`, v3's emulated IP `03 03` (stuck waitrequest); the PIC polled on each time.
- **After the poll** the PIC reprograms the video PLL through the block (25 register writes,
  `0x1000_00C4` 4 times; the HDMI signal drops and comes back), writes more set-up blocks, and
  then runs the **SPC player's UI loop** (every ~32 ms: 01 → `0x1000_D120`, read 2 bytes at
  `0x2000_0000` and at `0x2001_0000`, twice). Those are the pad 1 buttons
  (`notes/controllers.md`, "Link registers"); the file didn't come within 150 s while v3
  answered 00 there (section "After hwtest v3"). With the pad answered (v4), button presses
  make the PIC redraw a 4 KB screen of 2-byte cells at `0x1018_0000` (section "After hwtest
  v4 / v4b"); the file still didn't come.
- The 21 Oct capture contains only writes (U21 never went low). In true bit order they are a register
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
| `0x2xx0_0000` … by bits 19–16 | internal status regs: `0x2000_0000`, `0x2001_0000`, `0x2002_0000` full bytes and `0x2003_0000` bits 2–0 = **the controller poller's capture** (`0x2000` = buttons 7–0, `0x2001` bits 3–0 = buttons 11–8, 1 = pressed; `notes/controllers.md`, "Link registers"); `0x2004_0000` bit 1 includes `M013.020.5.FFB0` (= FPLL.000.037 LOCK0, synchronised), bit 0 `014.016.2.FFT0`; `0x2006_0000` bit 3 `025.018.7.FFT1`, bit 1 as `0x2004`; `0x2008_0000` bits 1–0 `025.019.0.FFT1` `025.019.1.FFT1` = the poller's device type (01 = standard pad); `0x2009_0000` full byte from `026.017.x`/`025.018.x`/`025.015.6.FFB1` (held registers `021.013.x`, not the pad) |
| anything with bit 28, 30 or 31 set (`0x1xxx_xxxx` …) | 0x00 |

**Changed:** the earlier table had constant bits (region `0x0?` bit 6 = 1 and bit 1 = 0;
`0x2002` bit 0 = 1; `0x2008_0000` = `0000_00x1`; `0x2009_0000` bits 6, 5, 2 = 1). They were
artefacts of reading an unrouted F pin (= 1) where the LUT really reads its own register
through the feedback line; all of them are registers. The `0x01xx_xxxx` row said "falling
clock edge, x16 SDRAM DQ?, bits 1–0 read 0": the falling edge was the clock-select misreading,
and bits 1–0 (A9, B10, A10) were missed because the tool ignored `DATAIN.3` and HMC-bypass
routes without inverter lines.

The PIC polls `0x2004_0000` (2 bytes) before it sends a file: see "Status 0x2004_0000" below.
Simulated idle values (whole link clock domain from power-up, nothing written, video PLL
locked): `0x2004_xxxx` = 0x03 (or 0x02, see below), `0x2000`–`0x2003` and `0x2006`–`0x2009` =
0x00 [likely].

## Status 0x2004_0000 (the PIC's wait before the file)

Console run 22 Oct 2026 (hwtest v1, `notes/buslog-2026-10-22-hwtest.md`): after its set-up
writes (`0x1000_xxxx`/`0x1010_xxxx` registers, a 0x1EAF-byte block at `0x0000_0000`, 0x80 bytes
at `0x111F_8100`, 0x2500 bytes at `0x1017_0800`, a 3-byte write `00 00 FF` to `0x1000_9018`
repeated ~500 times), from T = 406 ms on the PIC only polls: address `0x2004_0000`, A = 3 latch
(the "other writes" rate fits), two reads. v1 answered `02 00` (CRC-checked) and the PIC polled
~305 000 times a second for the rest of the minute; the file never came. [confirmed: log]

Decode (`~/scratch/hs/`, throwaway: `hs.py` = the link cone simulator of `~/scratch/netfix`
extended with the status bit and the PLL ports, `scan*.py`, `dec*.py`, `lock0.py`, `seq.py`):

- **Inputs** [confirmed]: the register cone of bit 0 (`014.016.2.FFT0`) on the link clock is 493
  registers whose only outside inputs are the 13 link pins and `FPLL.000.037` `LOCK0` and
  `PHASE_DONE0`. Nothing from the SNES, audio, SDRAM or video domains: the status depends only on
  what the PIC writes and on the video PLL.
- **The block is a reconfiguration controller for FPLL.000.037** (the video PLL: C1 = HDMI pixel
  clock, C6 = 148.5 MHz) [confirmed: port routes]. Link-domain FFs drive its DPRIO port
  (`DPRIO0_WRITE` `MLAB.009.017.1:FFT1`, `_READ` `.2:FFT1`, `_REG_ADDR[5:0]`, `_WRITEDATA[15:0]`
  (`LAB.005`/`006`/`MLAB.004`/`016.014`), `_BYTE_EN[1:0]`, `_RST_N` `016.019.2.FFB1`,
  `_SER_SHIFT_LOAD`, `_MDIO_DIS`; `DPRIO0_CLK` = the link clock), its dynamic phase shift
  (`PHASE_EN0` `002.044.7.FFT0`, `UP_DN0` `MLAB.013.018.2:FFB0`, `CNT_SEL0[4:0]` `017.021.x`,
  `PHASE_DONE0` back) and `NRESET0` (`010.018.2.FFB1`). DPRIO read data is not used.
- **Writes** [likely: symbolic decode of the third address stage + simulation from the pins]:
  - `0x1000_00C4` (the only address that loads them; bit 10 must be 0): D0 → `010.018.8.FFT1`, a
    reset for the block (`016.019.1.B` = D0 | ~DPRIO_RST_N sync-clears its state machine, and it
    async-clears the LOCK0 synchroniser `M009.016.x`); D1 → `010.018.2.FFB1` = the PLL's
    `NRESET0` port.
  - `0x1000_0500`–`0x1000_05FF`: 64 × 32-bit registers. Every write latches its byte by
    address bits 1–0 into lane registers (`MLAB.018.016.x` lane 0, `MLAB.013.018.7/8` lane 1,
    `LAB.014.018.x` lane 2, for any address), and a write with bits 1–0 = 3 inside the window
    (`017.019.9.B`) commits the word to register bits 7–2. The shape (6-bit word address, 32-bit
    data, phase-shift and counter registers) is that of Altera's `altera_pll_reconfig`
    (0 mode, 1 status, 2 start, 3 N, 4 M, 5 C, 6 phase shift, ...) [guess].
- **Read** [likely: simulation]: `0x2xx4_xxxx` (bits 31–28 = 2, 19–16 = 4; bits 1–0 and the
  rest ignored, so `0x2004_0001` reads the same) = `{6'b0, bit 1, bit 0}`.
  - Bit 1 follows `LOCK0` (simulated 0x01 with LOCK0 = 0, 0x03 with LOCK0 = 1).
  - Bit 0 (`014.016.2.FFT0`) = `014.016.8.T | …` with `014.016.8.T` = ~(busy | DPRIO_RST_N &
    ~D0(`0x1000_00C4`) & `010.018.0.FFT1` & LOCK0-synchronised), where `010.018.0.FFT1` is a
    sticky "timer done" flag set when a small counter (`010.018.4/5/7`, ~64 clocks) runs out
    after the block's reset synchroniser (`M009.019.5/6`) releases. What the counter does
    depends on two clear readings the tool can't settle: its FFs have a sync clear (the
    per-half `TSCLR_DIS`/`BSCLR_DIS` bits are clear exactly on them) and `netlist.py` also
    reports an async clear "(?)" from the same `DATAIN.3` (`M009.019.6.FFB1`, the synchronised
    reset release). Simulated from power-up, nothing written, LOCK0 = 1:
    - sync clear as decoded (with the async clears as printed or inverted): the counter is held
      at 0 once the reset is released, the flag never sets, bit 0 stays 1: **0x03** at
      `0x2004_0000` and `0x2004_0001`;
    - without that sync clear (async clear only, active in reset): the flag sets ~410 clocks
      after configuration and bit 0 drops: **0x02 0x02**.

    The first reading leaves a counter that can never count, which is odd; the second ignores
    explicit sclr-enable bits. So the stock idle answer is **0x03 or 0x02 (both bytes)**
    [likely for "one of the two", guess for which]. Either way bit 1 = 1 and both bytes are
    the same, unlike v1's `02 00` (`0x2004_0001` read 0x00 there): if the PIC checks the second
    byte, v1 failed on that alone. Bit 0 can also go 0 through the busy flag
    (`014.019.1.FFT0`, set by a commit in the `0x1000_05xx` window); a simulated commit of the
    start register (after mode = 0 and an M value) did not start any DPRIO traffic, so when the
    stock core reports busy is open [guess].
- **Reading**: the PIC checks the video PLL / reconfiguration status before it sends the file
  and wrote nothing to the block before (the logged case) [likely]. hwtest v2 answers 0x03 at
  every `0x2xx4_xxxx` address and steps to 0x02, 0x01, 0x00, 0xFF while the PIC keeps polling
  without sending data (`link_logger.sv`, `notes/hardware-tests.md`); the console run settles
  which one the PIC wants. `link_loader.sv` answers 0x03 until then.
  Whether the PIC later reconfigures the video PLL through `0x1000_00C4`/`0x1000_05xx` (other
  video modes?) and then waits for bit 0 again: watch for those addresses in the v2 log.

### After hwtest v2 (22 Oct, second console run)

v2's run (`notes/buslog-2026-10-22-hwtest.md`, second part): the PIC's set-up is the same as in
v1; its last writes before the poll are a ramp of `0x1000_D110` (1 byte) / `0x1000_D114`
(16 bits) over ~260 ms, `0x1010_0033` = 00 and then **4 bytes of 0 to `0x1000_0500`** (register
0 of the reconfiguration block), and from T = 406 ms it polls `0x2004_0000` forever. v2
answered `03 03` the whole time: its fallback stepping never ran because Quartus (power-up
don't care) had turned the "fixed" flag into a constant 1 (fixed in `quartus/common/supernt.tcl`).

**The block is Altera's `altera_pll_reconfig_core`** (Quartus IP,
`ip/altera/altera_pll_reconfig/`): register map 0 mode, 1 status, 2 start, 3 N, 4 M, 5 C,
6 phase shift, 7 K, 8 bandwidth, 9 charge pump, 0x1C VCO, 0x1F MIF, 6-bit word address, 32-bit
data [likely: same port set, same 64-register window]. The decode's odd timer is the IP's reset
logic: `self_reset` (counts to 340 after reset) and `fpll_dprio_init` (a 7-bit counter that
writes 0 to DPRIO addresses 0–63, then finishes after a few more clocks; its only clear is the
**asynchronous** one from a 2-FF reset synchroniser, `rst_n[1]` = the decode's `M009.019.5/6`).
In iverilog, Altera's RTL drops `mgmt_waitrequest` **415 clocks** after reset, matching the
decode's "flag sets ~410 clocks after configuration" under the reading *without* the sync
clear; the other reading (counter held at 0, bit 0 stuck at 1) contradicts the RTL. In the IP,
`mgmt_waitrequest` = (mode = waitrequest) ∧ (¬locked ∨ reset ∨ ¬init done ∨ reconfiguring ∨
phase shift running), and 0 in polling mode; the decoded bit 0 has that shape
(`014.016.8.T` = ¬busy ∧ ¬(DPRIO_RST_N ∧ ¬reset ∧ init done ∧ locked)). So:

- bit 1 = locked, bit 0 = `mgmt_waitrequest` (1 = busy); idle and locked: **0x02**, both bytes
  [likely; v1's `02 00` failed, so the PIC checks the second byte too, or reads 16 bits];
- writing 0 to register 0 selects waitrequest mode (also the reset mode, so it changes nothing),
  and the PIC then waits for "locked and not busy". Re-simulating the decoded logic with that
  write (`~/scratch/v3/stat_inputs.py`, throwaway; both clear readings, LOCK0 and PHASE_DONE0
  0/1) changes nothing either: 0x03/0x01 under the old reading, so v2's 03 03 = "busy".

hwtest v3 (`quartus/common/pll_emul.sv`): a reconfigurable fPLL like FPLL.000.037 on **H16**
(74.25 MHz × 16, outputs 148.5 / 21.6 / 148.5 MHz; spc.cor uses H16 as this PLL's reference,
an input) behind the real `altera_pll_reconfig_top`, driven by the PIC's writes to
`0x1000_00C4` (D0 = controller reset, D1 = PLL reset) and `0x1000_05xx` (lane bytes, commit on
address bits 1–0 = 3 → Avalon write to register addr[7:2], held until waitrequest drops). The
status the PIC reads is {locked, waitrequest} of that IP (candidate 0). Fallback in
`link_logger.sv`: once the PIC has made ≥ 1000 status reads, every 5 s window with status reads
and < 16 data writes steps to the next candidate: 02, 03, 01, 00, FF, bit 0 toggling per read,
03 for 1 ms then 02, 01 1 ms + 03 1 ms then 02, 00 1 ms then 02 (the timed ones restart at each
step and at every write to the block). The answer is fixed for good after 4 KB of data writes
following the first status read with no step in between (the count restarts at each step);
the screen shows the candidate, when polling began and when/with what it was fixed, plus the
PLL's lock, waitrequest, H16 and output frequencies and the block writes. The port ignores
reads until it is armed (both strobes high for 1 µs, or a write strobe with /RD high): the PIC
holds /RD low until it sets up its port, which looked like a read at power-up. `link_loader.sv`
now answers 0x02.

### After hwtest v3 (22 Oct, third console run)

v3 (`notes/buslog-2026-10-22-hwtest.md`, third part; video `IMG_3062.mov`, 155 s):

- **Candidate 0 (the emulated PLL + Altera reconfiguration IP) answered `03 03`**: its
  waitrequest stayed 1 after the PIC's write of 0 to register 0 (`pending` 1: the Avalon write
  never completed). In the iverilog model the same IP drops waitrequest after 415 clocks; on
  the FPGA it never did. Not chased further (v4 starts with 02 and shows whether waitrequest
  was ever 0); suspects: the IP's `dps_done`/`locked` inputs from `reconfig_from_pll`.
- After 5 s the fallback stepped to **candidate 1 = `02 02`** (T 0x14A2 = 5.4 s) and the PIC
  moved on at once: answer fixed with candidate 1 at T 0x14AE. [confirmed]
- Then: 25 commits to the `0x1000_05xx` block (last register 2 = start, data 0) and 4 writes to
  `0x1000_00C4` (C4 = 00 at the end), a short HDMI drop and recovery (the video PLL being
  retuned and the HDMI set-up redone, presumably), and five big write runs: `0x1006_0000` 0x2000
  bytes (CRC B5CFAF0C, T 0x14AC), `0x1010_0000` 0x28 (7B4EDA37, as before the poll),
  `0x1001_3000` 0x300 (D0C0DF2A), `0x111F_8100` 0x80 (FCB64B27, as before), `0x1018_0000` 0x1000
  (CE6B18CC, T 0x14F1). None of them is part of the chord .spc (every CRC window checked).
- From then on the UI loop above, for the rest of the run; the 1024-entry log was full after
  ~10 s (5 entries per loop). Video PLL: out 148.5 MHz before and after (024413/024414 kHz), H16
  74.25 MHz.
- The PIC never sent the file. With the loop reading the pad, it most likely waits for a
  button (a file list waiting for A/START?), and v3 answered 00 = nothing pressed.

hwtest v4: answers the pad registers like the stock core (real pad 1, plus automatic "virtual"
presses once the UI has waited 10 s: A, START, X, Y, L, R, UP, DOWN, LEFT, RIGHT, SELECT, B,
0.5 s each, 3 s apart, until a write run of ≥ 256 bytes starts; the screen shows which press
preceded it). Reads of `0x2000`/`0x2001` are counted, not logged, and the log keeps its first
512 entries plus a ring of the newest 512, so the file transfer shows on pages 2 and 3.

### After hwtest v4 / v4b (22 Oct, fourth and fifth console runs)

(`notes/hardware-tests.md`, "hwtest v4 / v4b results"; transcription in
`notes/buslog-2026-10-22-hwtest.md`, fourth part.)

- Both runs still began at candidate 0 (03 for 5 s, then 02, the PIC moving on at once): the
  candidate register's initial value sat in an ANSI port declaration, which Quartus ignores
  (`notes/quartus.md`, "Power-up values"). 02 02 stays confirmed as the answer.
- With the pad registers answered and virtual presses, the player reacts: **the PIC redraws a
  4 KB screen at `0x1018_0000`** (a full 0x1000-byte run) after START, DOWN, Y, UP, SELECT
  (back to the first screen) and B; A, RIGHT, LEFT, X, L, R changed nothing on those screens.
  Partial updates are bracketed by `0x1000_D129` = 01 / 00: after B, 16 bytes at
  `0x1018_0DE8` starting with 'T', then `20 00` x 8 at `0x0DE8` and x 4 at `0x0E6C`. So the
  screen is **a map of 2-byte cells, character (ASCII) then attribute, 64 cells per 128-byte
  row, 32 rows**; `0x0DE8` = row 27, cells 52-59, ending at cell 60 = 1920 / 32 [likely]. The
  8 KB at `0x1006_0000` (written once after the poll, first byte ED) is then most likely the
  glyph set (256 x 32 bytes: 16x16 at 1 bpp, or 8x16 at 2 bpp) and the 0x300 bytes at
  `0x1001_3000` a palette (256 x RGB?) [guess]. `0x1000_D110`/`D114` ramp down (a fade) after
  START (v4) and SELECT (v4b).
- No .spc data arrived in either run (all big runs are the UI blocks above).
- hwtest v5 captures these regions and shows them (text views, tile maps in several glyph
  formats, bit images decoded by `tools/bitdump.py`), with one press every 4 s and a screen
  dump before each, and counts only writes outside the UI's regions as "the file".

## After a file: how does the player get back to its menu? (23 Oct 2026, for snes_load v2)

Console (snes_load v1, Kirby and Gradius runs): after the last file byte the PIC writes 8 bytes
at `0x1018_0F6C` (screen cells, spaces), `0x1000_D129` = 00, `0x0000_00FE` = 06, `0x1000_0102`
= 00, `0x1000_0010` = 00, ~50 ms later `0x1000_0021` = F8, runs its UI loop once more and then
does **nothing at all on the link**: v1's address register stayed at `0x2001_0003` (the end of
that last pad read; any read or write would have moved it) for the 0.45 s / 2 s the page was
photographed, and its browser never changed again. (v1 logged reads too, except pad reads at
`0x2000`-`0x2009`, which it only counted; a frozen address register rules those out as well.)
So in "playing" mode the PIC waits on something other than the link.

Decode of `build/spc.bt` (`~/scratch/menu/`, throwaway: `xcone.py` = cross-domain backward
cone of each output pin, `allpins.py`, `h15*.py` = the link-domain cycle model of
`~/scratch/netfix` plus H15's cone):

- **No output pin carries the pad** [likely]: of all 160 configured pins only the eight link
  data pins (the read mux) and M16 (HDMI DE, through shared link-domain registers) have the
  poller's shift/capture registers in their cones; the capture registers feed nothing but the
  link read mux (forward trace). So the stock core has **no menu-combination detector and no
  interrupt line to the PIC**; whatever stops the playback is done by the PIC itself.
- Logic-driven outputs the stock core has and snes_load doesn't drive: the x16 SDRAM / 148.5
  MHz controller pins (top bank, N6-R9 etc.), the PCM1808 ADC clocks (M8, H18, J19), a group
  written over the link (`LAB.025.041`: A7 C6 B6 B7 C13 C15 D17, and the open-drain group B11
  A8 B10 A10 A9 A12 B12 C16, read back at `0x01xx_xxxx`; 245-register cones in the link and
  148.5 MHz domains), G6 (open drain, autonomous, three M10Ks: an I2C-like master?), and five
  pins with ~2200-register cones that include the link, M10Ks and DSP blocks: H14, H15, F14
  (three alike: an RGB LED PWM fits, the JB7.2 changelog mentions the SPC player's LED colour
  [guess]), G13 and F10. None is a plausible "attention" line (none depends on the pad; their
  link-side loads didn't fire for any of the post-file writes in the link-domain model). Not
  driven by v2.
- The post-file writes: `0x1000_0021` = F8 lands in the byte-lane registers of the 32-bit
  register window (lane 1: `MLAB.013.018.7`, `MLAB.013.019.3`, `MLAB.018.016.4`), i.e. a
  register at `0x1000_0020` whose consumer is on the memory side (other clock domains), not
  traced [open]; the others touch only the generic address/request pipeline in the link domain.
  Most likely "start playback / show the player screen" [guess].
- The JB documentation (SmokeMonster's Super-NT-Jailbreak README): the **menu combination is
  DOWN + SELECT** ("open the menu (SELECT and DOWN)"), and the JB6.5 changelog fixed "some games
  disabling the return-to-menu shortcut", i.e. the shortcut depends on how the game polls the
  pad. With no pad-derived output in spc.cor, the PIC must **watch the controller lines itself**
  (LATCH/CLOCK/DATA as the core drives them) [likely, not observed]. v1 polled at 1 kHz with a
  different waveform (12 us latch, 32 x 6/6 us) and nobody pressed DOWN+SELECT; v2 drives the
  stock waveform (16.17 ms, 8.3 us latch, 33 x 0.6/18.7 us, notes/controllers.md) and passes
  the pad registers through all the time, as spc.cor does.
- Fallbacks if DOWN+SELECT doesn't wake it: the console's RESET button (read by the PIC), and
  the ID666 song length (a 20 s file: whatever the player does when a song ends shows up in
  v2's log). See notes/snes-load.md, "Console test (v2)".

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
3. Reads: answer the stock status at `0x2xx4_xxxx` (0x02, both bytes [confirmed, hwtest v3]),
   the pad at `0x2000`/`0x2001` (buttons, 1 = pressed) and `0x2008` = 01 (standard pad),
   0x00 elsewhere. The PIC polls `0x2004_0000` before it sends a file and waits on a wrong
   answer (22 Oct: `02 00` and `03 03` both failed, `02 02` passed), then its player UI reads the
   pad. The other status bytes (`0x2006`, `0x2009`) are registers whose meaning isn't decoded;
   0x00 is their idle value in the simulation.

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
- What the open-drain group read back at `0x01xx_xxxx` is for, and the meaning of the other
  `0x2xxx_xxxx` status registers.
- Why the emulated reconfiguration IP's waitrequest stayed 1 on the FPGA (v3).
- What `0x1000_D120` = 01 (once per UI loop) and `0x1000_D129` are; the formats of the
  post-poll blocks (`0x1006_0000` glyphs?, `0x1001_3000` palette?; `0x1018_0000` is the
  screen, 2-byte cells); which button (or menu) makes the player send the file (hwtest v5).
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
