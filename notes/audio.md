# Audio: AD9889B serial audio from the FPGA

From spc.cor (`build/spc.bt`, traced with `tools/netlist.py` and `tools/trace.py`, 21 Oct 2026).

## Pins

| pin | role | source in spc.cor | confidence |
|---|---|---|---|
| L17 | MCLK 12.2885 MHz (256 fs) | `CMUXVG.025.045.0` clock out, `INPUT_SEL.0 0d` = PLLIN.5 = FPLL.054.037 C7 (/66) | likely |
| L19 | BCLK 3.0721 MHz (64 fs) | `CMUXVG.025.045.2`, `INPUT_SEL.2 0f` = PLLIN.7 = C5 (/264) | likely |
| K17 | LRCLK 48 kHz | `LAB.029.006.1:FFT0` | likely |
| L18 | serial data | `LAB.021.044.8:FFB1`, end of a shift register | likely |

The CMUXVG input mapping (PLLIN.4–7 = PLLCOUT 8, 7, 6, 5) follows from the Pocket core, where
`INPUT_SEL 0f` = PLLIN.7 carries its C5 (`notes/pll.md`). With it, L17/L19 are the two
audio-rate outputs of FPLL.054.037 (VCO 811.04 MHz: C7 /66 = 12.2885, C5 /264 = 3.0721), and
the other two mux outputs carry C6 (42.686 MHz, the PIC-link logic clock) and C8 (115.86 MHz).
The sample rate is 3.0721 MHz / 64 = 48.001 kHz.

## Logic (spc.cor)

- All of it runs on the falling edge of the BCLK clock (`~CMUXVG.025.045.2:CLKOUT`), so data
  and LRCLK change on BCLK falling edges, as I2S-style receivers expect.
- A 6-bit counter (`MLAB.028.008.*`: bit 0 `.8.FFB1` toggles, bit 1 `.5.FFB1`, bit 2 `.0.FFT1`,
  bit 3 `.9.FFB1`, bit 4 `.5.FFT1`, bit 5 `.6.FFB1`) counts BCLKs in the 64-BCLK frame.
- K17 loads counter bit 5 whenever bits 0–4 are 0, i.e. LRCLK = bit 5, one BCLK late: 32 BCLKs
  per channel.
- L18 is fed by a chain of registers that load parallel data (from logic on the 42.686 MHz
  `CMUXHG.054.022.1` clock) and shift on BCLK. Exactly where the MSB lands relative to the LRCLK
  edge (I2S vs left-justified) and the word length aren't decoded; `quartus/hwtest` tested both
  framings on the console instead: **I2S** (see below).
- The AD9889B itself is configured over I2C by the PIC32 (nothing in spc.cor looks like an I2C
  master), presumably for 48 kHz with N/CTS to match. Our cores only have to produce the stream.

## For our cores

- **On hardware: I2S** [confirmed: hwtest v3, 22 Oct 2026, `IMG_3062.mov`]. The tone was
  audible once the PIC got past its status poll (~4 s in; v1/v2, stuck at the poll, were
  silent, so the PIC enables the AD9889B's audio only then); `tools/audiocheck.py` finds the
  I2S segments (440 Hz) clean and the left-justified ones harsh. `AUD_FRAMING` = 0 in the SNES
  cores is right.
- `quartus/common/i2s_test.sv`: MCLK from a 12.288 MHz fractional PLL (DDIO copy on L17), BCLK
  = MCLK/4, LRCLK = BCLK/64, 24-bit samples MSB first in 32-bit slots, changes on BCLK falling
  edges. By default it alternates I2S (440 Hz) and left-justified (880 Hz) every 4 s with a
  0.9-full-scale sine, so the wrong framing is audibly distorted (verified in simulation);
  `FIXED_MODE` fixes the framing and `ATTEN` attenuates in 6 dB steps (hwtest v4: I2S only,
  24 dB down; full scale was uncomfortably loud).
- SNES: the DSP makes 32 kHz stereo 16-bit samples; for 48 kHz out, resample (or hold) in the
  core. Open: whether the PIC sets up the AD9889B's audio only while it believes the SPC player
  runs (it does in our test cores, since they replace spc.cor).
