// SPDX-License-Identifier: GPL-3.0-or-later
// Simulation stand-ins for quartus/snes_sdram (Verilator): the PLL (the C++ testbench drives
// clk_sys and clk_mem = 4 x clk_sys, rising edges aligned), the audio PLL and the Game Genie
// block, as quartus/snes/sim/sim_models.v. altddio_out is in ddio_model.v.
// (The phases are not modelled: all clocks have aligned edges. The cycle model sdram_cyc.v takes
// the read window in half cycles of clk_mem, which is where the shifts end up.)
module snes_sdram_pll #(parameter MEM_PHASE = "0 ps", SD_PHASE = "0 ps", CAP_PHASE = "0 ps") (
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

module audio_pll (input wire refclk, output wire outclk_0, output wire locked);
    assign outclk_0 = refclk;
    assign locked = 1'b1;
endmodule

module CODES #(parameter ADDR_WIDTH = 16, parameter DATA_WIDTH = 8, parameter MAX_CODES = 32) (
    input  wire                  clk, reset, enable,
    output wire                  available,
    input  wire [ADDR_WIDTH-1:0] addr_in,
    input  wire [DATA_WIDTH-1:0] data_in,
    input  wire [128:0]          code,
    output wire                  genie_ovr,
    output wire [DATA_WIDTH-1:0] genie_data
);
    assign available  = 1'b0;
    assign genie_ovr  = 1'b0;
    assign genie_data = data_in;
endmodule
