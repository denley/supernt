// SPDX-License-Identifier: GPL-3.0-or-later
// Testbench wrapper for Verilator (make sim-snes-load): the quartus/snes_load top with its
// clocks, the PIC32 link and controller port 1 driven from C++ (tb_snes_load.cpp: a PIC32
// stand-in running the SPC player's start-up, UI loop and file transfer, and a 4021 pad), and
// the x8 SDRAM pair replaced by the cycle-based model (quartus/snes_sdram/sim/sdram_cyc.v) with
// chip B's 512-column pages (clk_mem = 5 x clk_sys). Fixed sync order 0: s0/s1/s2 = HS/VS/DE.
// Shortened waits:
// pad poll from 2 ms, diagnostics shown 30 ms before the boot, 20 ms button combinations (menu
// combination 40 ms), the PIC counts as active for 60 ms after a UI write,
// 256-cycle SNES reset, 200-cycle SDRAM power-up wait.
module tb #(parameter CAPTURE_HALF = 8, parameter TMPL_HEX = "diag.hex",
            parameter FONT_HEX = "font.hex", parameter USE_GSU = 0) (
    input  wire       clk,       // 74.25 MHz board clock
    input  wire       clk_sys,   // SNES clock (PLL output 0, 21.44196 MHz)
    input  wire       clk_mem,   // SDRAM clock (PLL output 1, 4 x clk_sys)
    // PIC32 stand-in
    input  wire [2:0] pic_a,
    input  wire       pic_nrd,
    input  wire       pic_nwr,
    input  wire [7:0] pic_dout,
    input  wire       pic_drive,
    output wire [7:0] pic_din,
    output wire       link_oe,   // the core drives the bus
    // controller ports 1 and 2 (data lines; LATCH and CLOCK are shared)
    input  wire       pad_t12,
    input  wire       pad_d6,
    output wire       pad_p14, pad_j13,
    output wire       pclk, s0, s1, s2,
    output wire [7:0] ch1, ch2, ch3
);
    wire        sd_clk, sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n, sd_dqm_b;
    wire [11:0] sd_a;
    wire [1:0]  sd_ba;
    wire [15:0] sd_dq;
    wire [15:0] dq_chip;
    wire [7:0]  link_d;
    assign link_d = pic_drive ? pic_dout : 8'hzz;
    assign pic_din = link_d;
    assign link_oe = dut.link_oe;
    top #(.SYNC_ORDER(0), .RESET_CYCLES(16'd256), .CAPTURE_HALF(CAPTURE_HALF),
          .TMPL_HEX(TMPL_HEX), .FONT_HEX(FONT_HEX), .USE_GSU(USE_GSU),
          .PAD_START_US(2000), .SHOW_MS(30), .COMBO_MS(20), .MENU_MS(40), .FOLLOW_MS(60),
          .INIT_CYCLES(250)) dut (
        .clk(clk), .pclk(pclk), .s0(s0), .s1(s1), .s2(s2), .ch1(ch1), .ch2(ch2), .ch3(ch3),
        .aud_mclk(), .aud_bclk(), .aud_lrclk(), .aud_sdata(),
        .pad_p14(pad_p14), .pad_j13(pad_j13), .pad_k16(), .pad_t12(pad_t12), .pad_d6(pad_d6),
        .link_a(pic_a), .link_nrd(pic_nrd), .link_nwr(pic_nwr), .link_d(link_d),
        .sd_clk(sd_clk), .sd_cs_n(sd_cs_n), .sd_ras_n(sd_ras_n), .sd_cas_n(sd_cas_n),
        .sd_we_n(sd_we_n), .sd_a(sd_a), .sd_ba(sd_ba), .sd_dq(sd_dq), .sd_dqm_b(sd_dqm_b));
    wire fpga_oe = dut.sd_dq_oe;
    assign sd_dq = fpga_oe ? 16'hzzzz : dq_chip;
    // 5 x clk_sys: tRAS 5, tRC 7 cycles, refresh within 15.6 us = 1673 cycles; read window: the
    // byte is valid at half cycle 8 after the READ (rise 4) for board delays around 5 ns
    sdram_cyc #(.COL_BITS(9), .WLO(8), .WHI(8), .T_RAS(5), .T_RC(7), .REF_MAX(1673)) sdram (
        .clk(clk_mem), .cs_n(sd_cs_n), .ras_n(sd_ras_n), .cas_n(sd_cas_n), .we_n(sd_we_n),
        .a(sd_a), .ba(sd_ba), .dq_fpga(dut.sd_dq_out), .oe_fpga(fpga_oe), .dq_chip(dq_chip));
endmodule
