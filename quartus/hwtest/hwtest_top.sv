// SPDX-License-Identifier: GPL-3.0-or-later
// Super Nt hardware test core: one core that exercises every interface we know, with the
// results on a text screen (layout: screen.txt, compiled by tools/mkscreen.py). Sections:
//   audio  - i2s_test.sv: alternating I2S / left-justified test tone (notes/audio.md)
//   link   - link_logger.sv: the PIC32 port as spc.cor implements it, logging every
//            transaction as compressed runs with CRC-32 (notes/pic-link.md)
// Pages cycle automatically: 0 overview (10 s), 1-7 link tables (6 s each). Status word map:
// see screen.txt (words 24-28 are per table row).
module top #(
    parameter SCREEN_HEX = "../../build/hwtest/screen.hex",
    parameter FONT_HEX   = "../../build/hwtest/font.hex",
    parameter SINE_HEX   = "../../build/hwtest/sine.hex",
    parameter [9:0] PAGE0_FRAMES = 10'd600,   // overview page time (10 s)
    parameter [9:0] PAGE_FRAMES  = 10'd360    // other pages (6 s)
) (
    input  wire       clk,      // W16, 74.25 MHz
    // video (AD9889B), pins as quartus/snes/pins.tcl
    output wire       pclk,     // M22
    output reg        s0,       // P16 VSYNC
    output reg        s1,       // M16 DE
    output reg        s2,       // M18 HSYNC
    output reg  [7:0] ch1,      // red
    output reg  [7:0] ch2,      // green
    output reg  [7:0] ch3,      // blue
    // audio (AD9889B serial audio)
    output wire       aud_mclk, // L17
    output wire       aud_bclk, // L19
    output wire       aud_lrclk,// K17
    output wire       aud_sdata,// L18
    // PIC32 link (bank 4A)
    input  wire [2:0] link_a,   // AB20 AA20 AA19
    input  wire       link_nrd, // U21
    input  wire       link_nwr, // U22
    inout  wire [7:0] link_d    // AB21 AB22 AA22 Y21 Y22 W21 W22 V21 (bit 7..0)
);
    // ---------------------------------------------------------------- status words
    wire [31:0] st [0:23];
    wire [767:0] stat;
    genvar gi;
    generate for (gi = 0; gi < 24; gi = gi + 1) begin : g_stat
        assign stat[32*gi +: 32] = st[gi];
    end endgenerate

    // ---------------------------------------------------------------- video
    wire [7:0] vr, vg, vb;
    wire       vhs, vvs, vde;
    wire [9:0] vy;
    reg  [2:0]   page = 3'd0;
    wire [4:0]   row_next;
    wire [255:0] rowstat;
    wire         row_blank;
    textmode #(.SCREEN_HEX(SCREEN_HEX), .FONT_HEX(FONT_HEX), .PAGES(8)) txt (
        .clk(clk), .page(page), .stat(stat), .rowstat(rowstat), .row_blank(row_blank),
        .row_next(row_next), .r(vr), .g(vg), .b(vb), .hs(vhs), .vs(vvs), .de(vde), .frame_y(vy));
    always @(posedge clk) begin
        {ch1, ch2, ch3} <= {vr, vg, vb};
        {s0, s1, s2}    <= {vvs, vde, vhs};
    end
    altddio_out #(
        .extend_oe_disable("OFF"), .intended_device_family("Cyclone V"),
        .invert_output("OFF"), .lpm_hint("UNUSED"), .lpm_type("altddio_out"),
        .oe_reg("UNREGISTERED"), .power_up_high("OFF"), .width(1)
    ) pclk_ddio (
        .datain_h(1'b0), .datain_l(1'b1), .outclock(clk), .dataout(pclk),
        .aclr(1'b0), .aset(1'b0), .oe(1'b1), .oe_out(), .outclocken(1'b1), .sclr(1'b0), .sset(1'b0)
    );

    reg [31:0] frames = 32'd0;
    reg [9:0]  vy_d = 10'd0;
    reg [9:0]  pframes = 10'd0;
    always @(posedge clk) begin
        vy_d <= vy;
        if (vy == 10'd0 && vy_d == 10'd749) begin
            frames <= frames + 32'd1;
            if (pframes == (page == 3'd0 ? PAGE0_FRAMES : PAGE_FRAMES) - 10'd1) begin
                pframes <= 10'd0;
                page <= page + 3'd1;
            end else
                pframes <= pframes + 10'd1;
        end
    end
    assign st[0]  = frames;
    assign st[13] = {29'd0, page};

    // ---------------------------------------------------------------- audio
    wire mclk, mclk_locked;
    audio_pll apll (.refclk(clk), .outclk_0(mclk), .locked(mclk_locked));
    wire       a_mode;
    wire [7:0] a_secs;
    i2s_test #(.SINE_HEX(SINE_HEX)) aud (
        .mclk(mclk), .mclk_pin(aud_mclk), .bclk(aud_bclk), .lrclk(aud_lrclk), .sdata(aud_sdata),
        .mode(a_mode), .secs(a_secs));
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg [8:0] a_sync1, a_sync2;
    always @(posedge clk) begin
        a_sync1 <= {a_mode, a_secs};
        a_sync2 <= a_sync1;
    end
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg [1:0] lk_sync;
    always @(posedge clk) lk_sync <= {lk_sync[0], mclk_locked};
    assign st[1] = {31'd0, a_sync2[8]};     // audio framing now playing
    assign st[2] = {24'd0, a_sync2[7:0]};   // audio seconds
    assign st[3] = {31'd0, lk_sync[1]};     // audio PLL locked

    // ---------------------------------------------------------------- PIC32 link
    wire [7:0]  ld_out;
    wire        ld_oe;
    assign link_d = ld_oe ? ld_out : 8'hzz;
    // table pages: 1-2 big write runs, 3 read runs, 4-7 all runs; rows 2-21 = entries
    wire [1:0]  lsel = page == 3'd1 || page == 3'd2 ? 2'd1 : page == 3'd3 ? 2'd2 : 2'd0;
    wire [9:0]  lbase = page == 3'd2 ? 10'd20 : page >= 3'd4 ? {5'd0, page - 3'd4, 2'd0} * 10'd5 : 10'd0;
    wire [9:0]  lidx = lbase + {5'd0, row_next} - 10'd2;
    wire [127:0] lent;
    wire        lvalid;
    wire [31:0] l_nwr, l_nrd, l_noth, l_addr, l_us, l_last;
    wire [10:0] l_all, l_big, l_rdl;
    link_logger link (
        .clk(clk), .a(link_a), .n_rd(link_nrd), .n_wr(link_nwr), .d_in(link_d),
        .d_out(ld_out), .d_oe(ld_oe), .sel(lsel), .idx(lidx), .entry(lent), .entry_valid(lvalid),
        .n_wr_total(l_nwr), .n_rd_total(l_nrd), .n_other(l_noth), .n_all(l_all), .n_big(l_big),
        .n_rdlog(l_rdl), .addr(l_addr), .usec(l_us), .last_act(l_last));
    assign rowstat   = {96'd0, 22'd0, lidx, lent};
    assign row_blank = page != 3'd0 && row_next >= 5'd2 && !lvalid;
    assign st[4]  = l_nwr;
    assign st[5]  = l_nrd;
    assign st[6]  = l_noth;
    assign st[7]  = {21'd0, l_all};
    assign st[8]  = {21'd0, l_big};
    assign st[9]  = {21'd0, l_rdl};
    assign st[10] = l_addr;
    assign st[11] = l_us;
    assign st[12] = l_last;
    assign st[14] = {22'd0, lbase};
    assign st[15] = {21'd0, lsel == 2'd1 ? l_big : lsel == 2'd2 ? l_rdl : l_all};

    generate for (gi = 16; gi < 24; gi = gi + 1) begin : g_unused
        assign st[gi] = 32'd0;
    end endgenerate
endmodule
