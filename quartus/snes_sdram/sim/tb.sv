// SPDX-License-Identifier: GPL-3.0-or-later
// Testbench wrapper for Verilator (make sim-snes-sdram): the quartus/snes_sdram top with the
// three clocks driven from C++ (tb_snes_sdram.cpp) and the x8 SDRAM pair replaced by the
// cycle-based model sdram_cyc.v. Fixed sync order 0: s0/s1/s2 = HS/VS/DE.
module tb #(parameter ROM_HEX = "sa1test.hex", parameter CAPTURE_HALF = 7) (
    input  wire       clk,       // 74.25 MHz board clock
    input  wire       clk_sys,   // SNES clock (PLL output 0, 21.44196 MHz)
    input  wire       clk_mem,   // SDRAM clock (PLL output 1, 4 x clk_sys)
    input  wire       pad_t12,   // controller port 1 data line
    output wire       pclk, s0, s1, s2,
    output wire [7:0] ch1, ch2, ch3
);
    wire        sd_clk, sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n, sd_cke;
    wire [11:0] sd_a;
    wire [1:0]  sd_ba;
    wire [15:0] sd_dq;
    wire [7:0]  sd_dqm;
    wire [15:0] dq_chip;
    top #(.ROM_HEX(ROM_HEX), .SYNC_ORDER(0), .RESET_CYCLES(16'd256), .CAPTURE_HALF(CAPTURE_HALF)) dut (
        .clk(clk), .pclk(pclk), .s0(s0), .s1(s1), .s2(s2), .ch1(ch1), .ch2(ch2), .ch3(ch3),
        .aud_mclk(), .aud_bclk(), .aud_lrclk(), .aud_sdata(),
        .pad_p14(), .pad_j13(), .pad_k16(), .pad_t12(pad_t12),
        .sd_clk(sd_clk), .sd_cs_n(sd_cs_n), .sd_ras_n(sd_ras_n), .sd_cas_n(sd_cas_n),
        .sd_we_n(sd_we_n), .sd_a(sd_a), .sd_ba(sd_ba), .sd_dq(sd_dq), .sd_cke(sd_cke),
        .sd_dqm(sd_dqm));
    wire fpga_oe = dut.sd_dq_oe;
    assign sd_dq = fpga_oe ? 16'hzzzz : dq_chip;
    sdram_cyc sdram (
        .clk(clk_mem), .cs_n(sd_cs_n), .ras_n(sd_ras_n), .cas_n(sd_cas_n), .we_n(sd_we_n),
        .a(sd_a), .ba(sd_ba), .dq_fpga(dut.sd_dq_out), .oe_fpga(fpga_oe), .dq_chip(dq_chip));
endmodule
