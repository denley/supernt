# Controller ports in spc.cor (JB7.2)

Decoded from `build/spc.bt` (Analogue's spc.cor) with `tools/netlist.py` and a cycle model in
`~/scratch/padre/` (throwaway). Oct 2026. Re-simulated after the two decode fixes went into
the tool (`~/scratch/netfix/poller.py`, `pollrun.py`, throwaway): the poller now runs from
power-up with nothing assumed; timing and the shift-register clock changed (marked "Changed"). Tags: **[confirmed]** (two independent lines of
evidence), **[likely]** (clean decode, one line of evidence), **[guess]**.

## Summary

- **The FPGA reads the pad, not the PIC32** [likely]. spc.cor contains a self-contained poller:
  one serial input (T12) and two output nets (P14, and J13 + K16 driven from one FF). It runs
  on its own after power-up and needs no input from the PIC. The captured bits go into
  registers that the PIC reads over the bank-4A link: **`0x2000_0000` = buttons 7–0 (RIGHT LEFT
  DOWN UP START SELECT Y B), `0x2001_0000` bits 3–0 = buttons 11–8 (R L X A), 1 = pressed**,
  `0x2008_0000` = device type (01 = standard pad) [likely; "Link registers" below]. The SPC
  player's UI loop reads `0x2000`/`0x2001` every ~16 ms (hwtest v3, 22 Oct).
- **Only one data line is read.** No other pin in spc.cor behaves like a pad input. Port 2
  data, the D1 lines and IOBit are either on pins spc.cor leaves unconfigured or not wired to
  the FPGA. Their pins are unknown.
- **Roles**, from a cycle model of the decoded logic (no assumed fixes any more, see
  Derivation):
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
HMC.011.045:IOINTDQDOUT.64`) and the netlist agree on this. `build/spc-pinmap.txt` used to
miss both pins (it listed only the default HMC OE, not the fabric-driven bypass data port) and
the x16 SDRAM's top-bank outputs; fixed, it now lists all of them, and `netlist.py J13` follows
the bypass too.

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
  2^22 clocks ≈ 195 ms (simulated: first latch at clock 4 194 305 = 2^22 + 1). The outputs are also gated by a sticky "first cycle done" FF
  (`029.011.1.FFB1`), so P14 and J13/K16 are 0 until the first poll.
- **Interval timer** [likely]: a 20-bit down-counter (`032.013` carry chain; the low bits live
  in `029.012.x`/`029.011.3–4`). When it reaches 0 it reloads with a state-dependent constant.
  The reload LUTs use plain D_E/C_E/E_1 modes, so these constants are reliable:

  | reload + 1 (clocks) | µs @ 21.477 MHz | reading (model) |
  |---|---|---|
  | 333 318 – 333 750 | ≈ 15 520 | idle wait between polls |
  | 385 – 433 | 17.9 – 20.2 | clock high between bits (401 in the simulation) |
  | 161 – 177 | 7.5 – 8.2 | latch high (178), latch fall → first clock low (176) |
  | 13 – 17 | 0.6 – 0.8 | clock low pulse (13) |

  (Reading column changed with the new simulation: the latch is the ~8 µs constant, not the
  ~18 µs one.)

- **Bit counter** [likely]: `036.012`, a 7-bit down-counter. It loads 32 at the start of a
  poll and steps once per bit, so a poll covers 33 clock edges / 34 samples. More than a
  standard pad's 16 bits are clocked, which would also cover a mouse or the 4 ID bits.
- **Data path** [likely]:
  - T12 → `029.003.2.FFB0` (= ~T12, one synchroniser FF on the poller clock).
  - → shift register: at least 22 FFs in `024.015`/`025.015.7`, on the poller clock's rising
    edge like everything else (changed: was "CLK2, inverted = falling edge", the clock-select
    misreading), shift enable `029.012.5.B` = timer-zero ∧ FSM bit `029.011.9.FFT0`.
  - → parallel capture into `025.015.x`/`024.015.2/5/6` (link clock domain, enable
    `029.012.5.T` = timer-zero ∧ wait state).
  - The capture is cleared unless six of the shifted bits match a fixed pattern
    (`024.015.5.T`), a framing/ID check.
  - Captured bits feed the link read mux (`025.018.x`, `026.017.x`, `025.019.0`) and a second
    register stage (`025.015.5/6/8`).
  - I could not make the check pattern fit a standard pad for any bit count, so the exact
    bit-to-shift-stage mapping (and which bits the PIC sees) is [guess].
  - Re-check with the fixed tool (`~/scratch/netfix/padmap.py`: a 4021 model loading while
    P14 is high and shifting on J13's rising edge, one button held per run): at the capture
    pulse only pad bits 11–15 are still in the poller-clock stages (`024.015.7.FFT0`,
    `.8.FFB0/FFB1`, `.4.FFB1`, `.1.FFB0`, `.9.FFT1`); bits 0–10 have been shifted past them by
    the 33 samples, and the check `024.015.5.T` stays 1 throughout. So either the capture also
    takes earlier stages from the link-clock FFs in `025.015`, or the device isn't a plain
    16-bit 4021 read. Not followed further.

## Link registers (decoded 22 Oct 2026, after hwtest v3)

hwtest v3 showed the SPC player's UI loop: every ~32 ms the PIC writes 01 to `0x1000_D120`, then
reads 2 bytes at `0x2000_0000` and 2 bytes at `0x2001_0000`, twice (`notes/pic-link.md`, "After
hwtest v3"). hwtest v3 answered 00 there, so no button reached the player. Traced from the
read mux (`~/scratch/netfix/readmap-new.txt`) back to the poller (`~/scratch/v4/chain.py`,
`srchain.py`, `padmap3.py`, throwaway; the last is `padmap.py` with `LAB.024.014`, which the
earlier attempt had left out, and a 4021 model fed from the decoded P14/J13 waveform):

- **The shift register is 33 stages long** [likely]: T12 → `029.003.2.FFB0` (= ~T12) → stage 1
  `024.015.0.FFB1` → … → stage 22 `024.015.7.FFT0` → stage 23 `024.014.9.FFT1` … → stage 33
  `024.014.5.FFB1` (all on the poller clock, enable `029.012.5.B`, one shift per clock low
  pulse). After the 33 samples of a poll, sample k (pad bit k, 1 = line low = pressed) sits in
  stage 33 − k.
- **Capture** (enable `029.012.5.T`, once per poll, after the last shift) copies stages into two
  groups of registers, then one link-clock FF per bit feeds the read mux (no enable: the PIC
  always reads the newest poll):

  | read | bit 7 … bit 0 = pad sample | cleared when |
  |---|---|---|
  | `0x2000_0000` | 7 6 5 4 3 2 1 0 (RIGHT LEFT DOWN UP START SELECT Y B) | not a standard pad and not device A |
  | `0x2001_0000` | 19 18 17 16, then 11 10 9 8 (R L X A) | high nibble: not device A; low nibble: as 0x2000 |
  | `0x2002_0000` | 27 … 20 | not device A |
  | `0x2003_0000` | bits 2–0 = samples 31, 29, 28 | not device A |
  | `0x2008_0000` | bit 1 = "not a standard pad", bit 0 = "not device A" | – |

  Capture registers: `0x2000` bits 7…0 ← `024.014.6.FFB0` `.7.FFT0` `.7.FFB0` `.4.FFT1` `.2.FFB0`
  `.1.FFB0` `.3.FFB0` `.3.FFT0`; `0x2001` bits 3…0 ← `024.014.2.FFT0` `.1.FFT0` `.6.FFT0`
  `.4.FFB0`; then the link-clock FFs listed in the read map (`025.018.x`, `026.017.x`,
  `025.015.x`, `029.020.8.FFB1`). Address bits other than 31–28, 24 and 19–16 are ignored, so the
  PIC's second byte at `0x2000_0001` is the same byte again.
- **Device checks** at capture (stages after 33 shifts): "standard pad" = samples 12–15 = 0 and
  16–32 = 1 (`024.015.2.T`, among others `024.015.8.FFT1`, `.4.T`, `.3.T`, `.1.T`, `.0.B`); device
  A = samples 12 = 0, 13 = 1, 14 = 15 = 0, 30 = 0, 32 = 1 (`024.015.5.T`), a 4-bit ID 0100 in bits
  12–15 (mouse-like: the extra bytes would be its data) [likely for the terms, guess for the
  device]. Simulated with the 4021 model: an idle pad (FFFF0000 in pad_test terms) passes the
  standard check, so the stock core answers **0x2000 = 00, 0x2001 = 00, 0x2002 = 00, 0x2003 = 00,
  0x2008 = 01** with a pad and no button held; with nothing recognised (no pad: all samples 0,
  or a 34-bit device) everything reads 0 and `0x2008` = 03.
- **Buttons 5–11 simulate as expected** [likely]: one button per run lands in exactly the
  register above (bit 5 → `0x2000` bit 5 … bit 11 → `0x2001` bit 3); bits 12–15 make the
  standard check fail (everything cleared).
- **Buttons 0–4 (B Y SELECT START UP) never arrive in the simulation**: stage 29
  (`024.014.0.FFB0`/`FFB1`) is decoded with a sync clear from the validity term `024.015.8.T`,
  which is 1 at every shift (the pattern only lines up after the last one), so samples 0–4 are
  zeroed on their way to stages 29–33. A player that could never see B or START is implausible,
  so this clear is most likely a misreading of the LAB-wide SCLR on that ALM half (the capture
  registers in the same LAB do use it) [guess]. By stage position, 0x2000 bits 4–0 = buttons
  4–0 [likely]; hwtest v4 answers all 12 buttons that way and shows on screen what it answers.
- `0x1000_D120` (written 01 before each UI read pair) does not touch any of this: the poller's
  register cone (138 FFs) has T12 as its only input [confirmed: cone and simulation], and the
  link-domain copies have no enable. In the link domain a `0x1000_D120` write only loads the
  shared lane register `MLAB.018.016.x` (lane 0, used by the reconfiguration block's
  `0x1000_05xx` window); where the posted write goes on the memory side isn't traced. It is not
  a latch or strobe for the pad [likely].
- Other `0x2xxx` registers for the record: `0x2004` = video-PLL reconfiguration status
  (`notes/pic-link.md`); `0x2006` bit 3 from `M013.031.6.FFB0` and bit 1 = `0x2004` bit 1;
  `0x2009` = 8 register bits `021.013.0–9` that hold their value (a writable register read
  back?), not the pad. Not traced further.

## Timing (cycle model, [likely])

**Changed.** The earlier sequence (latch ≈ 18 µs, clock idling low, 33 periods of 414
clocks) came from a hand-coded model with one LUT flipped. With the fixed tool the decoded
logic runs unmodified, from all-zero FFs, for 5.4 M clocks (4 polls). One period = **347 351
clocks ≈ 16.17 ms** (61.8 Hz at 21.477 MHz):

```
t (clocks)   P14  J13/K16
0            1    1        LATCH high (P14); clock (J13/K16) is high (idle)
178          0    1        latch falls (8.3 µs)
354          0    0        first clock low pulse; T12 sampled on this edge (bit 0)
367          0    1        clock rises (pad shifts), 13 clocks = 0.6 µs low
... 33 low pulses in all, every 414 clocks (19.3 µs): 13 low, 401 high ...
13 602       0    0        33rd sample
13 615       0    1        clock back high, stays high (idle)
14 015       0    1        capture into the link-domain registers
347 351      1    1        next latch
```

- Latch 178 clocks ≈ 8.3 µs (SNES: 12 µs); bit period ≈ 19.3 µs (SNES: 12 µs).
- **The clock idles high** and pulses low, the same shape as a real SNES; data are sampled
  as the clock falls, ~18.7 µs after the rising edge that shifted the pad.
- 33 samples per poll (bit counter loads 32): 16 pad bits plus 17 more.
- With these levels the board's drivers would be non-inverting; nothing in the waveform now
  looks inverted, so the earlier "maybe inverting stages" discussion is moot unless hardware
  says otherwise.
- Before the first poll (195 ms) P14 and J13/K16 are 0 (gated by `029.011.1.FFB1`).

## Derivation (how far to trust it)

1. **Finding the block.** I tracked every input with fabric loads; T12 is the only one not
   explained by SDRAM, the PIC link, audio or the open-drain group. It feeds a long shift
   register whose capture register is readable over the link. P14, J13 and K16 come from the
   same autonomous FSM, which has no other inputs.
2. **netlist.py gaps found on the way**, now fixed in `tools/netlist.py` (evidence in
   `notes/pic-link.md`, "Tool"):
   - **Register feedback in F modes**: TF/BF (TA/BA in F_0/F_1, the 6-LUT select in D_F/C_F)
     are the ALM's own FF?0/FF?1 chosen by `[TB]_FEEDBACK_SEL`, **whatever the select's
     value**. This note's first version applied it only when the bit is 1; with select 0 the
     half reads FF?0, which is exactly the D_F-mode FSM bit `029.011.9.T` that needed the
     flip.
   - **LAB clock select**: the "CLK2 → CLKB" observation was one instance of mistral's
     `CLKn_INV`/`CLKn_SEL` names being swapped (`CLKn_INV` selects clkb, `CLKn_SEL CLKB`
     inverts). It also removes the falling-edge shift clock.
3. **The cycle model**: the poller's register cone (122 FFs, the only input T12) simulated
   directly on `netlist.Design` (`~/scratch/netfix/poller.py`). Changed: it no longer needs
   the flipped LUT (`029.011.9.T`); the hand-coded model in `~/scratch/padre/search.py` and its
   flip are obsolete. The latch/clock roles follow from the waveform (P14 one pulse per poll,
   J13/K16 33 pulses with T12 sampled on each) [likely; not checked on hardware].

## Open questions

- Pins for port 2 data, the D1 lines and IOBit (not configured by spc.cor). They need a probe
  on the board, or a test core that samples candidate unconfigured pins while a pad is held.
  Beware the cart-bus shifter direction pins.
- Whether the board's latch/clock drivers invert (Q1–Q7 near J5/J6). The decoded waveform
  is already SNES-shaped (latch high pulse, clock idle high), so non-inverting is likely.
- Whether the stock core really drops buttons 0–4 (the stage-29 clear above; hwtest v4's
  virtual presses of B/Y/SELECT/START/UP would then be something the stock player never sees).
- Which device "device A" is (ID 0100 in bits 12–15, data in `0x2001` bits 7–4, `0x2002`,
  `0x2003`).
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
  - Then once per frame: P14 high ~8.3 µs; J13/K16 idle high, then 33 low pulses of 0.6 µs
    every 19.3 µs, the first ~8 µs after the latch falls; sample T12 at each clock falling
    edge; ≥ 16 bits. (Changed: was "P14 high ~18 µs".)
  - Real-SNES timing (12 µs latch, 6 µs/6 µs clock) should also work, since the pad is static
    CMOS.
- **To settle the open polarity/role questions safely**, make a test core that:
  - shows T12 live on screen, plus the 16 bits from a poll;
  - alternates every few seconds between "P14 = latch, J13/K16 = clock" and the swapped
    assignment, and between normal and inverted output polarity.

  All four combinations only toggle pins that spc already drives as push-pull outputs.
