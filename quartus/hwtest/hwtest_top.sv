// SPDX-License-Identifier: GPL-3.0-or-later
// Super Nt hardware test core (v4): one core that exercises every interface we know, with the
// results on a text screen (layout: screen.txt, compiled by tools/mkscreen.py). Sections:
//   audio  - i2s_test.sv: test tone, I2S only (AUD_FIXED; confirmed by v3), 24 dB down
//   pads   - pad_test.sv: port 1 polled in cfg 0 (confirmed), held buttons shown by name; the
//            PIC reads them like from the stock core (0x2000-0x2003, 0x2008, below), with
//            virtual presses OR'd in (vpress.sv) once the player UI waits
//   sdram  - sdram_test.sv: x8 SDRAM pair, 512-column bursts, errors per chip at four capture
//            points, one pin hypothesis per pass (spc.cor's constant pins of banks 3A/3B at
//            their stock level or released), raw bus words
//   link   - link_logger.sv: the PIC32 port as spc.cor implements it, answering the status
//            poll at 0x2004_0000 with 02 (FIRST_CAND = 1, what v3 found), then the emulated
//            PLL + reconfiguration IP (pll_emul.sv) and the other candidates if the PIC keeps
//            polling; every transaction logged as compressed runs with CRC-32 (pad reads only
//            counted), the log a ring after 512 entries
// Pages cycle automatically: 0 overview (10 s), 1 link log up to just after the first status
// read, 2 the newest big write runs, 3 newest log entries, 4 SDRAM errors per hypothesis, 5 SDRAM
// raw words (8 s each). Status word map: see the assignments below (words 24-31 are per text
// row; on page 0 they are more overview words).
//
// Constant pins (notes/sdram.md, "Constant pins"): spc.cor drives many otherwise unused pins
// to a constant. tie3 (banks 3A/3B, 19 pins) is switched per SDRAM pass between spc.cor's level
// and released (weak pull-up, what v1/v2 did); tie_hold (24 pins: 4A and three next to the
// audio pins) is always at spc.cor's level. No other levels are ever driven on them.
module top #(
    parameter SCREEN_HEX = "../../build/hwtest/screen.hex",
    parameter FONT_HEX   = "../../build/hwtest/font.hex",
    parameter SINE_HEX   = "../../build/hwtest/sine.hex",
    parameter [9:0] PAGE0_FRAMES = 10'd600,   // overview page time (10 s)
    parameter [9:0] PAGE_FRAMES  = 10'd480,   // other pages (8 s)
    parameter integer STEP_US    = 5000000,   // link: answer candidate step time
    parameter [3:0]  FIRST_CAND  = 4'd1,      // link: first 0x2004 answer candidate (1 = 02)
    parameter integer AUD_FIXED  = 0,         // audio framing: 0 I2S (v3), 1 LJ, -1 alternate
    parameter integer AUD_ATTEN  = 4,         // test tone attenuation, 6 dB steps
    parameter [11:0] SD_ROWS     = 12'd4095   // SDRAM rows tested per bank (simulation: fewer)
) (
    input  wire       clk,      // W16, 74.25 MHz
    input  wire       h16,      // H16, 74.25 MHz reference of spc's video PLL (input only)
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
    output wire       pad_p14,  // P14, latch
    output wire       pad_j13,  // J13 } same signal, clock (ports 1/2)
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
    output wire       sd_cke,   // AB10, constant 0 in spc.cor; chip B drives only while low
    inout  wire [7:0] sd_dqm,   // Y3 W9 W8 Y9 Y10 R11 R10 Y11, open-drain constants (released)
    // spc.cor constant pins (pins.tcl): tie3 index 0-15 low, 16-18 high in spc.cor
    output wire [18:0] tie3,
    output wire [23:0] tie_hold
);
    // spc.cor's levels
    localparam [18:0] TIE3_LEVEL = 19'b111_0000000000000000;
    // tie_hold: 0-12 4A low, 13-20 4A high, 21 K19 low, 22 K20 low, 23 J17 high
    localparam [23:0] HOLD_LEVEL = 24'b1_00_11111111_0000000000000;

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
    textmode #(.SCREEN_HEX(SCREEN_HEX), .FONT_HEX(FONT_HEX), .PAGES(6), .FLAG_WORD(23)) txt (
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
        // count frames and turn pages at the last active line (blank on this screen), before
        // textmode samples the status words at the start of vertical blanking
        if (vy == 10'd719 && vy_d == 10'd718) begin
            frames <= frames + 32'd1;
            if (pframes == (page == 3'd0 ? PAGE0_FRAMES : PAGE_FRAMES) - 10'd1) begin
                pframes <= 10'd0;
                page <= page == 3'd5 ? 3'd0 : page + 3'd1;
            end else
                pframes <= pframes + 10'd1;
        end
    end

    // ---------------------------------------------------------------- audio
    wire mclk, mclk_locked;
    audio_pll apll (.refclk(clk), .outclk_0(mclk), .locked(mclk_locked));
    wire       a_mode;
    wire [7:0] a_secs;
    i2s_test #(.SINE_HEX(SINE_HEX), .FIXED_MODE(AUD_FIXED), .ATTEN(AUD_ATTEN)) aud (
        .mclk(mclk), .mclk_pin(aud_mclk), .bclk(aud_bclk), .lrclk(aud_lrclk), .sdata(aud_sdata),
        .mode(a_mode), .secs(a_secs));
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg [8:0] a_sync1 = 9'd0, a_sync2 = 9'd0;
    always @(posedge clk) begin
        a_sync1 <= {a_mode, a_secs};
        a_sync2 <= a_sync1;
    end
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg [1:0] lk_sync = 2'd0;
    always @(posedge clk) lk_sync <= {lk_sync[0], mclk_locked};

    // ---------------------------------------------------------------- PIC32 link
    wire [7:0]  ld_out;
    wire        ld_oe;
    assign link_d = ld_oe ? ld_out : 8'hzz;
    // table pages (text rows 2-20 = 19 entries): 1 = first status read - 16 .. + 2, 2 = the
    // newest 19 big write runs, 3 = the newest 19 entries
    wire [31:0] l_nwr, l_nrd, l_noth, l_nstat, l_addr, l_us, l_last, l_after, l_arm, l_pollt, l_fixt;
    wire [31:0] l_all, l_first, l_big, l_nolog;
    wire        l_have;
    wire [3:0]  l_cand, l_fixc;
    wire [7:0]  l_ans, l_steps;
    wire        l_fixed, l_polling, l_rd2, l_xfer;
    wire        w_go;
    wire [31:0] w_addr;
    wire [7:0]  w_data;
    wire [1:0]  emu_st;
    wire        lsel = page == 3'd2;
    wire [31:0] base1 = !l_have ? 32'd0 : l_first < 32'd16 ? 32'd0 : l_first - 32'd16;
    wire [31:0] base2 = l_big > 32'd19 ? l_big - 32'd19 : 32'd0;
    wire [31:0] base3 = l_all > 32'd19 ? l_all - 32'd19 : 32'd0;
    wire [31:0] lbase = page == 3'd1 ? base1 : page == 3'd2 ? base2 : base3;
    wire [31:0] lidx = lbase + {27'd0, row_next} - 32'd2;
    wire [191:0] lent;
    wire [31:0] lent_idx;
    wire        lvalid;
    wire [127:0] regs2;
    link_logger #(.STEP_US(STEP_US), .FIRST_CAND(FIRST_CAND), .NOLOG(16'h0003)) link (
        .clk(clk), .a(link_a), .n_rd(link_nrd), .n_wr(link_nwr), .d_in(link_d),
        .emu_status(emu_st), .regs2(regs2), .d_out(ld_out), .d_oe(ld_oe),
        .w_go(w_go), .w_addr(w_addr), .w_data(w_data),
        .sel(lsel), .idx(lidx), .entry(lent), .entry_idx(lent_idx), .entry_valid(lvalid),
        .n_nolog(l_nolog), .rd2(l_rd2), .xfer(l_xfer),
        .n_wr_total(l_nwr), .n_rd_total(l_nrd), .n_other(l_noth), .n_stat(l_nstat),
        .n_all(l_all), .n_big(l_big), .first_rd(l_first), .have_rd(l_have), .addr(l_addr),
        .usec(l_us), .last_act(l_last), .arm_t(l_arm), .cand(l_cand), .answer(l_ans),
        .n_steps(l_steps), .polling(l_polling), .poll_t(l_pollt), .cand_locked(l_fixed),
        .fix_cand(l_fixc), .fix_t(l_fixt), .n_wr_after(l_after));
    wire [255:0] link_row = {32'd0, lent_idx, lent};

    // video-PLL reconfiguration block stand-in (status bits for the PIC)
    wire [7:0]  e_ncmt, e_nc4, e_c4, e_cmtok;
    wire [5:0]  e_reg;
    wire [31:0] e_data;
    wire [23:0] e_out, e_ref, e_out1;
    wire        e_busy, e_wlow;
    pll_emul emu (
        .clk(clk), .refclk(h16), .wr(w_go), .wa(w_addr), .wd(w_data), .status(emu_st),
        .n_cmt(e_ncmt), .last_reg(e_reg), .last_data(e_data), .n_c4(e_nc4), .c4(e_c4),
        .out_per_ms(e_out), .ref_per_ms(e_ref), .out1_per_ms(e_out1), .busy_now(e_busy),
        .wait_low(e_wlow), .cmt_wlow(e_cmtok));

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

    // virtual presses for the player UI (vpress.sv)
    wire [15:0] vmask;
    wire [1:0]  vp_state;
    wire [3:0]  vp_btn, vp_xbtn;
    wire [7:0]  vp_np, vp_xnp, vp_nwait;
    wire [31:0] vp_uit, vp_xt, vp_xdt;
    vpress vp (
        .clk(clk), .usec(l_us), .ui_rd(l_rd2), .wr(w_go), .xfer(l_xfer), .mask(vmask),
        .state(vp_state), .btn(vp_btn), .n_press(vp_np), .ui_t(vp_uit), .n_wait(vp_nwait),
        .xfer_btn(vp_xbtn), .xfer_np(vp_xnp), .xfer_t(vp_xt), .xfer_dt(vp_xdt));

    // What the PIC reads at 0x2000-0x2003 and 0x2008, as the stock core (notes/controllers.md,
    // "Link registers"): its poller shifts 33 samples (1 = line low = pressed) and keeps them
    // when the 16 bits after the buttons match a standard pad (bits 12-15 = 0, 16-32 = 1):
    // 0x2000 = pad bits 7-0 (RIGHT LEFT DOWN UP START SELECT Y B), 0x2001 bits 3-0 = pad bits
    // 11-8 (R L X A), 0x2008 = 01 (standard pad; 02 = another device, 03 = none). The other
    // bits belong to the other device type and read 0 with a pad. Here: always "a standard
    // pad", buttons = the real pad's (when it reads like one) OR the virtual presses.
    wire        pad_std = praw0[31:12] == 20'hFFFF0;
    wire [11:0] pad_btn = (pad_std ? praw0[11:0] : 12'd0) | vmask[11:0];
    wire [39:0] pad_rd = {8'h01, 8'h00, 8'h00, 4'h0, pad_btn[11:8], pad_btn[7:0]};
    reg  [39:0] pad_rd_q = 40'd0;               // {2008, 2003, 2002, 2001, 2000}
    always @(posedge clk) pad_rd_q <= pad_rd;
    assign regs2 = {56'd0, pad_rd_q[39:32], 32'd0, pad_rd_q[31:0]};

    // ---------------------------------------------------------------- SDRAM
    wire [15:0]  sdq_out;
    wire         sdq_oe, s_ab10;
    wire [7:0]   s_odl;
    wire [18:0]  s_rel;
    wire [15:0]  s_passes;
    wire [3:0]   s_hyp;
    wire [3:0]   s_hsel = row_next - 5'd3;      // table rows 3-18 = hypotheses 0-15
    wire [191:0] s_err;
    wire [159:0] s_raw;
    assign sd_dq  = sdq_oe ? sdq_out : 16'hzzzz;
    assign sd_cke = s_ab10;
    genvar gk;
    generate for (gk = 0; gk < 8; gk = gk + 1) begin : g_od
        assign sd_dqm[gk] = s_odl[gk] ? 1'b0 : 1'bz;  // open-drain: low or released
    end endgenerate
    generate for (gk = 0; gk < 19; gk = gk + 1) begin : g_tie
        assign tie3[gk] = s_rel[gk] ? 1'bz : TIE3_LEVEL[gk];
    end endgenerate
    assign tie_hold = HOLD_LEVEL;
    sdram_test #(.ROWS(SD_ROWS)) sdram (
        .clk(clk), .sd_clk(sd_clk), .sd_cs_n(sd_cs_n), .sd_ras_n(sd_ras_n), .sd_cas_n(sd_cas_n),
        .sd_we_n(sd_we_n), .sd_a(sd_a), .sd_ba(sd_ba), .sd_dq_in(sd_dq), .sd_dq_out(sdq_out),
        .sd_dq_oe(sdq_oe), .ab10(s_ab10), .od_low(s_odl), .tie_rel(s_rel), .passes(s_passes),
        .hyp(s_hyp), .hsel(s_hsel), .err_row(s_err), .raw_row(s_raw));

    // ---------------------------------------------------------------- status words
    assign st[0]  = frames;
    assign st[1]  = l_us;
    assign st[2]  = {l_cand, l_ans, l_steps, 3'd0, l_fixed, l_fixc, 3'd0, l_polling};
    assign st[3]  = l_nwr;
    assign st[4]  = l_nrd;
    assign st[5]  = l_nstat;
    assign st[6]  = l_after;
    assign st[7]  = {l_all[15:0], l_first[15:0]};
    assign st[8]  = l_addr;
    assign st[9]  = l_last;
    assign st[10] = {12'd0, l_pollt[29:10]};
    assign st[11] = {12'd0, l_fixt[29:10]};
    assign st[12] = {3'd0, emu_st[1], 3'd0, emu_st[0], 3'd0, e_busy, e_c4, e_nc4[3:0], e_ncmt};
    assign st[13] = e_data;
    assign st[14] = {2'd0, e_reg, e_out};
    assign st[15] = {3'd0, e_wlow, e_cmtok[3:0], e_ref};
    assign st[16] = praw0;
    assign st[17] = {15'd0, pt12, ppolls};
    assign st[18] = {s_passes, 12'd0, s_hyp};
    assign st[19] = {3'd0, lk_sync[1], 3'd0, a_sync2[8], 8'd0, 8'd0, a_sync2[7:0]};
    assign st[20] = {lbase[15:0], page == 3'd2 ? l_big[15:0] : l_all[15:0]};
    assign st[21] = l_arm;
    assign st[22] = {1'b0, page, 4'd0, e_out1};
    // flags: 0-11 held buttons (real pad), 12-23 virtual presses now
    assign st[23] = {8'd0, vmask[11:0], praw0[31:12] == 20'hFFFF0 ? praw0[11:0] : 12'd0};

    // ---------------------------------------------------------------- per-row words 24-31
    // page 0: more overview words
    wire [255:0] ov = {
        {l_big[15:0], 3'd0, pad_std, 4'd0, pad_rd_q[39:32]},          // 31
        vp_xdt,                                                     // 30
        {12'd0, vp_xt[29:10]},                                      // 29
        {vp_xbtn, 4'd0, vp_xnp, vp_nwait, 8'd0},                    // 28
        {12'd0, vp_uit[29:10]},                                     // 27
        {2'd0, vp_state, vp_btn, vp_np, vmask},                     // 26
        pad_rd_q[31:0],                                             // 25
        l_nolog};                                                   // 24
    wire [255:0] s_err32;
    generate for (gk = 0; gk < 8; gk = gk + 1) begin : g_err
        assign s_err32[32*gk +: 32] = {8'd0, s_err[24*gk +: 24]};
    end endgenerate
    assign rowstat = page == 3'd4 ? s_err32 :
                     page == 3'd5 ? {96'd0, s_raw} :
                     page != 3'd0 ? link_row : ov;
    assign row_blank = (page == 3'd1 || page == 3'd2 || page == 3'd3) && row_next >= 5'd2 && !lvalid;
endmodule
