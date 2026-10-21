# PLL clocks for our own cores (post-route bitstream patch)

nextpnr-mistral can't place fPLLs (`notes/toolchain.md`). `tools/pllpatch.py` gets around that
after routing. The design routes its clock through a placeholder global clock buffer. The tool
then configures an fPLL with settings copied from a Quartus-built PLL in `spc.cor`, and switches
that buffer's clock mux from fabric to the fPLL output. Oct 2026, **not yet run on hardware**.

## Using it

1. In the Verilog, take the clock from a hand-instantiated `MISTRAL_CLKBUF`. Its input is the
   reference pin (W16), which must be a top-level input:

   ```verilog
   input wire clk;                                   // W16 (in the .qsf)
   wire clk74, clk_snes;
   MISTRAL_CLKBUF ref_buf (.A(clk), .Q(clk74));      // only if the design also uses 74.25 MHz
   (* BEL = "MISTRAL_CLKENA.0.22.0" *)               // optional: left global, see below
   MISTRAL_CLKBUF pll_snes (.A(clk), .Q(clk_snes));  // placeholder for the fPLL output
   ```

   If the design also clocks logic from the raw pin, instantiate that buffer by hand too.
   Otherwise yosys' automatic buffer (`clkbufmap`) takes over every load of `clk`, including the
   placeholder's input. That still works after patching, but it wastes a fabric route from one
   global to the other.
2. Add `hw/<name>/pll.cfg`, one line per placeholder:

   ```
   # <clkbuf instance> <MHz> [pll=FPLL.x.y] [out=Cn] [profile=NAME] [tol=PPM]
   pll_snes  21.477273
   ```

   Defaults: `pll` = the W16-fed fPLL on the side where nextpnr put the buffer
   (`CMUXHG.000.022` → `FPLL.000.000`, `CMUXHG.054.022` → `FPLL.054.000`); `out` = C0 (C1… for
   further lines on the same fPLL); `profile` = the first that hits the frequency (below);
   `tol` = 1 ppm.
3. `make out/<name>.cor`. When `pll.cfg` exists, the Makefile:
   - runs nextpnr with `--write build/hw/<name>-routed.json`, so the tool can see where each
     buffer was placed;
   - runs `pllpatch.py patch` to write `build/hw/<name>-pll.bt`, then
     `mistral-patch` to write `build/hw/<name>-pll.rbf`;
   - runs `pllpatch.py check` on the result (see Verification);
   - turns `-pll.rbf` into the `.cor` with rbf2cor, which does its own round-trip check.

Other commands:

```sh
python3 -I tools/pllpatch.py decode build/spc.bt        # or any .rbf; also: make build/plls-spc.txt
python3 -I tools/pllpatch.py solve 12.288               # settings for a frequency (C0, C1, … per arg)
python3 -I tools/pllpatch.py solve 21.477273 85.90908   # two outputs on one fPLL
```

`tools/pllinfo` (`tools/src/pllinfo.cc`) dumps the fixed wiring from mistral's database: which
pin feeds each fPLL `CLKIN.n`, which `PLLCOUT.n` reaches which clock-mux `PLLIN.m`, and the
`INPUT_SEL` tables.

**Timing:** nextpnr thinks the placeholder clock is the 74.25 MHz pin, so set `--freq` in
`nextpnr.args` to at least the fastest PLL clock. Treat paths between the PLL clock and any other
clock as asynchronous (the phase between them is unknown) and synchronise them.

## How a nextpnr design's global clock is driven

nextpnr only uses mux index 2 of the two horizontal global clock muxes, `CMUXHG.000.022` (left)
and `CMUXHG.054.022` (right), so a design gets **at most two global clocks**. The clock net comes
in from general routing:

```
r GPIO.046.000.0:DATAIN.0 V12...  ; W16      pin -> fabric
r TDMUX.000.022.0004 CMUXHG.000.022:CLKIN.2      fabric -> clock mux input
s CMUXHG.000.022:INPUT_SEL.2 1b                  1b = CLKIN.2 (general routing)
s CMUXHG.000.022:TESTSYN_ENOUT_SELECT.2 PRE_SYNENB
```

