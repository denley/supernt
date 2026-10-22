# Quartus Prime Lite

Installed 21 Oct 2026 with Denley's approval of the licence ("Quartus Prime and Altera IP License
Agreement, version 25.1"; copy in `~/scratch/quartus-eula/25.1/license.txt`).

- Version 25.1std.0.1129 Lite (free, no licence file), Cyclone V device support only.
- Installed at `~/altera_lite/25.1std` (installer default), with Questa, RiscFree and the offline
  help left out. Installer and `.qdz` were downloaded through the shared browser (curl gets 403
  from Altera's CDN) and checked against the SHA-1s on the download page:
  `QuartusLiteSetup-25.1std.0.1129-linux.run` ce0773469eacab5b7035c175484625f4ec3737d1,
  `cyclonev-25.1std.0.1129.qdz` a7225ec1bd36ccfd6826ea6273df5d21dd95633b.
- Reinstall: put both files in one folder and run
  `./QuartusLiteSetup-25.1std.0.1129-linux.run --mode unattended --unattendedmodeui none
  --accept_eula 1 --installdir ~/altera_lite/25.1std
  --disable-components questa_fse,questa_fe,riscfree,quartus_help`.
- Problem Reporter (crash reports to Altera, licence §15) is turned off.

## Licence rules for this project

1. **Never use Quartus to make bitstreams for reverse engineering the format** (compiling test
   designs and diffing/decoding them with mistral, etc.). §2.2.6 treats binaries produced with
   Quartus as part of the licensed software and §2.2.7 forbids reverse engineering it. Format
   work uses only third-party bitstreams (Analogue's `spc.cor`, agg23's Pocket release) and the
   open-source flow (`notes/toolchain.md`).
2. **Don't publish Quartus test or benchmark results** (e.g. Quartus vs nextpnr comparisons),
   §2.2.8.

Using Quartus to build cores for the Super Nt's Cyclone V is what the licence grants (§2.1).

## Pin safety

`make out/q-<name>.cor` runs `tools/checkpins.py` on Quartus' `.pin` report and refuses to make
the `.cor` if any user I/O is not on the pin `pins.tcl` gives it (Quartus, like nextpnr, places
unassigned I/Os anywhere, which on the board could drive a random net). The open flow does the
same before nextpnr with `tools/checkqsf.py` (every top port bit needs a `.qsf` location).
Added 21 Oct 2026 after a hwtest build briefly lacked its SDRAM pin block (caught, never built
into a `.cor`).

## Power-up values

- `quartus/common/supernt.tcl` sets `ALLOW_POWER_UP_DONT_CARE OFF`, so registers power up at
  their Verilog initial values (hwtest v2 lost two handshake flags to the default).
- **Quartus ignores initial values written in an ANSI port declaration** (`output reg x = 1`):
  synthesis warns "Net ... has no driver or initial value, using a default initial value '0'"
  (10030) and treats the register as powering up 0. Found 22 Oct 2026 from hwtest v4/v4b on the
  console: `link_logger`'s `cand = FIRST_CAND` and `vpress`'s `btn = 4'hF` came up 0 (the
  map report's "Inverted Register Statistics", where NOT-gate push-back registers are listed,
  had none of them; `sdram_test`'s `sd_cs_n = 1'b1` was reported "stuck at GND"). Rule: a
  register that must power up nonzero is declared inside the module (`reg q = v;` plus
  `assign out = q;`), and important ones also get an explicit post-configuration load
  (`link_logger`: 256 clocks loading FIRST_CAND). Zero initial values in port declarations are
  harmless. Check: `rg "output\s+reg[^;]*=\s*[^0;,]" quartus/` lists the candidates (only zero
  values such as `8'd0` may remain).
