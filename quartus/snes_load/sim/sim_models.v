// SPDX-License-Identifier: GPL-3.0-or-later
// Simulation stand-in for quartus/snes_load's PLL (Verilator, make sim-snes-load): the C++
// testbench drives clk_sys and clk_mem = 5 x clk_sys with rising edges aligned; the SDRAM clock
// source and the capture clock are clk_mem (the phases end up in the cycle model's read window,
// sdram_cyc.v). The audio PLL and the Game Genie stand-in are in quartus/snes_sdram/sim/sim_models.v.
module snes_load_pll #(parameter MEM_PHASE = "0 ps", SD_PHASE = "0 ps", CAP_PHASE = "0 ps") (
    input  wire refclk,
    input  wire rst,
    output wire outclk_0,
    output wire outclk_1,
    output wire outclk_2,
    output wire outclk_3,
    output wire locked
);
    assign outclk_0 = tb.clk_sys;
    assign outclk_1 = tb.clk_mem;
    assign outclk_2 = tb.clk_mem;
    assign outclk_3 = tb.clk_mem;
    assign locked   = 1'b1;
endmodule
