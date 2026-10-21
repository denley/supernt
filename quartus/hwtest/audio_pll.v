// SPDX-License-Identifier: GPL-3.0-or-later
// 74.25 MHz (W16) -> 12.288 MHz audio master clock (256 x 48 kHz), fractional-N fPLL.
// spc.cor makes its 12.2885 MHz from FPLL.054.037 (H16, integer M/N); any PLL will do here.
`timescale 1ns/10ps
module audio_pll (
    input  wire refclk,
    output wire outclk_0,
    output wire locked
);
    altera_pll #(
        .fractional_vco_multiplier("true"),
        .reference_clock_frequency("74.25 MHz"),
        .operation_mode("normal"),
        .number_of_clocks(1),
        .output_clock_frequency0("12.288 MHz"),
        .phase_shift0("0 ps"),
        .duty_cycle0(50),
        .pll_type("General"),
        .pll_subtype("General")
    ) altera_pll_i (
        .rst(1'b0),
        .outclk(outclk_0),
        .locked(locked),
        .fboutclk(),
        .fbclk(1'b0),
        .refclk(refclk)
    );
endmodule
