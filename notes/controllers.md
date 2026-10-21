# Controller ports in spc.cor (JB7.2)

Decoded from `build/spc.bt` (Analogue's spc.cor) with `tools/netlist.py` and a cycle model in
`~/scratch/padre/` (throwaway). Oct 2026. Tags: **[confirmed]** (two independent lines of
evidence), **[likely]** (clean decode, one line of evidence), **[guess]**.

## Summary

- **The FPGA reads the pad, not the PIC32** [likely]. spc.cor contains a self-contained poller:
  one serial input (T12) and two output nets (P14, and J13 + K16 driven from one FF). It runs
  on its own after power-up and needs no input from the PIC. The captured bits go into
  registers that the PIC can read over the bank-4A link (`notes/pic-link.md`, status reads at
  `0x2000_0000`–`0x2003_0000`).
- **Only one data line is read.** No other pin in spc.cor behaves like a pad input. Port 2
  data, the D1 lines and IOBit are either on pins spc.cor leaves unconfigured or not wired to
  the FPGA. Their pins are unknown.
- **Roles**, from a cycle model that needed one assumed polarity fix (see Derivation):
  - P14 = LATCH;
  - J13 and K16 = CLOCK, the same signal on two pins (most likely port 1 and port 2 clock);
  - T12 = port 1 DATA (D0), inverted on input so that a stored 1 means the line is low
    (pressed).

## Pin table

| pin | bank | dir in spc.cor | role | conf |
|---|---|---|---|---|
| T12 | 4A | input, no pull-up, no I/O standard set (pure input) | pad DATA, port 1 D0 | [likely] |
| P14 | 4A | push-pull output, `V2P5_50OHM`, OE always on | LATCH | output from the poller [confirmed], latch role [likely, model] |
| J13 | 7A (HMC bypass `IOINTDQSBDOUT.4`) | push-pull output, `V2P5_50OHM` | CLOCK (one of the ports) | output from the poller [confirmed], clock role [likely, model] |
| K16 | 7A (HMC bypass `IOINTDQDOUT.64`) | push-pull output, `V2P5_50OHM` | CLOCK (the other port) | same as J13 |
| port 2 D0, D1 ×2, IOBit ×2 | ? | not used by spc.cor | – | unknown |

"Confirmed" for J13/K16 as poller outputs: they are driven combinationally from
`LAB.029.011.8` (= `029.011.5.FFT0 & 029.011.1.FFB1`), which is inside the same register
cone as P14 and the T12 shift enable. A route trace (`tools/trace.py back
HMC.011.045:IOINTDQDOUT.64`) and the netlist agree on this. `build/spc-pinmap.txt` misses
both pins: it lists only the default HMC OE for them, not the fabric-driven bypass data port.
The same blind spot hides about 25 other top-bank outputs (the x16 SDRAM, see below).

### Earlier candidates, now explained

| pins | what they are | conf |
|---|---|---|
| H11 G12 J7 J9 K7 N8 (+F12 J11 D12 D13 E12 C13 …) | x16 SDRAM DQ (top bank): bidirectional, shared OE `LAB.020.021.0:FFB0`, fabric data-out via HMC bypass, inputs into wide registers/adders next to the other SDRAM logic | [likely] |
| A7 B6 B7 C6 C8 C9 D7 E9 F7 G8 H6 H9 L7 F14 … | x16 SDRAM address/control (HMC bypass ports even carry RAS/CAS/WE/CS/CKE names) | [likely] |
| U22 | PIC link /WR (`notes/pic-link.md`) | [likely] |
| G13, H15, F10 | logic in the 148.5 MHz / 42.686 MHz / video domains, not the poller | [likely not pads] |
| J18 (in), H18, J19, M8 | PCM1808 cart-audio ADC: J18 = DOUT sampled on 3.072 MHz BCLK into DSP blocks; H18 = 12.288 MHz (SCKI), J19 = 3.072 MHz (BCK), M8 = LRCK (same FF as HDMI LRCLK K17) | [likely] |
| B11 A8 B10 A10 A9 A12 B12 C16 | open-drain, all from `MLAB.023.040.2:FFT0`, each read back separately into the link read mux (`0x01xx_xxxx` region). Their state machine is in the 148.5/42.686 MHz domain (`024.040`/`025.040`) and has no connection to the poller. Not pads; purpose unknown (shared-bus or reset/enable line read back per chip?) | [likely not pads] |
| G6 | open-drain, `LAB.039.041.8:FFT1`, read back. Not pads | [likely not pads] |

## The poller

All of it is in `LAB.029.003`, `029.010–013`, `032.013`, `036.012–014` and `024.015`/`025.015`
(`python3 tools/netlist.py build/spc.bt --back 10 --fwd 0 LAB.029.011.8:FFT0
LAB.029.011.2:FFT0 LAB.029.012.5:T LAB.029.012.5:B LAB.024.015.5:T`). Its only leaf input is T12.

- **Clock**: `CMUXHG.000.022.3`. This is a global with `INPUT_SEL 20` = dynamic clock
  switchover; `SWITCHIN` comes from FFs in `LAB.001.022`. The switch choices
  (`CLK_SELECT_A/B/D = 3`) are not decoded. [guess] It picks between the left fPLLs' SNES-rate
  outputs: FPLL.000.000 C0 = 21.477 MHz (NTSC master clock) and FPLL.000.037 C3 = 21.6 MHz
  (that fPLL's DPRIO is wired to logic, so it may be retuned, e.g. for PAL). Times below are
  given in clocks and at 21.477 MHz.
- **Power-on delay** [likely]: a 22-bit saturating counter (`036.013`, `036.014` + LSB
  `036.014.2.FFB1`) holds the whole FSM in sync clear until it reaches all ones. That is
  2^22 clocks ≈ 195 ms. The outputs are also gated by a sticky "first cycle done" FF
  (`029.011.1.FFB1`), so P14 and J13/K16 are 0 until the first poll.
- **Interval timer** [likely]: a 20-bit down-counter (`032.013` carry chain; the low bits live
  in `029.012.x`/`029.011.3–4`). When it reaches 0 it reloads with a state-dependent constant.
  The reload LUTs use plain D_E/C_E/E_1 modes, so these constants are reliable:

  | reload + 1 (clocks) | µs @ 21.477 MHz | reading (model) |
  |---|---|---|
  | 333 318 – 333 750 | ≈ 15 520 | idle wait between polls (the "b" state) |
  | 385 – 433 | 17.9 – 20.2 | latch high / clock high |
  | 161 – 177 | 7.5 – 8.2 | first clock-low after latch |
  | 13 – 17 | 0.6 – 0.8 | clock low pulse |

- **Bit counter** [likely]: `036.012`, a 7-bit down-counter. It loads 32 at the start of a
  poll and steps once per bit, so a poll covers 33 clock edges / 34 samples. More than a
  standard pad's 16 bits are clocked, which would also cover a mouse or the 4 ID bits.
- **Data path** [likely]:
  - T12 → `029.003.2.FFB0` (= ~T12, one synchroniser FF on the poller clock).
  - → shift register: at least 22 FFs in `024.015`/`025.015.7`, CLK2 (inverted = falling
    edge), shift enable `029.012.5.B` = timer-zero ∧ FSM bit `029.011.9.FFT0`.
  - → parallel capture into `025.015.x`/`024.015.2/5/6` (link clock domain, enable
    `029.012.5.T` = timer-zero ∧ wait state).
  - The capture is cleared unless six of the shifted bits match a fixed pattern
    (`024.015.5.T`), a framing/ID check.
  - Captured bits feed the link read mux (`025.018.x`, `026.017.x`, `025.019.0`) and a second
    register stage (`025.015.5/6/8`).
  - I could not make the check pattern fit a standard pad for any bit count, so the exact
    bit-to-shift-stage mapping (and which bits the PIC sees) is [guess].

## Timing (cycle model, [guess] for the sequence, [likely] for each duration)

One period = 347 533 clocks ≈ 16.18 ms (61.8 Hz at 21.477 MHz):

```
t (clocks)   P14  J13/K16
0            0    0        capture previous poll, idle wait (333 326 clocks ≈ 15.5 ms)
333 326      1    1        LATCH high (P14), clock goes high with it
333 711      0    0        latch falls; sample bit 0; clock low 173
333 884      0    1        clock rises (pad shifts)
334 285      0    0        clock falls; sample next bit; low 13 clocks (0.6 µs)
334 298      0    1        clock rises; high 401 clocks (18.7 µs)
... 33 clock periods of 414 clocks (19.3 µs) ...
347 533      0    0        last sample, capture, back to wait
```

- Latch ≈ 18 µs (SNES: 12 µs); bit period ≈ 19.3 µs (SNES: 12 µs).
- Data are sampled at each clock falling edge, 18.7 µs after the rising edge that shifted the
  pad.
- The clock idles low between polls; on a real SNES it idles high. The 4021 ignores this
  because the latch is high when the clock rises with it.
- If these are the real pad levels, the board's drivers are **non-inverting**. With inverting
  transistor stages, the pad would see the latch high for 15.5 ms of every 16.2 ms, which is
  still a valid parallel load, but the clock would then be low-idle with 18.7 µs low pulses.
  Either way the protocol works.

## Derivation (how far to trust it)

1. **Finding the block.** I tracked every input with fabric loads; T12 is the only one not
   explained by SDRAM, the PIC link, audio or the open-drain group. It feeds a long shift
   register whose capture register is readable over the link. P14, J13 and K16 come from the
   same autonomous FSM, which has no other inputs.
2. **netlist.py gaps found on the way** (relevant to anyone using it):
   - **`[TB]_FEEDBACK_SEL`**: in F modes (F_0/F_1/D_F/C_F), with this bit set, the half's F
     select input (TA/BA in F_0/F_1, the bit-5 select in D_F/C_F) is the ALM's own register
     (the clocked one of FFT0/FFT1 or FFB0/FFB1), not the routed F pin.
     - Evidence: the bit only ever appears in F (and RAM) modes. The model makes the
       power-on counter a sane 22-bit saturating counter, where the tool's reading leaves it
       stuck at 0. It also turns the "stuck" `020.015` counter from `notes/pic-link.md` into
       a counter (`(1)+(1)+cin` becomes `(020.015.1.FFB1)+(1)+cin`).
     - Implemented as a subclass in `~/scratch/padre/fbdesign.py`; `tools/netlist.py` is
       unchanged.
   - **LAB CLK2 default**: the tool maps CLK2 to CLKA (CLKIN.0). In `024.015`/`025.015` that
     would put one shift chain on two different clocks. CLK2 → CLKB (CLKIN.1 = poller clock
     there) makes it consistent. [guess]
3. **The cycle model** (`~/scratch/padre/search.py`) hand-codes the FSM equations that
   `fbdesign.py` prints (own-F convention as in pic-link.md, plus the feedback model), with
   reload constants evaluated from the LUTs (`reload.txt`).
   - As decoded, the FSM dies after its first state.
   - Flipping exactly one LUT (`029.011.9.T`, a D_F-mode half without feedback, the FSM bit
     "a") gives the periodic poll above. Of the other 31 single/multiple polarity variants,
     none gives a regular period with one capture per poll and a latch-like pulse.
   - That flip is an assumption: it is why the sequence and the latch/clock assignment are
     [guess]/[likely] rather than confirmed.

## Open questions

- Pins for port 2 data, the D1 lines and IOBit (not configured by spc.cor). They need a probe
  on the board, or a test core that samples candidate unconfigured pins while a pad is held.
  Beware the cart-bus shifter direction pins.
- Whether the board's latch/clock drivers invert (Q1–Q7 near J5/J6), and so which polarity the
  pad really sees.
- Which shift stages end up in which link status byte, and what the six-bit framing check is.
- The real frequency of `CMUXHG.000.022.3` (clock switchover not decoded).
- Whether J13 = port 1 clock and K16 = port 2 clock or the reverse (irrelevant while both get
  the same signal).

## Recommendation for a test core

Only use the pins and I/O settings spc.cor itself uses for the pads:

- **Outputs (push-pull, not open-drain, OE always on)**: P14, J13, K16. rbf2cor copies spc's
  `DRIVE_STRENGTH V2P5_50OHM` for them. Drive J13 and K16 with the same signal, as spc does.
  J13/K16 are top-bank (7A) pins that spc reaches through the HMC bypass. nextpnr should be
  able to place a plain output there, but check that the built `.cor` drives `GPIO.042.045.1`
  / `GPIO.044.045.3` and nothing else in bank 7A.
- **Input**: T12, no pull-up (spc: `USE_WEAK_PULLUP 0`). Treat it as active-low data
  (0 = pressed), with a 2-FF synchroniser.
- **Leave everything else undriven**: the open-drain group (B11 A8 B10 A10 A9 A12 B12 C16), G6,
  the SDRAM pins, and every pin spc doesn't configure (cart-bus shifters, unknown port-2
  lines).
- **Timing**: copy the stock core rather than real-SNES timing.
  - Wait ≥ 200 ms after configuration before the first poll.
  - Then once per frame: P14 high ~18 µs; J13/K16 clock with ~19 µs per bit and a short low
    pulse; sample T12 at each clock falling edge; ≥ 16 bits.
  - Real-SNES timing (12 µs latch, 6 µs/6 µs clock) should also work, since the pad is static
    CMOS.
- **To settle the open polarity/role questions safely**, make a test core that:
  - shows T12 live on screen, plus the 16 bits from a poll;
  - alternates every few seconds between "P14 = latch, J13/K16 = clock" and the swapped
    assignment, and between normal and inverted output polarity.

  All four combinations only toggle pins that spc already drives as push-pull outputs.
