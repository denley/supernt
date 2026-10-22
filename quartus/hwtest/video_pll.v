// SPDX-License-Identifier: GPL-3.0-or-later
// A reconfigurable fPLL set up like spc.cor's video PLL FPLL.000.037 (notes/pll.md: H16
// reference, N 1, M 16, VCO 1188 MHz; C1 /8 = 148.5 MHz, C3 /55 = 21.6 MHz at 270 deg,
// C6 /8 = 148.5 MHz at 90 deg). Used only by pll_emul.sv (status for the PIC, frequency
// counter); none of its clocks reaches a pin.
`timescale 1ns/10ps
module video_pll (
    input  wire        refclk,
    input  wire        rst,
    output wire        outclk_0,
    output wire        outclk_1,
    output wire        outclk_2,
    output wire        locked,
    input  wire [63:0] reconfig_to_pll,
    output wire [63:0] reconfig_from_pll
);
    altera_pll #(
        .fractional_vco_multiplier("false"),
        .reference_clock_frequency("74.25 MHz"),
        .operation_mode("direct"),
        .number_of_clocks(3),
        .output_clock_frequency0("148.500000 MHz"),
        .phase_shift0("0 ps"),
        .duty_cycle0(50),
        .output_clock_frequency1("21.600000 MHz"),
        .phase_shift1("34722 ps"),
        .duty_cycle1(50),
        .output_clock_frequency2("148.500000 MHz"),
        .phase_shift2("1684 ps"),
        .duty_cycle2(50),
        .pll_type("General"),
        .pll_subtype("Reconfigurable")
    ) altera_pll_i (
        .rst(rst),
        .outclk({outclk_2, outclk_1, outclk_0}),
        .locked(locked),
        .reconfig_to_pll(reconfig_to_pll),
        .reconfig_from_pll(reconfig_from_pll),
        .fboutclk(),
        .fbclk(1'b0),
        .refclk(refclk)
    );
endmodule
