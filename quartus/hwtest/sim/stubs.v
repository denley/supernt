// Stand-ins for the parts of quartus/hwtest the screen simulation (tb_screen.sv) doesn't look
// at, so its frames render faster: no SDRAM test (all pins idle), no video-PLL emulation
// (status 02), no audio. The full simulation (tb.sv) uses the real modules.
`timescale 1ns/1ps
module sdram_test #(
    parameter [11:0] MRS_PINS = 12'h037, parameter [11:0] ROWS = 12'd4095,
    parameter [15:0] INIT_NOP = 16'd20000, parameter integer NTIE = 19,
    parameter integer FIXED_STOCK = 0
) (
    input  wire        clk, start,
    output wire        sd_clk, sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n,
    output wire [11:0] sd_a,
    output wire [1:0]  sd_ba,
    input  wire [15:0] sd_dq_in,
    output wire [15:0] sd_dq_out,
    output wire        sd_dq_oe, ab10,
    output wire [7:0]  od_low,
    output wire [NTIE-1:0] tie_rel,
    output wire [15:0] passes,
    output wire [3:0]  hyp,
    input  wire [3:0]  hsel,
    output wire [191:0] err_row,
    output wire [159:0] raw_row,
    output wire        pass_done,
    output wire [191:0] last_err
);
    assign {sd_clk, sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n} = 5'b01111;
    assign sd_a = 12'd0, sd_ba = 2'd0, sd_dq_out = 16'd0, sd_dq_oe = 1'b0, ab10 = 1'b0;
    assign od_low = 8'd0, tie_rel = {NTIE{1'b0}}, passes = 16'd0, hyp = 4'd0;
    assign err_row = 192'd0, raw_row = 160'd0, pass_done = 1'b0, last_err = 192'd0;
endmodule

module pll_emul (
    input  wire        clk, refclk, wr,
    input  wire [31:0] wa,
    input  wire [7:0]  wd,
    output wire [1:0]  status,
    output wire [7:0]  n_cmt,
    output wire [5:0]  last_reg,
    output wire [31:0] last_data,
    output wire [7:0]  n_c4, c4,
    output wire [23:0] out_per_ms, ref_per_ms, out1_per_ms,
    output wire        busy_now, wait_low,
    output wire [7:0]  cmt_wlow
);
    assign status = 2'b10, n_cmt = 8'd0, last_reg = 6'd0, last_data = 32'd0, n_c4 = 8'd0;
    assign c4 = 8'd0, out_per_ms = 24'd0, ref_per_ms = 24'd0, out1_per_ms = 24'd0;
    assign busy_now = 1'b0, wait_low = 1'b0, cmt_wlow = 8'd0;
endmodule

module i2s_test #(
    parameter SINE_HEX = "sine.hex", parameter integer MODE_SAMPLES = 192000,
    parameter integer FIXED_MODE = -1, parameter integer ATTEN = 0
) (
    input  wire       mclk,
    output wire       mclk_pin, bclk, lrclk, sdata, mode,
    output wire [7:0] secs
);
    assign {mclk_pin, bclk, lrclk, sdata, mode} = 5'd0;
    assign secs = 8'd0;
endmodule
