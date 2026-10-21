// SPDX-License-Identifier: GPL-3.0-or-later
// 74.25 MHz (W16) -> 21.477273 MHz SNES master clock (NTSC, 6 x 3.579545 MHz), fractional-N
// fPLL. Same request as the Pocket core's mf_pllbase (VCO ~601.36 MHz, /28) and spc.cor's own
// SNES clock. Quartus picks the counters; the .fit report lists the result.
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
        .output_clock_frequency0("21.477272 MHz"),
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