From `CMUXHG.x.022.2:CLKOUT`, the global feeds the spines (`SCLK.039.000.0011` etc.) and the
LABs. The decompiler hides the first hop because it is a mux default.

## How spc drives its LABs from FPLL.000.000 C0 (21.477 MHz)

The path has no routed lines at all. `FPLL.000.000:PLLCOUT.0` is hard-wired (a p2p link) to
`CMUXHG.000.022:PLLIN.4`, and the mux selects it:

```
s CMUXHG.000.022:INPUT_SEL.2 0c                  0c = PLLIN.4 (0x08 + m selects PLLIN.m)
```

This is the same mux, same index 2, that nextpnr uses for a left-side global, so the patch is
one `INPUT_SEL` value plus the fPLL settings. Only C0–C3 of each fPLL reach a `CMUXHG`. C4–C8 go
to the regional and vertical muxes (`CMUXVG/VR/HR/CR`), which nextpnr doesn't use.

| clock mux | PLLIN.0–3 (`INPUT_SEL` 08–0b) | PLLIN.4–7 (`INPUT_SEL` 0c–0f) |
|---|---|---|
| `CMUXHG.000.022` (left) | FPLL.000.037 C0–C3 (ref H16) | FPLL.000.000 C0–C3 (ref W16) |
| `CMUXHG.054.022` (right) | FPLL.054.037 C0–C3 (ref H16) | FPLL.054.000 C0–C3 (ref W16) |

What the patch writes, for `pll_snes 21.477273`. It equals spc's FPLL.000.000 configuration line
for line:

```
s FPLL.000.000:BWCTRL 8                     loop bandwidth  } loop settings, copied from the
s FPLL.000.000:CP_CURRENT 3                 charge pump     } profile's source PLL
s FPLL.000.000:CTRL_OVERRIDE_SETTING 0
s FPLL.000.000:DSM_OUT_SEL 1                delta-sigma on (fractional mode)
s FPLL.000.000:FBCLK_MUX_2 1
s FPLL.000.000:FPLL_ENABLE 1
s FPLL.000.000:LOCK_FILTER_CFG_SETTING 019
s FPLL.000.000:N_CNT_BYPASS_EN 1            N = 1
s FPLL.000.000:N_CNT_HI_DIV_SETTING 00
s FPLL.000.000:N_CNT_LO_DIV_SETTING 00
s FPLL.000.000:TCLK_SEL 0
s FPLL.000.000:UNLOCK_FILTER_CFG_SETTING 2
s FPLL.000.000:VCO_PH0_EN 1 … VCO_PH7_EN 1
s FPLL.000.000:M_CNT_HI_DIV_SETTING 04      M = 4 + 4 = 8
s FPLL.000.000:M_CNT_LO_DIV_SETTING 04
s FPLL.000.000:FRACTIONAL_DIVISION_SETTING 196371dc   K: M_eff = 8 + K/2^32 = 8.0991737
s FPLL.000.000:CLKIN_0_SRC 7                } position-specific, copied from spc's own
s FPLL.000.000:NREVERT_INVERT 1             } config of the target fPLL (7 = CLKIN.3 = W16)
s FPLL.000.000:C0_COUT_EN 1                 output C0 on
s FPLL.000.000:CNT_IN_SRC.0 0               C0 counts the VCO (default 2 = test clock)
s FPLL.000.000:DPRIO0_CNT_HI_DIV.0 0e       C0 = 14 + 14 = 28
s FPLL.000.000:DPRIO0_CNT_LO_DIV.0 0e
i FPLL.000.000:NRESET0 1                    as spc: NRESET0 undriven, inverted
s CMUXHG.000.022:INPUT_SEL.2 0c             was 1b
```

