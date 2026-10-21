// SPDX-License-Identifier: GPL-3.0-or-later
// 74.25 MHz (W16) -> 21.44196 MHz SNES master clock, fractional-N fPLL: 74.25 x 357366/1237500,
// so an NTSC SNES frame (357366 master clocks) lasts exactly one 1650 x 750 720p frame at
// 74.25 MHz (60.000 Hz). That is 0.164% slower than a real SNES (21.477273 MHz, 60.0988 Hz;
// the Pocket core's and spc.cor's clock). Standard 720p60 timing with a constant frame length
// is what the test projector accepts; matching the video clock to the SNES instead (74.372 MHz)
// needs a multiplier fraction below the fPLL's 0.05 minimum. Quartus picks the counters; the
// .fit report lists the result.
// The simulation replaces this module (sim/sim_models.v).
`timescale 1ns/10ps
module snes_pll (
    input  wire refclk,
    input  wire rst,
    output wire outclk_0,
    output wire locked
);
    altera_pll #(
        .fractional_vco_multiplier("true"),
        .reference_clock_frequency("74.25 MHz"),
        .operation_mode("normal"),
        .number_of_clocks(1),
        .output_clock_frequency0("21.44196 MHz"),
        .phase_shift0("0 ps"),
        .duty_cycle0(50),
        .pll_type("General"),
        .pll_subtype("General")
    ) altera_pll_i (
        .rst(rst),
        .outclk(outclk_0),
        .locked(locked),
        .fboutclk(),
        .fbclk(1'b0),
        .refclk(refclk)
    );
endmodule
