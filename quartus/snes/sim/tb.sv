// SPDX-License-Identifier: GPL-3.0-or-later
// Testbench wrapper for Verilator: the Super Nt top with both clocks driven from C++ (tb_snes.cpp). The sim
// PLL (sim_models.v) takes its output from clk_sys here. Fixed sync order 0: s0/s1/s2 =
// HS/VS/DE.
module tb #(parameter ROM_HEX = "sa1test.hex") (
    input  wire       clk,       // 74.25 MHz board clock
    input  wire       clk_sys,   // 21.477 MHz (PLL output)
    output wire       pclk, s0, s1, s2,
    output wire [7:0] ch1, ch2, ch3
);
    top #(.ROM_HEX(ROM_HEX), .SYNC_ORDER(0), .RESET_CYCLES(16'd256)) dut (
        .clk(clk), .pclk(pclk), .s0(s0), .s1(s1), .s2(s2), .ch1(ch1), .ch2(ch2), .ch3(ch3));
endmodule