spc.bt also prints `r TCLK.000.001.0004 FPLL.000.000:FBCLK_IN_R0` for each fPLL, but those mux
bits are at their default in nextpnr's output too, with the same source. The decompiler prints
them only for spc (a quirk in its DCMUX/TCLK default filter), so there is nothing to copy. The
fabric route that still feeds `CMUXHG:CLKIN.2` from the pin is left in place; it is unused once
`INPUT_SEL` points at the PLL.

## Decoded fPLL parameters

The encoding, checked against the Pocket SNES core, whose Quartus sources give the intended
frequencies:

- Reference: `CLKIN_0_SRC` = 4 + n selects `CLKIN.n` (pin from `tools/pllinfo`). W16 and H16 are
  both taken to be 74.25 MHz.
- N = `N_CNT_HI + N_CNT_LO`, or 1 if `N_CNT_BYPASS_EN`. Default 1 + 1 = 2.
- M = `M_CNT_HI + M_CNT_LO` (+ `K/2^32`, `K = FRACTIONAL_DIVISION_SETTING`, 32 bits, in
  fractional mode). Quartus writes K = 1 in integer mode; the decoder ignores it.
- VCO = ref × M / N. Output Cn = VCO / (`DPRIO0_CNT_HI_DIV.n + DPRIO0_CNT_LO_DIV.n`), enabled by
  `Cn_COUT_EN`, `CNT_IN_SRC.n 0`. Odd dividers use hi = lo + 1 plus
  `DPRIO0_CNT_ODD_DIV_EVEN_DUTY_EN.n 1`. `CNT_PRESET.n`/`CNT_PH_MUX_PRESET.n` are phase shifts
  (default = none).
- `Cn` is `PLLCOUT.n`: in both spc and the Pocket core, every clock mux that selects a PLL
  output selects an enabled counter with the same index.

**Pocket check** (`build/pocket/snes_main.bt`, `target/pocket/mf_pllbase/mf_pllbase_0002.v`):
FPLL.054.000 decodes to N=1, M=8 + 0x19635ee1/2^32, VCO 601.363560 MHz, giving C5 /7 = 85.909080,
C0 /28 = 21.477270, and C1, C2 /56 = 10.738635 MHz. Those are exactly the four
`output_clock_frequency` values in its source, and K is exactly
round((85.909080 × 7 / 74.25 − 8) × 2^32). So the formula, the 32-bit K, the hi+lo counters and
the reference (74.25 MHz, which the source declares) are confirmed, and there is no hidden VCO
post-divider. The main clock (C5, 85.9 MHz) goes through `CMUXVG.021.000:INPUT_SEL.2 0f` =
PLLIN.7 = PLLCOUT.5.

**spc** (`make build/plls-spc.txt`). This completes the table in `notes/spc-core.md`:

| fPLL | ref | N | M | VCO MHz | BWCTRL / CP | outputs (MHz) | used by |
|---|---|---|---|---|---|---|---|
| 000.000 | W16 | 1 | 8 + 0x196371dc/2^32 | 601.3636 | 8 / 3 | C0 /28 = 21.477273 | CMUXHG.000.022.2 |
| 000.037 | H16 | 1 | 16 | 1188 | 7 / 2 | C1 /8 = 148.5, C3 /55 = 21.6 (phase), C6 /8 = 148.5 (phase) | CMUXHG.000.022.0 (C1), CMUXVR.025.045.2 (C6) |
| 054.000 | W16 | 2 | 28 | 1039.5 | 7 / 1 | C5, C8 /7 = 148.5 (C8 phase-shifted) | CMUXVG.021.000.2/3 |
| 054.037 | H16 | 13 | 142 | 811.0385 | 3 / 2 | C0 /38 = 21.3431, C1, C8 /7 = 115.8626, C2 /9 = 90.1154, C3 /22 = 36.8654, C5 /264 = 3.0721, C6 /19 = 42.6862, C7 /66 = 12.2885 | CMUXHG.054.022.0–3 (C0–C3), CMUXVG.025.045 (C5–C8) |

