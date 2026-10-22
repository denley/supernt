// SPDX-License-Identifier: GPL-3.0-or-later
// 1280x720p60 status screen for the Super Nt test cores: 80 x 22 character cells of 16 x 32
// pixels (an 8x16 VGA font drawn at double size), laid out by a template ROM compiled from a
// text file (tools/mkscreen.py, up to PAGES pages), with live hex fields taken from 32 status
// words. Words 0-23 come from `stat`; words 24-31 are per text row (`rowstat`, for tables): the
// caller sees `row_next` (the text row of the next video line) and must present that row's
// words, and `row_blank` to hide the row, before the line starts. Conditional text cells
// (mkscreen `{?F:TEXT}`) are drawn only while bit F of status word FLAG_WORD is 1.
//
// Timing: CEA-861 VIC 4 (1650 x 750, positive syncs) on clk (74.25 MHz). Outputs are
// registered; hs/vs/de and the colour leave together, 5 clocks after the counters.
module textmode #(
    parameter SCREEN_HEX = "screen.hex",
    parameter FONT_HEX   = "font.hex",
    parameter PAGES      = 1,
    parameter integer FLAG_WORD = 23
) (
    input  wire          clk,
    input  wire [2:0]    page,
    input  wire [767:0]  stat,          // status words 0-23, word w = stat[32*w +: 32]
    input  wire [255:0]  rowstat,       // words 24-31 for row_next (word 24 + k = [32*k +: 32])
    input  wire          row_blank,     // hide row_next entirely
    output reg  [4:0]    row_next = 5'd0,
    output reg  [7:0]    r, g, b,
    output reg           hs, vs, de,
    output reg  [9:0]    frame_y = 10'd0  // current line, for callers that need frame timing
);
    localparam H_ACT = 1280, H_FP = 110, H_SYNC = 40, H_TOT = 1650;
    localparam V_ACT = 720,  V_FP = 5,   V_SYNC = 5,  V_TOT = 750;

    reg [10:0] x = 11'd0;
    reg [9:0]  y = 10'd0;
    always @(posedge clk) begin
        if (x == H_TOT - 1) begin
            x <= 11'd0;
            y <= (y == V_TOT - 1) ? 10'd0 : y + 10'd1;
        end else
            x <= x + 11'd1;
        frame_y <= y;
        row_next <= (y == V_TOT - 1) ? 5'd0 : y[9:5] + {4'd0, &y[4:0]};
    end

    (* ramstyle = "M10K" *) reg [15:0] tmpl [0:80*22*PAGES-1];
    (* ramstyle = "M10K" *) reg [7:0]  font [0:2047];
    initial begin
        $readmemh(SCREEN_HEX, tmpl);
        $readmemh(FONT_HEX, font);
    end

    // Status words are sampled once per frame, at the start of vertical blanking, so a field
    // never shows digits from two different values.
    reg [767:0] st_q;
    always @(posedge clk)
        if (x == 11'd0 && y == V_ACT) st_q <= stat;

    // Row data for the current line (row_next was presented during the previous line).
    reg [255:0] rs;
    reg         rb;
    always @(posedge clk)
        if (x == H_TOT - 1) begin
            rs <= rowstat;
            rb <= row_blank;
        end

    // Stage 1: cell address.
    reg [13:0] ta1 = 14'd0;
    reg [2:0]  gx1;
    reg [3:0]  gy1;
    reg        in1, hs1, vs1, de1;
    always @(posedge clk) begin
        ta1 <= page * 14'd1760 + {y[9:5], 6'd0} + {2'd0, y[9:5], 4'd0} + {4'd0, x[10:4]};
        gx1 <= x[3:1];
        gy1 <= y[4:1];
        in1 <= (x < H_ACT) && (y < 22 * 32) && !rb;
        de1 <= (x < H_ACT) && (y < V_ACT);
        hs1 <= (x >= H_ACT + H_FP) && (x < H_ACT + H_FP + H_SYNC);
        vs1 <= (y >= V_ACT + V_FP) && (y < V_ACT + V_FP + V_SYNC);
    end

    // Stage 2: template word.
    reg [15:0] t2;
    reg [2:0]  gx2;
    reg [3:0]  gy2;
    reg        in2, hs2, vs2, de2;
    always @(posedge clk) begin
        t2 <= tmpl[ta1];
        gx2 <= gx1; gy2 <= gy1; in2 <= in1; hs2 <= hs1; vs2 <= vs1; de2 <= de1;
    end

    // Stage 3: status word (for fields).
    reg [31:0] w3;
    reg [15:0] t3;
    reg [2:0]  gx3;
    reg [3:0]  gy3;
    reg        in3, hs3, vs3, de3;
    wire [31:0] flags = st_q[32*FLAG_WORD +: 32];
    always @(posedge clk) begin
        w3 <= t2[12:11] == 2'b11 ? rs[{t2[10:8], 5'd0} +: 32] : st_q[{t2[12:8], 5'd0} +: 32];
        in3 <= in2 && !(!t2[15] && t2[12] && !flags[t2[11:7]]);
        t3 <= t2;
        gx3 <= gx2; gy3 <= gy2; hs3 <= hs2; vs3 <= vs2; de3 <= de2;
    end

    // Stage 4: glyph -> font byte.
    wire [3:0] nib = w3[{t3[2:0], 2'd0} +: 4];
    wire [6:0] glyph = t3[15] ? (nib < 4'd10 ? 7'h30 + {3'd0, nib} : 7'h37 + {3'd0, nib})
                              : t3[6:0];
    reg [7:0] f4;
    reg [1:0] c4;
    reg [2:0] gx4;
    reg       in4, hs4, vs4, de4;
    always @(posedge clk) begin
        f4 <= font[{glyph, gy3}];
        c4 <= t3[14:13];
        gx4 <= gx3; in4 <= in3; hs4 <= hs3; vs4 <= vs3; de4 <= de3;
    end

    // Stage 5: pixel.
    wire on = in4 && f4[3'd7 - gx4];
    always @(posedge clk) begin
        hs <= hs4; vs <= vs4; de <= de4;
        if (!on)
            {r, g, b} <= 24'h000000;
        else case (c4)
            2'd0:    {r, g, b} <= 24'hffffff;   // white
            2'd1:    {r, g, b} <= 24'h40e0ff;   // cyan
            2'd2:    {r, g, b} <= 24'hffe040;   // yellow
            default: {r, g, b} <= 24'h40ff40;   // green
        endcase
    end
endmodule
