// SPDX-License-Identifier: GPL-3.0-or-later
// 1280x720p60 status screen for the Super Nt test cores: 80 x 22 character cells of 16 x 32
// pixels (an 8x16 VGA font drawn at double size), laid out by a template ROM compiled from a
// text file (tools/mkscreen.py, up to PAGES pages), with live hex fields taken from 32 status
// words. Words 0-23 come from `stat`; words 24-31 are per text row (`rowstat`, for tables): the
// caller sees `row_next` (the text row of the next video line) and must present that row's
// words, and `row_blank` to hide the row, by the end of the line before the row starts.
// Conditional text cells (mkscreen `{?F:TEXT}`) are drawn only while bit F of status word
// FLAG_WORD is 1. External character cells (mkscreen `{E:n}`, template code 7F) show the byte
// `ext_q` the caller reads for the cell (`cell_row`, `cell_col`, valid from the clock after the
// counters; `ext_q` is wanted one clock later, like a block RAM read with its address taken
// from them): its low 7 bits as the character, yellow for codes 80-FF; control codes 01-1F as
// '@' + code in cyan, 00 blank. `cx`/`cy` are the pixel counters (for a graphics layer beside
// this one) and `fg` marks the pixels drawn in a text colour.
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
    input  wire [3:0]    page,
    input  wire [767:0]  stat,          // status words 0-23, word w = stat[32*w +: 32]
    input  wire [255:0]  rowstat,       // words 24-31 for row_next (word 24 + k = [32*k +: 32])
    input  wire          row_blank,     // hide row_next entirely
    output reg  [4:0]    row_next = 5'd0,
    output reg  [7:0]    r, g, b,
    output reg           hs, vs, de,
    output reg  [9:0]    frame_y = 10'd0, // current line, for callers that need frame timing
    output wire [10:0]   cx,            // pixel counter (output appears 5 clocks later)
    output wire [9:0]    cy,
    output reg  [4:0]    cell_row = 5'd0, // text cell of the pixel one clock after cx/cy
    output reg  [6:0]    cell_col = 7'd0,
    input  wire [7:0]    ext_q,         // its external character (wanted two clocks after cx/cy)
    output reg           fg = 1'b0      // pixel drawn in a text colour
);
    localparam H_ACT = 1280, H_FP = 110, H_SYNC = 40, H_TOT = 1650;
    localparam V_ACT = 720,  V_FP = 5,   V_SYNC = 5,  V_TOT = 750;

    reg [10:0] x = 11'd0;
    reg [9:0]  y = 10'd0;
    assign cx = x;
    assign cy = y;
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

    // Row data, taken once per text row at the end of the line before it (row_next was
    // presented during that line), so a value that changes while the row is drawn can't tear
    // its digits.
    reg [255:0] rs;
    reg         rb;
    always @(posedge clk)
        if (x == H_TOT - 1 && (y[4:0] == 5'd31 || y == V_TOT - 1)) begin
            rs <= rowstat;
            rb <= row_blank;
        end

    // Stage 1: cell address.
    reg [14:0] ta1 = 15'd0;
    reg [2:0]  gx1;
    reg [3:0]  gy1;
    reg        in1, hs1, vs1, de1;
    always @(posedge clk) begin
        ta1 <= page * 15'd1760 + {y[9:5], 6'd0} + {2'd0, y[9:5], 4'd0} + {4'd0, x[10:4]};
        cell_row <= y[9:5];
        cell_col <= x[10:4];
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
    reg [7:0]  e3;
    reg [2:0]  gx3;
    reg [3:0]  gy3;
    reg        in3, hs3, vs3, de3;
    wire [31:0] flags = st_q[32*FLAG_WORD +: 32];
    always @(posedge clk) begin
        w3 <= t2[12:11] == 2'b11 ? rs[{t2[10:8], 5'd0} +: 32] : st_q[{t2[12:8], 5'd0} +: 32];
        in3 <= in2 && !(!t2[15] && t2[12] && !flags[t2[11:7]]);
        t3 <= t2;
        e3 <= ext_q;
        gx3 <= gx2; gy3 <= gy2; hs3 <= hs2; vs3 <= vs2; de3 <= de2;
    end

    // Stage 4: glyph -> font byte.
    wire [3:0] nib = w3[{t3[2:0], 2'd0} +: 4];
    // external cells: 00 blank, 01-1F as '@' + code in cyan, 80-FF yellow (the same for the
    // low 7 bits)
    wire       ext = !t3[15] && t3[6:0] == 7'h7F;
    wire       ectl = e3[6:5] == 2'b00;
    wire [6:0] eg = !ectl ? e3[6:0] : e3 == 8'd0 ? 7'h20 : {2'b10, e3[4:0]};
    wire [6:0] glyph = t3[15] ? (nib < 4'd10 ? 7'h30 + {3'd0, nib} : 7'h37 + {3'd0, nib})
                              : ext ? eg : t3[6:0];
    reg [7:0] f4;
    reg [1:0] c4;
    reg [2:0] gx4;
    reg       in4, hs4, vs4, de4;
    always @(posedge clk) begin
        f4 <= font[{glyph, gy3}];
        c4 <= ext && e3[7] ? 2'd2 : ext && ectl && e3 != 8'd0 ? 2'd1 : t3[14:13];
        gx4 <= gx3; in4 <= in3; hs4 <= hs3; vs4 <= vs3; de4 <= de3;
    end

    // Stage 5: pixel.
    wire on = in4 && f4[3'd7 - gx4];
    always @(posedge clk) begin
        hs <= hs4; vs <= vs4; de <= de4;
        fg <= on;
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