(054.000's N was "not decoded" before: N is at its default, 1 + 1 = 2, so 148.5 MHz.
`CMUXHG.000.022.1/.3` use `INPUT_SEL 20` = SWITCH, the dynamic clock switchover, which is not
decoded here.)

## Other frequencies: profiles

The tool never invents a loop configuration. Each **profile** is the full set of non-counter
settings of one Quartus-built spc fPLL (M, N, bandwidth, charge pump, lock filter, VCO phase
enables, …). The tool only picks output dividers, and in fractional mode the fractional part K
of M near the source's M. The loop dynamics (PFD 74.25 or 37.125 MHz, M ≈ 8–28) therefore stay
ones Quartus chose. The tool tries profiles in this order and takes the first within `tol`:

| profile | source | mode | VCO | reachable outputs |
|---|---|---|---|---|
| `int28n2` | spc FPLL.054.000 | integer, N=2 M=28 | 1039.5 | 1039.5/C: 148.5 (7), 74.25 (14), … |
| `int16` | spc FPLL.000.037 | integer, N=1 M=16 | 1188 | 1188/C: 27 (44), 59.4 (20), 99 (12), … |
| `int142n13` | spc FPLL.054.037 | integer, N=13 M=142 | 811.04 | 12.2885 (66), … |
| `frac8` | spc FPLL.000.000 | fractional, N=1 M=8+K | 600–668 | anything with f×C in 600–668 MHz (any f ≤ 68 MHz; some above) |

Results (from `pllpatch.py solve`, each checked by decoding a patched bitstream):

