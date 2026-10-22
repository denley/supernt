// SPDX-License-Identifier: GPL-3.0-or-later
// On-screen layer for quartus/snes_load (notes/snes-load.md), drawn over (instead of) the SNES
// picture on snes_video.sv's 1280x720 counters. Two views, both with the 8x16 VGA console font
// (build/hwtest/font.hex, ASCII 00-7F) drawn twice as wide:
//
//   mode 1, browser: the SPC player's own screen as the PIC writes it to 0x1018_0000
//     (link_ui.sv): 64 x 32 cells of {character, attribute}, each cell 16 x 22 pixels (the
//     glyph's 16 rows from the 4th line), 1024 x 704 from x = 128, y = 8. hwtest v5 showed this
//     layout legibly ("view 04", our font: the player's own 8 KB glyph set never rendered as
//     text in any format tried). Attribute bits 6-5 (0x60, the cursor row) = highlight bar;
//     characters 80-FF are the player's icons, drawn in yellow as best guesses from the screens
//     seen (81 B, 83 Y, 89 '#', 8A '+', 9E-A3 "START ", A4-A9 "SELECT", B2 '<', others '*').
//   mode 2, diagnostics: a text page compiled from a template (tools/mkscreen.py) as
//     textmode.sv: 80 x 22 cells of 16 x 32 pixels, hex fields of 64 status words (0-55 from
//     `stat`, sampled once per frame; 56-63 per text row from `rowstat`, which the caller
//     presents for `row_next`), conditional text on bits of word FLAG_WORD, external cells
//     (template code 7F) showing the byte `ext_q` the caller reads for (ext_row, ext_col).
//   mode 0: nothing (valid = 0).
// Timing: hx/vy are snes_video's counters (cycle 0); r/g/b/valid are registered at cycle 6, so
// the caller delays snes_video's outputs (registered at cycle 3) by 3 clocks.
module overlay #(
    parameter TMPL_HEX = "diag.hex",
    parameter FONT_HEX = "font.hex",
    parameter integer FLAG_WORD = 1
) (
    input  wire          clk,
    input  wire [10:0]   hx,
    input  wire [9:0]    vy,
    input  wire [1:0]    mode,
    input  wire [1791:0] stat,              // words 0-55, word w = stat[32*w +: 32]
    input  wire [255:0]  rowstat,           // words 56-63 for row_next
    output reg  [4:0]    row_next = 5'd0,
    output reg  [10:0]   scr_addr = 11'd0,  // screen cell (1 clock latency to scr_q)
    input  wire [15:0]   scr_q,
    output reg  [4:0]    ext_row = 5'd0,    // external cell (1 clock latency to ext_q)
    output reg  [6:0]    ext_col = 7'd0,
    input  wire [7:0]    ext_q,
    output reg  [7:0]    r = 8'd0, g = 8'd0, b = 8'd0,
    output reg           valid = 1'b0
);
    localparam H_TOT = 1650, V_ACT = 720;

    (* ramstyle = "M10K" *) reg [15:0] tmpl [0:80*22-1];
    (* ramstyle = "M10K" *) reg [7:0]  font [0:2047];
    initial begin
        $readmemh(TMPL_HEX, tmpl);
        $readmemh(FONT_HEX, font);
    end

    // ---------------------------------------------------------------- per-frame / per-row data
    reg [1791:0] st_q;
    always @(posedge clk)
        if (hx == 11'd0 && vy == V_ACT) st_q <= stat;
    always @(posedge clk)
        row_next <= (vy == 10'd749) ? 5'd0 : vy[9:5] + {4'd0, &vy[4:0]};
    reg [255:0] rs;
    always @(posedge clk)
        if (hx == H_TOT - 1 && (vy[4:0] == 5'd31 || vy == 10'd749)) rs <= rowstat;

    // browser rows: 22 lines per cell row from line 8 (updated at the start of each line)
    reg [4:0] brow = 5'd0;
    reg [4:0] bl = 5'd0;
    reg       bon = 1'b0;               // inside the 32 cell rows
    always @(posedge clk)
        if (hx == 11'd0) begin
            if (vy == 10'd8) begin
                brow <= 5'd0; bl <= 5'd0; bon <= 1'b1;
            end else if (bon) begin
                if (bl == 5'd21) begin
                    bl <= 5'd0;
                    if (brow == 5'd31) bon <= 1'b0;
                    else brow <= brow + 5'd1;
                end else
                    bl <= bl + 5'd1;
            end
        end

    // ---------------------------------------------------------------- stage 1: cell
    wire [10:0] bx = hx - 11'd128;
    reg [10:0] ta1 = 11'd0;
    reg [2:0]  dgx1, bgx1;
    reg [3:0]  dgy1, bgy1;
    reg        din1, bin1;
    reg [1:0]  m1;
    always @(posedge clk) begin
        ta1 <= {vy[9:5], 6'd0} + {2'd0, vy[9:5], 4'd0} + {4'd0, hx[10:4]};
        ext_row <= vy[9:5];
        ext_col <= hx[10:4];
        dgx1 <= hx[3:1];
        dgy1 <= vy[4:1];
        din1 <= hx < 11'd1280 && vy < 10'd704;
        scr_addr <= {brow, bx[9:4]};
        bgx1 <= bx[3:1];
        bgy1 <= bl[3:0] - 4'd3;
        bin1 <= bon && hx >= 11'd128 && hx < 11'd1152;
        m1 <= mode;
    end

    // ---------------------------------------------------------------- stage 2: template word
    reg [15:0] t2;
    reg [2:0]  dgx2, bgx2;
    reg [3:0]  dgy2, bgy2;
    reg        din2, bin2, bgl2;
    reg [1:0]  m2;
    always @(posedge clk) begin
        t2 <= tmpl[ta1];
        {dgx2, bgx2, dgy2, bgy2, din2, bin2, m2} <= {dgx1, bgx1, dgy1, bgy1, din1, bin1, m1};
        bgl2 <= bl >= 5'd3 && bl < 5'd19;   // (one line late is fine: bl is per line)
    end

    // ---------------------------------------------------------------- stage 3: field value
    wire [5:0]  wsel = {t2[3], t2[12:8]};
    wire [31:0] flags = st_q[32*FLAG_WORD +: 32];
    reg  [31:0] w3;
    reg  [15:0] t3, s3;
    reg  [7:0]  e3;
    reg  [2:0]  dgx3, bgx3;
    reg  [3:0]  dgy3, bgy3;
    reg         din3, bin3, bgl3;
    reg  [1:0]  m3;
    always @(posedge clk) begin
        w3 <= wsel >= 6'd56 ? rs[{wsel[2:0], 5'd0} +: 32] : st_q[{wsel, 5'd0} +: 32];
        din3 <= din2 && !(!t2[15] && t2[12] && !flags[t2[11:7]]);
        t3 <= t2;
        e3 <= ext_q;
        s3 <= scr_q;
        {dgx3, bgx3, dgy3, bgy3, bin3, bgl3, m3} <= {dgx2, bgx2, dgy2, bgy2, bin2, bgl2, m2};
    end

    // ---------------------------------------------------------------- stage 4: glyph
    function [8:0] icon(input [6:0] c);     // {yellow, glyph}
        case (c)
            7'h01: icon = {1'b1, 7'h42};    // B
            7'h03: icon = {1'b1, 7'h59};    // Y
            7'h09: icon = {1'b1, 7'h23};    // #
            7'h0A: icon = {1'b1, 7'h2B};    // +
            7'h1E: icon = {1'b1, 7'h53};    // S T A R T
            7'h1F: icon = {1'b1, 7'h54};
            7'h20: icon = {1'b1, 7'h41};
            7'h21: icon = {1'b1, 7'h52};
            7'h22: icon = {1'b1, 7'h54};
            7'h23: icon = {1'b1, 7'h20};
            7'h24: icon = {1'b1, 7'h53};    // S E L E C T
            7'h25: icon = {1'b1, 7'h45};
            7'h26: icon = {1'b1, 7'h4C};
            7'h27: icon = {1'b1, 7'h45};
            7'h28: icon = {1'b1, 7'h43};
            7'h29: icon = {1'b1, 7'h54};
            7'h32: icon = {1'b1, 7'h3C};    // <
            default: icon = {1'b1, 7'h2A};  // *
        endcase
    endfunction
    wire [3:0] nib = w3[{t3[2:0], 2'd0} +: 4];
    wire       ext = !t3[15] && t3[6:0] == 7'h7F;
    wire       ectl = e3[6:5] == 2'b00;
    wire [6:0] eg = !ectl ? e3[6:0] : e3 == 8'd0 ? 7'h20 : {2'b10, e3[4:0]};
    wire [6:0] dglyph = t3[15] ? (nib < 4'd10 ? 7'h30 + {3'd0, nib} : 7'h37 + {3'd0, nib})
                               : ext ? eg : t3[6:0];
    wire [8:0] ic = icon(s3[6:0]);
    wire [6:0] bglyph = s3[7] ? ic[6:0] : s3[6:5] == 2'b00 ? 7'h20 : s3[6:0];
    reg  [10:0] fa4;
    reg  [2:0]  c4;                      // colour: 0 white 1 cyan 2 yellow 3 green
    reg         hl4, on4, bpix4;
    reg  [2:0]  gx4;
    reg  [1:0]  m4;
    always @(posedge clk) begin
        if (m3 == 2'd1) begin
            fa4 <= {bglyph, bgy3};
            c4 <= s3[7] ? 3'd2 : 3'd0;
            hl4 <= s3[14:13] != 2'b00;
            on4 <= bin3;
            bpix4 <= bin3 && bgl3;
            gx4 <= bgx3;
        end else begin
            fa4 <= {dglyph, dgy3};
            c4 <= {1'b0, ext && e3[7] ? 2'd2 : ext && ectl && e3 != 8'd0 ? 2'd1 : t3[14:13]};
            hl4 <= 1'b0;
            on4 <= din3;
            bpix4 <= din3;
            gx4 <= dgx3;
        end
        m4 <= m3;
    end

    // ---------------------------------------------------------------- stage 5: font
    reg [7:0] f5;
    reg [2:0] c5, gx5;
    reg       hl5, on5, bpix5;
    reg [1:0] m5;
    always @(posedge clk) begin
        f5 <= font[fa4];
        {c5, gx5, hl5, on5, bpix5, m5} <= {c4, gx4, hl4, on4, bpix4, m4};
    end

    // ---------------------------------------------------------------- stage 6: pixel
    wire pix = bpix5 && f5[3'd7 - gx5];
    always @(posedge clk) begin
        valid <= m5 != 2'd0;
        if (pix) case (c5[1:0])
            2'd0:    {r, g, b} <= 24'hffffff;
            2'd1:    {r, g, b} <= 24'h40e0ff;
            2'd2:    {r, g, b} <= 24'hffe040;
            default: {r, g, b} <= 24'h40ff40;
        endcase
        else if (on5 && hl5)
            {r, g, b} <= 24'h2050b0;    // cursor bar
        else
            {r, g, b} <= 24'h000000;
    end
endmodule
