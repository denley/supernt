// SPDX-License-Identifier: GPL-3.0-or-later
// Super Nt hardware test core (v2): one core that exercises every interface we know, with the
// results on a text screen (layout: screen.txt, compiled by tools/mkscreen.py). Sections:
//   audio  - i2s_test.sv: alternating I2S / left-justified test tone (notes/audio.md)
//   pads   - pad_test.sv: port 1 polled in cfg 0 (confirmed), held buttons shown by name
//   sdram  - sdram_test.sv: x8 SDRAM pair memory test at 8 read-capture points, one pin
//            hypothesis (AB10 level, open-drain pins) per pass, raw bus words
//   link   - link_logger.sv: the PIC32 port as spc.cor implements it, answering the status
//            poll at 0x2004_0000 like the stock core, logging every transaction as
//            compressed runs (repeats merged) with CRC-32 (notes/pic-link.md)
// Pages cycle automatically: 0 overview (10 s), 1 link log from the first status read,
// 2 big write runs, 3 newest log entries (8 s each). Status word map: see the assignments
// below (words 24-31 are per text row).
module top #(
    parameter SCREEN_HEX = "../../build/hwtest/screen.hex",
    parameter FONT_HEX   = "../../build/hwtest/font.hex",
    parameter SINE_HEX   = "../../build/hwtest/sine.hex",
    parameter [9:0] PAGE0_FRAMES = 10'd600,   // overview page time (10 s)
    parameter [9:0] PAGE_FRAMES  = 10'd480,   // other pages (8 s)
    parameter integer STEP_US    = 5000000,   // link: answer candidate step time
    parameter [11:0] SD_ROWS     = 12'd4095   // SDRAM rows tested per bank (simulation: fewer)
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
    inout  wire [7:0] link_d,   // AB21 AB22 AA22 Y21 Y22 W21 W22 V21 (bit 7..0)
    // controller port 1 (notes/controllers.md)
    output wire       pad_p14,  // P14, likely LATCH
    output wire       pad_j13,  // J13 } same signal, likely CLOCK (ports 1/2)
    output wire       pad_k16,  // K16 }
    input  wire       pad_t12,  // T12, port 1 data
    // x8 SDRAM pair (notes/sdram.md)
    output wire       sd_clk,   // AB11
    output wire       sd_cs_n,  // AB17
    output wire       sd_ras_n, // AA17
    output wire       sd_cas_n, // AB18
    output wire       sd_we_n,  // AA18
    output wire [11:0] sd_a,    // A0-A9 AB13 AA13 AB12 AA12 U2 U1 W2 AA2 AA1 N1, A10 AA14, A11 N2
    output wire [1:0] sd_ba,    // AA15 AB15 (order unknown)
    inout  wire [15:0] sd_dq,   // 7:0 chip A (2A) D3 E2 L2 L1 G2 G1 C2 C1, 15:8 chip B (3B)
    output wire       sd_cke,   // AB10, constant output in spc.cor (low, decoded; CKE or DQM?)
    inout  wire [7:0] sd_dqm    // Y3 W9 W8 Y9 Y10 R11 R10 Y11, open-drain constants in spc.cor
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
    reg  [1:0]   page = 2'd0;
    wire [4:0]   row_next;
    wire [255:0] rowstat;
    wire         row_blank;
    textmode #(.SCREEN_HEX(SCREEN_HEX), .FONT_HEX(FONT_HEX), .PAGES(4), .FLAG_WORD(23)) txt (
        .clk(clk), .page({1'b0, page}), .stat(stat), .rowstat(rowstat), .row_blank(row_blank),
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
        // count frames and turn pages at the last active line (blank on this screen), before
        // textmode samples the status words at the start of vertical blanking
        if (vy == 10'd719 && vy_d == 10'd718) begin
            frames <= frames + 32'd1;
            if (pframes == (page == 2'd0 ? PAGE0_FRAMES : PAGE_FRAMES) - 10'd1) begin
                pframes <= 10'd0;
                page <= page + 2'd1;
            end else
                pframes <= pframes + 10'd1;
        end
    end
    assign st[0]  = frames;
    assign st[13] = {30'd0, page};

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
    // table pages: 1 = all log from two entries before the first read run, 2 = big write runs,
    // 3 = the newest 19 entries; text rows 3-21 = entries
    wire [31:0] l_nwr, l_nrd, l_noth, l_addr, l_us, l_last, l_after;
    wire [10:0] l_all, l_first;
    wire [8:0]  l_big;
    wire [2:0]  l_cand;
    wire [7:0]  l_ans, l_steps;
    wire        l_fixed;
    wire        lsel = page == 2'd2;
    wire [10:0] base1 = l_first == 11'h7ff ? 11'd0 : l_first < 11'd2 ? 11'd0 : l_first - 11'd2;
    wire [10:0] base3 = l_all > 11'd19 ? l_all - 11'd19 : 11'd0;
    wire [9:0]  lbase = page == 2'd1 ? base1[9:0] : page == 2'd3 ? base3[9:0] : 10'd0;
    wire [9:0]  lidx = lbase + {5'd0, row_next} - 10'd3;
    wire [191:0] lent;
    wire [9:0]  lent_idx;
    wire        lvalid;
    link_logger #(.STEP_US(STEP_US)) link (
        .clk(clk), .a(link_a), .n_rd(link_nrd), .n_wr(link_nwr), .d_in(link_d), .pll_locked(1'b1),
        .d_out(ld_out), .d_oe(ld_oe), .sel(lsel), .idx(lidx), .entry(lent), .entry_idx(lent_idx),
        .entry_valid(lvalid), .n_wr_total(l_nwr), .n_rd_total(l_nrd), .n_other(l_noth),
        .n_all(l_all), .n_big(l_big), .first_rd(l_first), .addr(l_addr), .usec(l_us),
        .last_act(l_last), .cand(l_cand), .answer(l_ans), .n_steps(l_steps),
        .cand_locked(l_fixed), .n_wr_after(l_after));
    wire [255:0] link_row = {32'd0, 22'd0, lent_idx, lent};
    assign st[4]  = l_nwr;
    assign st[5]  = l_nrd;
    assign st[6]  = l_noth;
    assign st[7]  = {21'd0, l_all};
    assign st[8]  = {23'd0, l_big};
    assign st[9]  = {21'd0, l_first};
    assign st[10] = l_addr;
    assign st[11] = l_us;
    assign st[12] = l_last;
    assign st[14] = {22'd0, lbase};
    assign st[15] = page == 2'd2 ? {23'd0, l_big} : {21'd0, l_all};
    assign st[18] = {8'd0, l_steps, l_ans, 3'd0, l_fixed, 1'b0, l_cand};
    assign st[19] = l_after;

    // ---------------------------------------------------------------- pads (cfg 0 confirmed)
    wire        pclkp;
    wire [31:0] praw0, praw1, praw2, praw3;
    wire        pt12;
    wire [15:0] ppolls;
    pad_test #(.FIXED_CFG(0)) pads (
        .clk(clk), .p14(pad_p14), .j13k16(pclkp), .t12(pad_t12),
        .raw0(praw0), .raw1(praw1), .raw2(praw2), .raw3(praw3), .t12_now(pt12), .polls(ppolls));
    assign pad_j13 = pclkp;
    assign pad_k16 = pclkp;
    assign st[16] = praw0;
    assign st[17] = {15'd0, pt12, ppolls};
    assign st[23] = {20'd0, praw0[31:12] == 20'hFFFF0 ? praw0[11:0] : 12'd0};  // held buttons

    // ---------------------------------------------------------------- SDRAM
    wire [15:0]  sdq_out;
    wire         sdq_oe, s_ab10, s_dqm_low;
    wire [15:0]  s_passes, s_hpasses;
    wire [1:0]   s_hyp;
    wire [1:0]   s_hsel = row_next >= 5'd16 ? row_next[1:0] : row_next[1:0] + 2'd1;   // rows 11-14, 16-19
    wire [255:0] s_err;
    wire [143:0] s_raw;
    assign sd_dq  = sdq_oe ? sdq_out : 16'hzzzz;
    assign sd_cke = s_ab10;
    assign sd_dqm = s_dqm_low ? 8'h00 : 8'hzz;     // open-drain: low or released
    sdram_test #(.ROWS(SD_ROWS)) sdram (
        .clk(clk), .sd_clk(sd_clk), .sd_cs_n(sd_cs_n), .sd_ras_n(sd_ras_n), .sd_cas_n(sd_cas_n),
        .sd_we_n(sd_we_n), .sd_a(sd_a), .sd_ba(sd_ba), .sd_dq_in(sd_dq), .sd_dq_out(sdq_out),
        .sd_dq_oe(sdq_oe), .ab10(s_ab10), .dqm_low(s_dqm_low), .passes(s_passes), .hyp(s_hyp),
        .hsel(s_hsel), .err_row(s_err), .raw_row(s_raw), .hyp_passes(s_hpasses));
    assign st[20] = {16'd0, s_passes};
    assign st[21] = {30'd0, s_hyp};
    assign st[22] = 32'd0;

    // ---------------------------------------------------------------- per-row words 24-31
    assign rowstat = page != 2'd0                         ? link_row :
                     row_next >= 5'd11 && row_next <= 5'd14 ? s_err :
                     row_next >= 5'd16 && row_next <= 5'd19 ? {80'd0, s_hpasses, s_raw} : 256'd0;
    assign row_blank = page != 2'd0 && row_next >= 5'd3 && !lvalid;
endmodule