| request (MHz) | profile | VCO | C | decoded |
|---|---|---|---|---|
| 21.477273 (NTSC SNES) | frac8 | 601.363644 | 28 | 21.477273, **identical to spc's FPLL.000.000** |
| 85.90908 (4× SNES, SDRAM) | frac8 | 601.363560 | 7 | 85.909080 (same as Pocket's PLL) |
| 74.25 (720p) | int28n2 | 1039.5 | 14 | 74.250000 |
| 148.5 (1080p) | int28n2 | 1039.5 | 7 | 148.500000 |
| 12.288 (48 kHz × 256) | frac8 | 602.112 | 49 | 12.288000 (`profile=int142n13 tol=50` gives spc's 12.2885) |
| 27 (480p) | int16 | 1188 | 44 | 27.000000 |

Two outputs on one fPLL share the VCO (`solve 21.477273 85.909092` → C0 /28, C1 /7). This can't
be used yet, because each side has a single nextpnr global.

## Verification (no hardware)

For `hw/plltest` (`make out/plltest.cor`) and 12 more configurations in
`~/scratch/pll/var` (85.9, 74.25, 148.5, 12.288 in both modes, 27 MHz, out=C2, right-hand
FPLL.054.000, two PLL clocks at once):

- `pllpatch.py check` decompiles nextpnr's bitstream and the patched one with
  `mistral-cv decomp`; both give empty stderr (0 errors). Their decompiles differ only in lines
  of the patch: for plltest, 1 removed (`INPUT_SEL.2 1b`) and 31 added. Decoding the patched
  bitstream gives the requested frequency on the requested output, through the buffer's clock
  mux.
- rbf2cor's libmistral round trip reports 0 differences. The final `out/plltest.cor`, bit-reversed
  and decompiled, also gives 0 errors. Apart from rbf2cor's usual I/O-standard and option lines,
  its diff against nextpnr's `.rbf` is exactly the patch. Its `FPLL.000.000` lines and
  `CMUXHG.000.022:INPUT_SEL.2` are identical to spc.bt's.
- Bit level: compiling spc.bt from scratch reproduces spc.rbf's PRAM (where the fPLL and clock-mux
  settings live) byte for byte, so mistral models every fPLL bit Quartus set. I compiled spc.bt
  once as is and once without FPLL.000.000's settings and with `INPUT_SEL.2 1b`. The two differ
  in exactly the same 132 bit positions that the plltest patch flips. 98 are configuration bits
  with identical values; the other 34 are per-frame CRC bits.
- Error cases are caught: an fPLL or output that can't reach the buffer's mux, a frequency no
  profile hits within `tol`, an unknown buffer name, a reference pin the design doesn't use as
  input, and an fPLL the design already configures.

## Assumed, not verified

- **That it runs at all**: no hardware test yet. The fPLL settings and mux value are copies of a
  working Quartus core, but the rest of the bitstream (nextpnr's) is untested on the console,
  `out/blinky.cor` included.
- **Reference frequency**: W16 = 74.25 MHz is inferred (spc's PLL settings only make sense with
  it). plltest measures the PLL against W16, so the PLL/W16 ratio is checked whatever W16 really
  is.
- **NRESET0 inverter**: spc leaves NRESET0 of FPLL.000.000/054.000 undriven with the inverter set,
  and we copy that. FPLL.054.037 has no inverter in spc; its NRESET0 is also undriven. The
  inversion's meaning is unknown, so we only copy what spc does per position.
- **Lock / startup**: there is no lock output or reset sequencing. Logic on the PLL clock sees
  whatever the PLL makes while locking, so designs should reset themselves (e.g. a counter on the
  board clock) or tolerate it. Lock time is unknown (µs to ms).
- **Profiles for new frequencies**: copying the loop settings while changing only output dividers
  is safe in principle (the output counters are outside the loop). In fractional mode K changes:
  M from 8.08 to 9.0 against Quartus' 8.099 for the same bandwidth/charge-pump values. The
  Cyclone V limits used (VCO 600–1300 MHz, counters ≤ 510) are datasheet values for -C8, not
  checked against Quartus.
- **TESTSYN_ENOUT_SELECT**: nextpnr sets PRE_SYNENB on the mux; spc uses the default (core_en) on
  index 2 but PRE_SYNENB on index 0 (also PLL-fed). We keep nextpnr's value.
- **Clock pin outputs** (HDMI pixel clock straight from a clock network, as spc does on M22):
  not supported. plltest makes the pixel clock in fabric (`~clk74`), as vtest does.

## Limits

- Two global clocks in total (one per side, mux index 2, nextpnr's limit), so at most one PLL
  clock per side. A left-side buffer can take FPLL.000.000 (W16) or FPLL.000.037 (H16) C0–C3, a
  right-side one FPLL.054.000/054.037 C0–C3. Pin the side with
  `(* BEL = "MISTRAL_CLKENA.0.22.0" *)` or `"MISTRAL_CLKENA.54.22.0"` (the trailing 0 is nextpnr's
  bel number in the tile, not the mux index).
- An H16-fed fPLL needs H16 declared as a design input (the tool checks for that). Its
  placeholder can be fed from H16.
- No phase shifts, dynamic reconfiguration, lock output, clock switchover or PLL outputs to pins.
  These are all decodable (spc uses each), but none is wired up.

## hw/plltest

A 720p frequency meter, with vtest's pins and sync-role cycling (`hw/plltest/plltest.v`):

- Video runs on the raw 74.25 MHz W16 clock (right global).
- A placeholder buffer on the left global becomes FPLL.000.000 C0 = 21.477273 MHz.
- A Gray counter on the PLL clock is sampled every frame (1/60 s of board clock).

Expected count: 357954 or 357955. The screen shows:

- 20 boxes at y 140–220 with the count, MSB left. Filled = 1, a thin bar at the bottom = 0.
  Expected pattern `0101 0111 0110 0100 001x`.
- A big block below: solid white = count within ±2 (PLL runs as configured), vertical stripes =
  wrong frequency (read the bits), black = no PLL clock.

Everything is white-on-black, so it doesn't depend on the unconfirmed colour-pin order. Not
simulated (no simulator on this box). Timing: clk74 81.9 MHz, PLL clock 225 MHz at
`--freq 74.25`. Like vtest it uses MLAB tiles as plain logic (no LUT RAM).
