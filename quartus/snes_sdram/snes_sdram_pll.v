// SPDX-License-Identifier: GPL-3.0-or-later
// 74.25 MHz (W16) -> SNES master clock and SDRAM controller clock from one fractional fPLL:
//   outclk_0 = 21.44196 MHz (74.25 x 357366/1237500, as quartus/snes/snes_pll.v: an NTSC SNES
//              frame lasts exactly one 720p60 frame)
//   outclk_1 = 85.76784 MHz = 4 x outclk_0, delayed by MEM_PHASE (SDRAM controller: commands)
//   outclk_2 = 85.76784 MHz at SD_PHASE (source of the SDRAM clock, DDIO on AB11)
//   outclk_3 = 85.76784 MHz at CAP_PHASE (SDRAM read-capture register)
// All come from the same VCO (600.375 MHz: /28 and /7), so the timing analyser treats them as
// related clocks; phases are multiples of VCO period/8 = 208.2 ps. Defaults (sdram_cfg.tcl):
// controller 1250 ps after clk_sys, SDRAM clock source 1041 ps before it (10618 ps after),
// capture 625 ps after it (= 1666 ps after the SDRAM clock source). Why: notes/snes-sdram.md,
// "Clocks". With all three at 0 ps this is hwtest's arrangement.
`timescale 1ns/10ps
module snes_sdram_pll #(
    parameter MEM_PHASE = "1250 ps",
    parameter SD_PHASE  = "10618 ps",
    parameter CAP_PHASE = "625 ps"
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
        .output_clock_frequency1("85.76784 MHz"),
        .phase_shift1(MEM_PHASE),
        .duty_cycle1(50),
        .output_clock_frequency2("85.76784 MHz"),
        .phase_shift2(SD_PHASE),
        .duty_cycle2(50),
        .output_clock_frequency3("85.76784 MHz"),
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
