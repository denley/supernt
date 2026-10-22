// SPDX-License-Identifier: GPL-3.0-or-later
// 74.25 MHz (W16) -> SNES master clock and SDRAM clocks for quartus/snes_load, one fractional
// fPLL, VCO 750.4686 MHz (35 x 21.44196):
//   outclk_0 = 21.44196 MHz (/35: an NTSC SNES frame lasts exactly one 720p60 frame, as
//              quartus/snes/snes_pll.v)
//   outclk_1 = 107.2098 MHz = 5 x outclk_0 (/7), at MEM_PHASE: SDRAM controller
//   outclk_2 = 107.2098 MHz at SD_PHASE: source of the SDRAM clock (DDIO on AB11)
//   outclk_3 = 107.2098 MHz at CAP_PHASE: SDRAM read-capture register
// One VCO, so the timing analyser treats them as related; phases are multiples of VCO period / 8
// = 166.6 ps. Why 5 x and not 4 x (quartus/snes_sdram): notes/snes-load.md, "SDRAM".
`timescale 1ns/10ps
module snes_load_pll #(
    parameter MEM_PHASE = "0 ps",
    parameter SD_PHASE  = "9160 ps",
    parameter CAP_PHASE = "666 ps"
) (
    input  wire refclk,
    input  wire rst,
    output wire outclk_0,
    output wire outclk_1,
    output wire outclk_2,
    output wire outclk_3,
    output wire locked
);
    wire [3:0] outclk;
    assign {outclk_3, outclk_2, outclk_1, outclk_0} = outclk;
    altera_pll #(
        .fractional_vco_multiplier("true"),
        .reference_clock_frequency("74.25 MHz"),
        .operation_mode("normal"),
        .number_of_clocks(4),
        .output_clock_frequency0("21.44196 MHz"),
        .phase_shift0("0 ps"),
        .duty_cycle0(50),
        .output_clock_frequency1("107.2098 MHz"),
        .phase_shift1(MEM_PHASE),
        .duty_cycle1(50),
        .output_clock_frequency2("107.2098 MHz"),
        .phase_shift2(SD_PHASE),
        .duty_cycle2(50),
        .output_clock_frequency3("107.2098 MHz"),
        .phase_shift3(CAP_PHASE),
        .duty_cycle3(50),
        .pll_type("General"),
        .pll_subtype("General")
    ) altera_pll_i (
        .rst(rst),
        .outclk(outclk),
        .locked(locked),
        .fboutclk(),
        .fbclk(1'b0),
        .refclk(refclk)
    );
endmodule
