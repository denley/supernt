// SPDX-License-Identifier: GPL-3.0-or-later
// Graphics views of the captured player screen for the hwtest status display (hwtest v5,
// ui_capture.sv). Runs beside textmode.sv on its pixel counters and produces a pixel 7 clocks
// after (x, y) (textmode's own output is 5 clocks late; the caller delays it by 2).
// Below the header text row (y >= 32) the whole width is graphics while `valid`:
//   mode 1, map: the screen (capture 0x0000-0x0FFF) as a character / tile map with 128-byte
//     rows (v4b: 2-byte cells, ASCII character then an attribute byte, 64 per row); an entry
//     is 1 byte or 2 bytes (eb; the glyph is the first, low byte; the attribute is not used);
//     row roff and entry coff at the top left. Glyphs: gw x gh pixels (8/16), 1/2/4/8 bits per pixel (lbpp 0-3), packed
//     MSB-first (the leftmost pixel in the top bits of the row's first byte) or, for 2 bpp,
//     SNES planar (planar: a row = plane-0 byte, plane-1 byte), consecutive glyphs of
//     gh x gw x bpp / 8 bytes from capture 0x1000 (the 8 KB at 0x1006_0000), or our own 8x16
//     font (src = 1: 00 blank, 01-1F as '@' + code in cyan, 80-FF yellow as code - 80). Pixel values as grey levels
//     (1 bpp white on black, 2 bpp 00 55 AA FF, 4 bpp x 11, 8 bpp the value). Scale x2 per axis
//     (sx, sy). Cells outside the map are dark blue, glyph numbers past the end of the 8 KB
//     dark red.
//   mode 2, sheet: the same glyph formats, glyph n at column n mod 64, row n / 64 (a tile
//     viewer of the 8 KB).
//   mode 3, bits: 4 KB block `blk` of the capture as a bit image for tools/bitdump.py: 256 x
//     128 cells of 4 x 5 pixels (cell = one bit, 1 = white; row r = bytes 32r .. 32r + 31,
//     MSB first), surrounded by a timing ring (cells alternate, white where column + row is
//     even), a black margin cell and a white frame two cells thick: 264 x 136 cells from
//     x = 112, y = 36.
module gfx_render #(
    parameter FONT_HEX = "font.hex"
) (
    input  wire        clk,
    input  wire [10:0] x,               // textmode's counters (pixel 0-1279, line 0-719 active)
    input  wire [9:0]  y,
    input  wire [1:0]  mode,            // 0 off, 1 map, 2 sheet, 3 bits
    input  wire        src,             // glyphs: 0 captured, 1 own 8x16 font
    input  wire        gw,              // glyph width 8 / 16
    input  wire        gh,              // glyph height 8 / 16
    input  wire [1:0]  lbpp,            // 1, 2, 4, 8 bits per pixel
    input  wire        planar,          // 2 bpp SNES planar
    input  wire        eb,              // map entries of 1 / 2 bytes
    input  wire        sx, sy,          // x2 scale
    input  wire [4:0]  roff,            // first map row shown
    input  wire [6:0]  coff,            // first map entry shown in a row
    input  wire [2:0]  blk,             // bits: 4 KB block
    output reg  [10:0] a_addr,          // screen word (ui_capture copy A, 1 clock latency)
    input  wire [15:0] a_q,
    output reg  [13:0] b_addr,          // capture word (ui_capture copy B, 1 clock latency)
    input  wire [15:0] b_q,
    output reg  [7:0]  r, g, b,
    output reg         valid
);
    localparam [9:0]  Y0 = 10'd32;
    localparam [10:0] BX0 = 11'd112;
    localparam [9:0]  BY0 = 10'd36;

    (* ramstyle = "M10K" *) reg [7:0] font [0:2047];
    initial $readmemh(FONT_HEX, font);

    // bits mode: cell row from a line counter (5 lines per cell), set up in blanking
    reg [7:0] bcy = 8'd0;
    reg [2:0] bcl = 3'd0;
    wire [9:0] ny = y == 10'd749 ? 10'd0 : y + 10'd1;
    always @(posedge clk)
        if (x == 11'd1300) begin
            if (ny == BY0) begin
                bcy <= 8'd0;
                bcl <= 3'd0;
            end else if (bcl == 3'd4) begin
                bcl <= 3'd0;
                bcy <= bcy + 8'd1;
            end else
                bcl <= bcl + 3'd1;
        end

    // ---------------------------------------------------------------- stage 1: coordinates
    wire [9:0]  yy  = y - Y0;
    wire [10:0] gxs = sx ? {1'b0, x[10:1]} : x;
    wire [9:0]  gys = sy ? {1'b0, yy[9:1]} : yy;
    wire [10:0] bxr = x - BX0;
    reg [7:0] c1;
    reg [6:0] r1;
    reg [3:0] px1, py1;
    reg       in1, bin1;
    reg [8:0] bcx1;
    reg [7:0] bcy1;
    always @(posedge clk) begin
        c1  <= gw ? {1'b0, gxs[10:4]} : gxs[10:3];
        px1 <= gw ? gxs[3:0] : {1'b0, gxs[2:0]};
        r1  <= gh ? {1'b0, gys[9:4]} : gys[9:3];
        py1 <= gh ? gys[3:0] : {1'b0, gys[2:0]};
        // line 719 stays black: the caller turns pages at its start
        in1 <= mode != 2'd0 && x < 11'd1280 && y >= Y0 && y < 10'd719;
        bin1 <= x >= BX0 && bxr < 11'd1056 && y >= BY0 && y < BY0 + 10'd680;
        bcx1 <= bxr[10:2];
        bcy1 <= bcy;
    end

    // ---------------------------------------------------------------- stage 2: map address
    wire [7:0]  mrow = {1'b0, r1} + {3'd0, roff};
    wire [8:0]  mcol = {1'b0, c1} + {2'd0, coff};
    wire        mok  = mrow < 8'd32 && (eb ? mcol < 9'd64 : mcol < 9'd128);
    wire [11:0] mbyte = {mrow[4:0], 7'd0} | (eb ? {4'd0, mcol[5:0], 1'b0} : {5'd0, mcol[6:0]});
    wire [8:0]  dcx = bcx1 - 9'd4;
    wire [7:0]  dcy = bcy1 - 8'd4;
    reg        bs2, ok2, in2, bin2, bk2, bv2;
    reg [12:0] gs2;
    reg [3:0]  px2, py2;
    reg [11:0] bo2;
    reg [2:0]  bb2;
    always @(posedge clk) begin
        a_addr <= mbyte[11:1];
        bs2 <= mbyte[0];
        ok2 <= mode == 2'd2 ? c1 < 8'd64 : mok;
        gs2 <= {r1, c1[5:0]};
        px2 <= px1;
        py2 <= py1;
        in2 <= in1;
        bin2 <= bin1;
        // bits: frame (white), margin (black), timing ring, data
        if (bcx1 < 9'd2 || bcx1 >= 9'd262 || bcy1 < 8'd2 || bcy1 >= 8'd134) begin
            bk2 <= 1'b0; bv2 <= 1'b1;
        end else if (bcx1 == 9'd2 || bcx1 == 9'd261 || bcy1 == 8'd2 || bcy1 == 8'd133) begin
            bk2 <= 1'b0; bv2 <= 1'b0;
        end else if (bcx1 == 9'd3 || bcx1 == 9'd260 || bcy1 == 8'd3 || bcy1 == 8'd132) begin
            bk2 <= 1'b0; bv2 <= ~(bcx1[0] ^ bcy1[0]);
        end else begin
            bk2 <= 1'b1; bv2 <= 1'b0;
        end
        bo2 <= {dcy[6:0], dcx[7:3]};
        bb2 <= dcx[2:0];
    end

    // ---------------------------------------------------------------- stage 3: map word
    reg        bs3, ok3, in3, bin3, bk3, bv3;
    reg [12:0] gs3;
    reg [3:0]  px3, py3;
    reg [11:0] bo3;
    reg [2:0]  bb3;
    always @(posedge clk) begin
        {bs3, ok3, in3, bin3, bk3, bv3} <= {bs2, ok2, in2, bin2, bk2, bv2};
        gs3 <= gs2; px3 <= px2; py3 <= py2; bo3 <= bo2; bb3 <= bb2;
    end

    // ---------------------------------------------------------------- stage 4: glyph address
    wire [15:0] ent  = eb ? a_q : {8'd0, bs3 ? a_q[15:8] : a_q[7:0]};
    wire [12:0] gi   = mode == 2'd2 ? gs3 : {5'd0, ent[7:0]};    // 2-byte cells: low byte
    wire [3:0]  lbpr = {3'd0, gw} + {2'd0, lbpp};           // log2 bytes per glyph row
    wire [3:0]  lbpg = lbpr + 4'd3 + {3'd0, gh};             // log2 bytes per glyph
    wire        gok  = (gi >> (4'd13 - lbpg)) == 13'd0;
    wire [12:0] roww = {9'd0, py3} << lbpr;
    wire [12:0] colb = planar ? 13'd0 : {9'd0, px3} >> (4'd3 - {2'd0, lbpp});
    wire [12:0] goff = (gi << lbpg) | roww | colb;
    reg        bs4, ok4, gb4, in4, bin4, bk4, bv4, hi4, ct4;
    reg [3:0]  pk4;
    reg [10:0] fa4;
    always @(posedge clk) begin
        b_addr <= mode == 2'd3 ? {blk, bo3[11:1]} : 14'h0800 + {1'b0, goff[12:1]};
        bs4 <= mode == 2'd3 ? bo3[0] : goff[0];
        // own font: 00 blank, 01-1F (also above 80) as '@' + code, cyan; 80-FF yellow
        fa4 <= {gi[6:5] != 2'b00 ? gi[6:0] : gi[7:0] == 8'd0 ? 7'h20 : {2'b10, gi[4:0]}, py3};
        hi4 <= gi[7];
        ct4 <= gi[6:5] == 2'b00 && gi[7:0] != 8'd0;
        ok4 <= ok3;
        gb4 <= !(src || gok);
        pk4 <= mode == 2'd3 ? {1'b0, bb3} : px3;
        {in4, bin4, bk4, bv4} <= {in3, bin3, bk3, bv3};
    end

    // ---------------------------------------------------------------- stage 5: glyph data
    reg [7:0] fq;
    reg       bs5, ok5, gb5, in5, bin5, bk5, bv5, hi5, ct5;
    reg [3:0] pk5;
    always @(posedge clk) begin
        fq <= font[fa4];
        {bs5, ok5, gb5, in5, bin5, bk5, bv5, hi5, ct5} <= {bs4, ok4, gb4, in4, bin4, bk4, bv4, hi4, ct4};
        pk5 <= pk4;
    end

    // ---------------------------------------------------------------- stage 6: pixel value
    wire       own   = src && mode != 2'd3;
    wire [7:0] byte6 = own ? fq : bs5 ? b_q[15:8] : b_q[7:0];
    wire [2:0] bi    = 3'd7 - pk5[2:0];
    reg  [7:0] v6;
    reg        ok6, gb6, in6, bin6, bk6, bv6, hi6, ct6;
    always @(posedge clk) begin
        if (mode == 2'd3 || own || lbpp == 2'd0)
            v6 <= {7'd0, byte6[bi]};
        else if (lbpp == 2'd1)
            v6 <= planar ? {6'd0, b_q[{1'b1, bi}], b_q[{1'b0, bi}]}
                         : {6'd0, byte6[{~pk5[1:0], 1'b1}], byte6[{~pk5[1:0], 1'b0}]};
        else if (lbpp == 2'd2)
            v6 <= {4'd0, pk5[0] ? byte6[3:0] : byte6[7:4]};
        else
            v6 <= byte6;
        {ok6, gb6, in6, bin6, bk6, bv6, hi6, ct6} <= {ok5, gb5, in5, bin5, bk5, bv5, hi5, ct5};
    end

    // ---------------------------------------------------------------- stage 7: colour
    always @(posedge clk) begin
        valid <= in6;
        if (mode == 2'd3) begin
            if (bin6 && (bk6 ? v6[0] : bv6)) {r, g, b} <= 24'hFFFFFF;
            else                             {r, g, b} <= 24'h000000;
        end else if (!ok6)
            {r, g, b} <= 24'h000050;
        else if (gb6)
            {r, g, b} <= 24'h500000;
        else if (own)
            {r, g, b} <= !v6[0] ? 24'h000000 : hi6 ? 24'hFFE040 : ct6 ? 24'h40E0FF : 24'hFFFFFF;
        else case (lbpp)
            2'd0:    {r, g, b} <= {3{{8{v6[0]}}}};
            2'd1:    {r, g, b} <= {3{{4{v6[1:0]}}}};
            2'd2:    {r, g, b} <= {3{{2{v6[3:0]}}}};
            default: {r, g, b} <= {3{v6}};
        endcase
    end
endmodule
