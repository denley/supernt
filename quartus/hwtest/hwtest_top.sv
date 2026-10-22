// SPDX-License-Identifier: GPL-3.0-or-later
// Super Nt hardware test core (v5): one core that exercises every interface we know, with the
// results on a text screen (layout: screen.txt, compiled by tools/mkscreen.py) plus graphics
// views. Sections:
//   audio  - i2s_test.sv: test tone, I2S only (AUD_FIXED; confirmed by v3), 24 dB down
//   pads   - pad_test.sv: port 1 polled in cfg 0 (confirmed), held buttons shown by name; the
//            PIC reads them like from the stock core (0x2000-0x2003, 0x2008, below), with
//            virtual presses OR'd in (vpress.sv) once the player UI waits
//   sdram  - sdram_test.sv: x8 SDRAM pair, 512-column bursts, errors per chip at four capture
//            points, one pin hypothesis per pass, raw bus words
//   link   - link_logger.sv: the PIC32 port as spc.cor implements it, answering the status
//            poll at 0x2004_0000 with 02 (FIRST_CAND = 1; v4/v4b powered up at candidate 0,
//            fixed in v5), the emulated PLL and other candidates only if the PIC keeps polling;
//            every transaction logged as compressed runs with CRC-32
//   player - ui_capture.sv keeps copies of what the PIC writes for the SPC player's UI (the
//            4 KB screen at 0x1018_0000, the 8 KB at 0x1006_0000, the palette, registers,
//            0x1017_xxxx), CRCs and a history of screen changes per virtual press;
//            gfx_render.sv and textmode's external cells show them: the screen as text in our
//            font, as tile maps with the captured glyphs in several formats, glyph sheets, a
//            hex dump and bit images of each 4 KB block for tools/bitdump.py
// Display pages (pg() below, the list in notes/hardware-tests.md; the screen shows page numbers
// in hex): 38 pages of 2-5 s; while pressing, one second before each press shows page 29 (0x1D,
// the screen's bit image), which pauses the cycle.
//
// Constant pins (notes/sdram.md, "Constant pins"): spc.cor drives many otherwise unused pins
// to a constant. tie3 (banks 3A/3B, 19 pins) is switched per SDRAM pass between spc.cor's level
// and released (weak pull-up, what v1/v2 did); tie_hold (24 pins: 4A and three next to the
// audio pins) is always at spc.cor's level. No other levels are ever driven on them.
module top #(
    parameter SCREEN_HEX = "../../build/hwtest/screen.hex",
    parameter FONT_HEX   = "../../build/hwtest/font.hex",
    parameter SINE_HEX   = "../../build/hwtest/sine.hex",
    parameter integer HALF_SEC_FRAMES = 30,   // page times are in 0.5 s (simulation: 0 = 1 frame)
    parameter integer STEP_US    = 5000000,   // link: answer candidate step time
    parameter [3:0]  FIRST_CAND  = 4'd1,      // link: first 0x2004 answer candidate (1 = 02)
    parameter integer AUD_FIXED  = 0,         // audio framing: 0 I2S (v3), 1 LJ, -1 alternate
    parameter integer AUD_ATTEN  = 4,         // test tone attenuation, 6 dB steps
    parameter [11:0] SD_ROWS     = 12'd4095,  // SDRAM rows tested per bank (simulation: fewer)
    parameter integer VP_SCRIPT   = 1,         // vpress: 1 = DOWN, DOWN, RUN (the chord), 0 = explore
    parameter integer VP_WAIT_US  = 4_000_000, // virtual presses (vpress.sv): wait after the UI starts,
    parameter integer VP_PRESS_US = 100_000,   //   press time (0.5 s auto-repeated: v6 moved two rows),
    parameter integer VP_GAP_US   = 3_500_000, //   gap,
    parameter integer VP_DUMP_US  = 1_000_000, //   bit image of the screen at the end of each gap,
    parameter integer VP_DUMP_END = 50_000,    //   ending this long before the press
    parameter integer QUIET_US    = 30_000,    // the screen has settled after this long unwritten
    parameter integer FILE_RUN    = 16384      // a write run this long (outside the UI blocks) = the file
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


    // ---------------------------------------------------------------- status words 0-23
    wire [31:0] st [0:23];
    wire [767:0] stat;
    genvar gi;
    generate for (gi = 0; gi < 24; gi = gi + 1) begin : g_stat
        assign stat[32*gi +: 32] = st[gi];
    end endgenerate

    // ---------------------------------------------------------------- display pages
    // Templates (screen.txt pages): 0 overview, 1-3 link tables, 4-5 SDRAM, 6 screen history,
    // 7 press table, 8 screen as text (external cells), 9 hex dump, 10 graphics (header only).
    localparam [3:0] K_OV = 4'd0, K_L1 = 4'd1, K_L2 = 4'd2, K_L3 = 4'd3, K_S1 = 4'd4,
                     K_S2 = 4'd5, K_HI = 4'd6, K_PR = 4'd7, K_TV = 4'd8, K_HX = 4'd9,
                     K_GX = 4'd10;
    localparam [5:0] NPAGES = 6'd38, DUMP_PAGE = 6'd29;
    // page entry: {hex base[14:0], blk[2:0], coff[6:0], roff[4:0], sy, sx, eb, planar,
    //              lbpp[1:0], gh, gw, src, mode[1:0], half seconds[3:0], template[3:0]}
    function [48:0] P(input [3:0] t, input [3:0] hs, input [1:0] md, input sr, input w,
                      input h, input [1:0] lb, input pl, input e, input xs, input ys,
                      input [4:0] ro, input [6:0] co, input [2:0] bk, input [14:0] hb);
        P = {hb, bk, co, ro, ys, xs, e, pl, lb, h, w, sr, md, hs, t};
    endfunction
    function [48:0] pg(input [5:0] n);
        case (n)
            //            tmpl  hs    mode src gw gh  lbpp  pl eb sx sy roff   coff   blk  hex
            6'd0:  pg = P(K_OV, 4'd10, 2'd0, 0, 0, 0, 2'd0, 0, 0, 0, 0, 5'd0,  7'd0,  3'd0, 15'd0);
            6'd1:  pg = P(K_HI, 4'd8,  2'd0, 0, 0, 0, 2'd0, 0, 0, 0, 0, 5'd0,  7'd0,  3'd0, 15'd0);
            // the screen as text: 2-byte cells (v4b: character, attribute), then 1 byte each
            6'd2:  pg = P(K_TV, 4'd6,  2'd0, 0, 0, 0, 2'd0, 0, 1, 0, 0, 5'd0,  7'd0,  3'd0, 15'd0);
            6'd3:  pg = P(K_TV, 4'd6,  2'd0, 0, 0, 0, 2'd0, 0, 1, 0, 0, 5'd11, 7'd0,  3'd0, 15'd0);
            // map views: own font, then the captured 8 KB as glyphs (2-byte cells first)
            6'd4:  pg = P(K_GX, 4'd6,  2'd1, 1, 0, 1, 2'd0, 0, 1, 1, 0, 5'd0,  7'd0,  3'd0, 15'd0);
            6'd5:  pg = P(K_GX, 4'd5,  2'd1, 0, 1, 1, 2'd0, 0, 1, 0, 0, 5'd0,  7'd0,  3'd0, 15'd0);
            6'd6:  pg = P(K_GX, 4'd5,  2'd1, 0, 1, 1, 2'd0, 0, 1, 1, 1, 5'd0,  7'd0,  3'd0, 15'd0);
            6'd7:  pg = P(K_GX, 4'd5,  2'd1, 0, 1, 1, 2'd0, 0, 1, 1, 1, 5'd11, 7'd24, 3'd0, 15'd0);
            6'd8:  pg = P(K_GX, 4'd5,  2'd1, 0, 0, 1, 2'd1, 0, 1, 1, 0, 5'd0,  7'd0,  3'd0, 15'd0);
            6'd9:  pg = P(K_GX, 4'd5,  2'd1, 0, 0, 0, 2'd2, 0, 1, 1, 1, 5'd0,  7'd0,  3'd0, 15'd0);
            6'd10: pg = P(K_GX, 4'd5,  2'd1, 0, 0, 1, 2'd2, 0, 1, 1, 0, 5'd0,  7'd0,  3'd0, 15'd0);
            6'd11: pg = P(K_GX, 4'd5,  2'd1, 0, 0, 1, 2'd1, 1, 1, 1, 0, 5'd0,  7'd0,  3'd0, 15'd0);
            6'd12: pg = P(K_GX, 4'd5,  2'd1, 0, 0, 1, 2'd0, 0, 1, 1, 0, 5'd0,  7'd0,  3'd0, 15'd0);
            6'd13: pg = P(K_GX, 4'd5,  2'd1, 0, 0, 1, 2'd1, 0, 0, 0, 0, 5'd0,  7'd0,  3'd0, 15'd0);
            6'd14: pg = P(K_GX, 4'd5,  2'd1, 1, 0, 1, 2'd0, 0, 0, 0, 0, 5'd0,  7'd0,  3'd0, 15'd0);
            // glyph sheets of the 8 KB
            6'd15: pg = P(K_GX, 4'd4,  2'd2, 0, 1, 1, 2'd0, 0, 0, 0, 0, 5'd0,  7'd0,  3'd0, 15'd0);
            6'd16: pg = P(K_GX, 4'd4,  2'd2, 0, 0, 1, 2'd0, 0, 0, 1, 1, 5'd0,  7'd0,  3'd0, 15'd0);
            6'd17: pg = P(K_GX, 4'd4,  2'd2, 0, 0, 1, 2'd1, 0, 0, 1, 1, 5'd0,  7'd0,  3'd0, 15'd0);
            6'd18: pg = P(K_GX, 4'd4,  2'd2, 0, 0, 0, 2'd2, 0, 0, 1, 1, 5'd0,  7'd0,  3'd0, 15'd0);
            // more text views, 1 byte per character
            6'd19: pg = P(K_TV, 4'd6,  2'd0, 0, 0, 0, 2'd0, 0, 0, 0, 0, 5'd0,  7'd0,  3'd0, 15'd0);
            6'd20: pg = P(K_TV, 4'd6,  2'd0, 0, 0, 0, 2'd0, 0, 0, 0, 0, 5'd11, 7'd40, 3'd0, 15'd0);
            6'd21: pg = P(K_TV, 4'd6,  2'd0, 0, 0, 0, 2'd0, 0, 0, 0, 0, 5'd11, 7'd0,  3'd0, 15'd0);
            6'd22: pg = P(K_TV, 4'd6,  2'd0, 0, 0, 0, 2'd0, 0, 0, 0, 0, 5'd0,  7'd40, 3'd0, 15'd0);
            6'd23: pg = P(K_HX, 4'd6,  2'd0, 0, 0, 0, 2'd0, 0, 0, 0, 0, 5'd0,  7'd0,  3'd0, 15'h0000);
            6'd24: pg = P(K_HX, 4'd6,  2'd0, 0, 0, 0, 2'd0, 0, 0, 0, 0, 5'd0,  7'd0,  3'd0, 15'h02A0);
            6'd25: pg = P(K_PR, 4'd8,  2'd0, 0, 0, 0, 2'd0, 0, 0, 0, 0, 5'd0,  7'd0,  3'd0, 15'd0);
            6'd26: pg = P(K_L1, 4'd4,  2'd0, 0, 0, 0, 2'd0, 0, 0, 0, 0, 5'd0,  7'd0,  3'd0, 15'd0);
            6'd27: pg = P(K_L2, 4'd8,  2'd0, 0, 0, 0, 2'd0, 0, 0, 0, 0, 5'd0,  7'd0,  3'd0, 15'd0);
            6'd28: pg = P(K_L3, 4'd8,  2'd0, 0, 0, 0, 2'd0, 0, 0, 0, 0, 5'd0,  7'd0,  3'd0, 15'd0);
            // bit images of the capture's 4 KB blocks 0-6
            6'd29: pg = P(K_GX, 4'd4,  2'd3, 0, 0, 0, 2'd0, 0, 0, 0, 0, 5'd0,  7'd0,  3'd0, 15'd0);
            6'd30: pg = P(K_GX, 4'd4,  2'd3, 0, 0, 0, 2'd0, 0, 0, 0, 0, 5'd0,  7'd0,  3'd1, 15'd0);
            6'd31: pg = P(K_GX, 4'd4,  2'd3, 0, 0, 0, 2'd0, 0, 0, 0, 0, 5'd0,  7'd0,  3'd2, 15'd0);
            6'd32: pg = P(K_GX, 4'd4,  2'd3, 0, 0, 0, 2'd0, 0, 0, 0, 0, 5'd0,  7'd0,  3'd3, 15'd0);
            6'd33: pg = P(K_GX, 4'd4,  2'd3, 0, 0, 0, 2'd0, 0, 0, 0, 0, 5'd0,  7'd0,  3'd4, 15'd0);
            6'd34: pg = P(K_GX, 4'd4,  2'd3, 0, 0, 0, 2'd0, 0, 0, 0, 0, 5'd0,  7'd0,  3'd5, 15'd0);
            6'd35: pg = P(K_GX, 4'd4,  2'd3, 0, 0, 0, 2'd0, 0, 0, 0, 0, 5'd0,  7'd0,  3'd6, 15'd0);
            6'd36: pg = P(K_S1, 4'd4,  2'd0, 0, 0, 0, 2'd0, 0, 0, 0, 0, 5'd0,  7'd0,  3'd0, 15'd0);
            default: pg = P(K_S2, 4'd4, 2'd0, 0, 0, 0, 2'd0, 0, 0, 0, 0, 5'd0, 7'd0,  3'd0, 15'd0);
        endcase
    endfunction

    // ---------------------------------------------------------------- video
    wire [7:0] vr, vg, vb;
    wire       vhs, vvs, vde, vfg;
    wire [9:0] vy;
    wire [10:0] tx;
    wire [9:0]  ty;
    wire [4:0]  crow;
    wire [6:0]  ccol;
    wire [7:0]  ext_q;
    reg  [5:0]  dp = 6'd0;              // page of the cycle
    reg  [5:0]  dps = 6'd0;             // page shown (dp, or DUMP_PAGE before a press)
    reg  [48:0] pe = 49'd0;             // its entry
    wire [3:0]  kind = pe[3:0];
    wire [4:0]   row_next;
    wire [255:0] rowstat;
    wire         row_blank;
    textmode #(.SCREEN_HEX(SCREEN_HEX), .FONT_HEX(FONT_HEX), .PAGES(11), .FLAG_WORD(23)) txt (
        .clk(clk), .page(kind), .stat(stat), .rowstat(rowstat), .row_blank(row_blank),
        .row_next(row_next), .r(vr), .g(vg), .b(vb), .hs(vhs), .vs(vvs), .de(vde), .frame_y(vy),
        .cx(tx), .cy(ty), .cell_row(crow), .cell_col(ccol), .ext_q(ext_q), .fg(vfg));

    // graphics layer (7 clocks after the counters; textmode's output is delayed by 2 to match)
    wire [10:0] g_aaddr;
    wire [13:0] g_baddr;
    wire [15:0] c_aq, c_bq;
    wire [7:0]  gr, gg, gb;
    wire        gvalid;
    wire [1:0]  g_mode = kind == K_GX ? pe[9:8] : 2'd0;
    gfx_render #(.FONT_HEX(FONT_HEX)) gfx (
        .clk(clk), .x(tx), .y(ty), .mode(g_mode), .src(pe[10]), .gw(pe[11]), .gh(pe[12]),
        .lbpp(pe[14:13]), .planar(pe[15]), .eb(pe[16]), .sx(pe[17]), .sy(pe[18]),
        .roff(pe[23:19]), .coff(pe[30:24]), .blk(pe[33:31]),
        .a_addr(g_aaddr), .a_q(c_aq), .b_addr(g_baddr), .b_q(c_bq),
        .r(gr), .g(gg), .b(gb), .valid(gvalid));
    reg [23:0] trgb1, trgb2;
    reg [2:0]  tsync1, tsync2;
    always @(posedge clk) begin
        trgb1 <= {vr, vg, vb};  trgb2 <= trgb1;
        tsync1 <= {vvs, vde, vhs};  tsync2 <= tsync1;
        {ch1, ch2, ch3} <= kind == K_GX && gvalid ? {gr, gg, gb} : trgb2;
        {s0, s1, s2}    <= tsync2;
    end
    altddio_out #(
        .extend_oe_disable("OFF"), .intended_device_family("Cyclone V"),
        .invert_output("OFF"), .lpm_hint("UNUSED"), .lpm_type("altddio_out"),
        .oe_reg("UNREGISTERED"), .power_up_high("OFF"), .width(1)
    ) pclk_ddio (
        .datain_h(1'b0), .datain_l(1'b1), .outclock(clk), .dataout(pclk),
        .aclr(1'b0), .aset(1'b0), .oe(1'b1), .oe_out(), .outclocken(1'b1), .sclr(1'b0), .sset(1'b0)
    );

    // pages turn at the last active line (blank on every page), before textmode samples the
    // status words at the start of vertical blanking; the bit image before each press pauses
    // the cycle
    reg [31:0] frames = 32'd0;
    reg [9:0]  vy_d = 10'd0;
    reg [9:0]  pframes = 10'd0;
    wire       vp_dump;
    wire [48:0] pe_dp = pg(dp);
    wire [9:0] pg_frames = HALF_SEC_FRAMES == 0 ? 10'd1 : pe_dp[7:4] * HALF_SEC_FRAMES;
    always @(posedge clk) begin
        vy_d <= vy;
        if (vy == 10'd719 && vy_d == 10'd718) begin
            frames <= frames + 32'd1;
            dps <= vp_dump ? DUMP_PAGE : dp;
            pe  <= pg(vp_dump ? DUMP_PAGE : dp);
            if (!vp_dump) begin
                if (pframes >= pg_frames - 10'd1) begin
                    pframes <= 10'd0;
                    dp <= dp == NPAGES - 6'd1 ? 6'd0 : dp + 6'd1;
                    dps <= dp == NPAGES - 6'd1 ? 6'd0 : dp + 6'd1;
                    pe  <= pg(dp == NPAGES - 6'd1 ? 6'd0 : dp + 6'd1);
                end else
                    pframes <= pframes + 10'd1;
            end
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
    // link tables (text rows 2-20 = 19 entries): K_L1 = first status read - 16 .. + 2, K_L2 =
    // the newest 19 big write runs, K_L3 = the newest 19 entries
    wire [31:0] l_nwr, l_nrd, l_noth, l_nstat, l_addr, l_us, l_last, l_after, l_arm, l_pollt, l_fixt;
    wire [31:0] l_all, l_first, l_big, l_nolog;
    wire        l_have;
    wire [3:0]  l_cand, l_fixc;
    wire [7:0]  l_ans, l_steps;
    wire        l_fixed, l_polling, l_rd2, l_xfer;
    wire [31:0] l_xaddr;
    wire        w_go;
    wire [31:0] w_addr;
    wire [7:0]  w_data;
    wire [1:0]  emu_st;
    wire        lsel = kind == K_L2;
    wire [31:0] base1 = !l_have ? 32'd0 : l_first < 32'd16 ? 32'd0 : l_first - 32'd16;
    wire [31:0] base2 = l_big > 32'd19 ? l_big - 32'd19 : 32'd0;
    wire [31:0] base3 = l_all > 32'd19 ? l_all - 32'd19 : 32'd0;
    wire [31:0] lbase = kind == K_L1 ? base1 : kind == K_L2 ? base2 : base3;
    wire [31:0] lidx = lbase + {27'd0, row_next} - 32'd2;
    wire [191:0] lent;
    wire [31:0] lent_idx;
    wire        lvalid;
    wire [127:0] regs2;
    link_logger #(.STEP_US(STEP_US), .FIRST_CAND(FIRST_CAND), .NOLOG(16'h0003), .XFER(FILE_RUN)) link (
        .clk(clk), .a(link_a), .n_rd(link_nrd), .n_wr(link_nwr), .d_in(link_d),
        .emu_status(emu_st), .regs2(regs2), .d_out(ld_out), .d_oe(ld_oe),
        .w_go(w_go), .w_addr(w_addr), .w_data(w_data),
        .sel(lsel), .idx(lidx), .entry(lent), .entry_idx(lent_idx), .entry_valid(lvalid),
        .n_nolog(l_nolog), .rd2(l_rd2), .xfer(l_xfer), .xfer_addr(l_xaddr),
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
    wire [7:0]  vp_np, vp_xnp;
    wire [31:0] vp_uit, vp_xt, vp_xdt, vp_pt, vp_out;
    wire        vp_go;
    vpress #(.WAIT_US(VP_WAIT_US), .PRESS_US(VP_PRESS_US), .GAP_US(VP_GAP_US),
             .DUMP_US(VP_DUMP_US), .DUMP_END(VP_DUMP_END), .SCRIPT(VP_SCRIPT)) vp (
        .clk(clk), .usec(l_us), .ui_rd(l_rd2), .wr(w_go), .wr_addr(w_addr), .xfer(l_xfer),
        .xfer_addr(l_xaddr), .mask(vmask), .state(vp_state), .btn(vp_btn), .n_press(vp_np),
        .press_go(vp_go), .dump(vp_dump), .press_t(vp_pt), .ui_t(vp_uit), .n_out(vp_out),
        .xfer_btn(vp_xbtn), .xfer_np(vp_xnp), .xfer_t(vp_xt), .xfer_dt(vp_xdt));

    // ---------------------------------------------------------------- the player's screen
    wire [10:0]  tv_aaddr;
    wire [13:0]  hx_baddr;
    wire [255:0] crc_blk;
    wire [31:0]  crc_font, crc_pal, crc_x17, scr_crc, n_scr_wr, scr_wr_t, upd_t;
    wire [7:0]   n_upd, n_pt;
    wire [5:0]   h_idx;
    reg  [5:0]   p_idx = 6'd0;
    wire [63:0]  h_q, p_q;
    ui_capture #(.QUIET_US(QUIET_US)) cap (
        .clk(clk), .usec(l_us), .w_go(w_go), .w_addr(w_addr), .w_data(w_data),
        .press_go(vp_go), .n_press(vp_np), .btn(vp_btn),
        .a_addr(kind == K_TV ? tv_aaddr : g_aaddr), .a_q(c_aq),
        .b_addr(kind == K_HX ? hx_baddr : g_baddr), .b_q(c_bq),
        .crc_blk(crc_blk), .crc_font(crc_font), .crc_pal(crc_pal), .crc_x17(crc_x17),
        .scr_crc(scr_crc), .n_scr_wr(n_scr_wr), .scr_wr_t(scr_wr_t), .n_upd(n_upd),
        .upd_t(upd_t), .h_idx(h_idx), .h_q(h_q), .p_idx(p_idx), .p_q(p_q), .n_pt(n_pt));

    // text view: the cell textmode draws next (one clock after its counters) -> screen byte;
    // the RAM answers with textmode's template read, the byte is picked a clock later
    wire [7:0]  tv_row = {3'd0, crow} - 8'd1 + {3'd0, pe[23:19]};
    wire [8:0]  tv_col = {2'd0, ccol} + {2'd0, pe[30:24]};
    wire        tv_ok  = crow != 5'd0 && tv_row < 8'd32 && (pe[16] ? tv_col < 9'd64 : tv_col < 9'd128);
    wire [11:0] tv_byte = {tv_row[4:0], 7'd0} | (pe[16] ? {4'd0, tv_col[5:0], 1'b0} : {5'd0, tv_col[6:0]});
    assign tv_aaddr = tv_byte[11:1];
    reg tv_ok2 = 1'b0, tv_bs2 = 1'b0;
    always @(posedge clk) begin
        tv_ok2 <= tv_ok;
        tv_bs2 <= tv_byte[0];
    end
    assign ext_q = !tv_ok2 ? 8'h20 : tv_bs2 ? c_aq[15:8] : c_aq[7:0];

    // row fetch for the hex dump and the press table: 18 clocks from x = 1290 of every line,
    // for text row row_next (textmode takes the row's words at the end of the line)
    reg  [4:0]  sk = 5'd31;
    reg  [13:0] hx_q = 14'd0;
    reg  [15:0] hw [0:15];
    reg  [63:0] pw [0:2];
    wire [4:0]  hrow = row_next - 5'd1;
    wire [5:0]  prow = {1'b0, row_next} - 6'd2;
    assign hx_baddr = hx_q;
    integer ki;
    always @(posedge clk) begin
        if (tx == 11'd1290) sk <= 5'd0;
        else if (sk != 5'd31) sk <= sk + 5'd1;
        hx_q <= pe[48:35] + {hrow, 4'd0} + {9'd0, sk[3:0]};
        p_idx <= sk[1:0] == 2'd0 ? prow : sk[1:0] == 2'd1 ? prow + 6'd19 : prow + 6'd38;
        if (sk >= 5'd2 && sk < 5'd18) hw[sk[3:0] - 4'd2] <= c_bq;
        if (sk >= 5'd2 && sk < 5'd5)
            pw[sk - 5'd2] <= {1'b0, sk - 5'd2 == 5'd0 ? prow : sk - 5'd2 == 5'd1 ? prow + 6'd19 : prow + 6'd38} < {1'b0, n_pt[5:0]} || n_pt[7:6] != 2'd0 ? p_q : 64'd0;
    end
    // screen history: the newest 18 changes on rows 4-21
    wire [7:0]  hbase = n_upd > 8'd18 ? n_upd - 8'd18 : 8'd0;
    wire [7:0]  hent  = hbase + {3'd0, row_next} - 8'd4;
    assign h_idx = hent[5:0];
    reg  [7:0]  hent_q = 8'd0;
    always @(posedge clk) hent_q <= hent;

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
    assign st[20] = {lbase[15:0], kind == K_L2 ? l_big[15:0] : l_all[15:0]};
    assign st[21] = l_arm;
    assign st[22] = {2'd0, dps, e_out1};
    // flags: 0-11 held buttons (real pad), 12-23 virtual presses now
    assign st[23] = {8'd0, vmask[11:0], praw0[31:12] == 20'hFFFF0 ? praw0[11:0] : 12'd0};

    // ---------------------------------------------------------------- per-row words 24-31
    wire [31:0] w_dp  = {2'd0, dps, 24'd0};
    wire [31:0] w_t   = {12'd0, l_us[29:10]};
    wire [31:0] w_np  = {vp_np, 24'd0};
    wire [31:0] w_upt = {12'd0, upd_t[29:10]};
    // overview: more overview words; its "SCREEN" line (row 15) has its own
    wire [255:0] ov = {
        {l_big[15:0], 3'd0, pad_std, 4'd0, pad_rd_q[39:32]},          // 31
        vp_xdt,                                                     // 30
        {12'd0, vp_xt[29:10]},                                      // 29
        {vp_xbtn, 4'd0, vp_xnp, 16'd0},                             // 28
        {12'd0, vp_uit[29:10]},                                     // 27
        {2'd0, vp_state, vp_btn, vp_np, vmask},                     // 26
        pad_rd_q[31:0],                                             // 25
        l_nolog};                                                   // 24
    wire [255:0] ov_scr = {128'd0, vp_out, n_scr_wr, {n_upd, 4'd0, upd_t[29:10]}, scr_crc};
    // screen history
    wire [255:0] hi_row =
        row_next == 5'd0 ? {192'd0, w_t, w_dp} :
        row_next == 5'd1 ? {128'd0, {12'd0, scr_wr_t[29:10]}, n_scr_wr, {n_upd, 24'd0}, scr_crc} :
        row_next == 5'd2 ? {160'd0, crc_x17, crc_pal, crc_font} :
        row_next == 5'd3 ? 256'd0 :
        {128'd0, {h_q[43:32], 20'd0}, h_q[31:0], {12'd0, h_q[63:44]}, {hent_q, 24'd0}};
    // press table: 3 entries per row
    wire [255:0] pr_row = row_next == 5'd0 ? {224'd0, w_dp} :
                          {64'd0, pw[2][31:0], pw[2][63:32], pw[1][31:0], pw[1][63:32],
                           pw[0][31:0], pw[0][63:32]};
    // text view header
    wire [255:0] tv_row0 = {32'd0, w_dp, w_np, w_upt, scr_crc, {25'd0, pe[30:24]},
                            {27'd0, pe[23:19]}, {28'd0, pe[16] ? 4'd2 : 4'd1}};
    // hex dump: header, then 32 bytes per row (word k = bytes 4k .. 4k + 3, first byte left)
    wire [255:0] hx_data;
    generate for (gk = 0; gk < 8; gk = gk + 1) begin : g_hx
        assign hx_data[32*gk +: 32] = {hw[2*gk][7:0], hw[2*gk][15:8], hw[2*gk+1][7:0], hw[2*gk+1][15:8]};
    end endgenerate
    wire [31:0] hx_crc = crc_blk[{pe[48:46], 5'd0} +: 32];
    wire [255:0] hx_row = row_next == 5'd0 ? {96'd0, w_dp, w_np, w_upt, hx_crc, {17'd0, pe[48:34]}} : hx_data;
    // graphics header: view, format, crc (bits: of the block shown)
    wire [3:0]  g_bpp  = pe[14:13] == 2'd0 ? 4'd1 : pe[14:13] == 2'd1 ? 4'd2 : pe[14:13] == 2'd2 ? 4'd4 : 4'd8;
    wire [31:0] g_w25  = {2'd0, pe[9:8], 4'd0, pe[11] ? 8'h10 : 8'h08, pe[12] ? 8'h10 : 8'h08, g_bpp,
                          pe[10] ? 4'hF : {3'd0, pe[15]}};
    wire [31:0] g_w26  = {pe[16] ? 4'd2 : 4'd1, pe[17] ? 4'd2 : 4'd1, pe[18] ? 4'd2 : 4'd1,
                          1'b0, pe[33:31], 3'd0, pe[23:19], 1'b0, pe[30:24]};
    wire [31:0] g_crc  = pe[9:8] == 2'd3 ? crc_blk[{pe[33:31], 5'd0} +: 32] : scr_crc;
    wire [255:0] gx_row = {64'd0, w_np, w_upt, g_crc, g_w26, g_w25, w_dp};

    wire [255:0] s_err32;
    generate for (gk = 0; gk < 8; gk = gk + 1) begin : g_err
        assign s_err32[32*gk +: 32] = {8'd0, s_err[24*gk +: 24]};
    end endgenerate
    assign rowstat = kind == K_OV ? (row_next == 5'd15 ? ov_scr : ov) :
                     kind == K_S1 ? s_err32 :
                     kind == K_S2 ? {96'd0, s_raw} :
                     kind == K_HI ? hi_row :
                     kind == K_PR ? pr_row :
                     kind == K_TV ? tv_row0 :
                     kind == K_HX ? hx_row :
                     kind == K_GX ? gx_row : link_row;
    assign row_blank = ((kind == K_L1 || kind == K_L2 || kind == K_L3) && row_next >= 5'd2 && !lvalid) ||
                       (kind == K_HI && row_next >= 5'd4 && hent_q >= n_upd) ||
                       (kind == K_PR && row_next >= 5'd2 && row_next <= 5'd20 &&
                        n_pt[7:6] == 2'd0 && prow >= n_pt[5:0]);
endmodule
