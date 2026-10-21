// PLL test: measures an fPLL clock against the 74.25 MHz board clock and shows the result on a
// 720p60 picture (same video pins and timing as hw/vtest). Build: make out/plltest.cor.
//
// clk_pll comes from the placeholder clock buffer `pll_snes`: nextpnr routes it like any global
// clock (from the W16 pin), then tools/pllpatch.py (driven by pll.cfg) rewires that global to
// FPLL.000.000 C0, configured for 21.477273 MHz with the SPC core's own settings
// (notes/pll.md). The BEL attribute puts the buffer on the left global clock mux, the one that
// FPLL.000.000 can reach; the 74.25 MHz video clock gets the right one.
//
// Every frame (1650 x 750 board clocks = 1/60 s) the number of clk_pll cycles is latched:
// 21.477273 MHz / 60 = 357954.5, so 357954 or 357955 (0x57642/0x57643) if the PLL runs as
// configured, whatever the board clock really is (the PLL is locked to it).
//
// Screen (sync pin roles cycle every 8 s like vtest; the boxes at the top show which is active):
//   - row of 20 boxes at y 140-220: the latched count, MSB left; filled = 1, a thin bar = 0
//     (expected pattern 0101 0111 0110 0100 001x),
//   - big block at y 300-600: solid white = count within +-2 of 357954.5 (PLL OK),
//     vertical stripes = clock running but at another frequency, black = no PLL clock at all.
// Pins: only pins the SPC core already drives as outputs, plus W16 as input (hw/vtest).
module top (
    input  wire       clk,      // W16, 74.25 MHz board clock; also the fPLL's reference
    output wire       pclk,     // M22
    output reg        s0,       // P16
    output reg        s1,       // M16
    output reg        s2,       // M18
    output reg  [7:0] ch1,      // N19 N16 P18 P19 R21 R22 P22 N20 (bit 7..0)
    output reg  [7:0] ch2,      // T22 R15 T18 T17 L22 M20 K22 K21
    output reg  [7:0] ch3       // R17 P17 N21 M21 R16 T19 T15 T20
);
    // Clock buffers. Both are instantiated by hand: if the board clock went through yosys'
    // automatic buffer, the placeholder's input would be fed from that global instead of the pin.
    wire clk74, clk_pll;
    MISTRAL_CLKBUF ref_buf (.A(clk), .Q(clk74));
    (* BEL = "MISTRAL_CLKENA.0.22.0" *)
    MISTRAL_CLKBUF pll_snes (.A(clk), .Q(clk_pll));   // placeholder, see pll.cfg

    // ---- PLL clock domain: free-running Gray counter.
    reg [19:0] pbin = 0, pgray = 0;
    always @(posedge clk_pll) begin
        pbin  <= pbin + 20'd1;
        pgray <= (pbin >> 1) ^ pbin;
    end

    // ---- Video clock domain.
    localparam H_ACT = 1280, H_FP = 110, H_SYNC = 40, H_TOT = 1650;
    localparam V_ACT = 720,  V_FP = 5,   V_SYNC = 5,  V_TOT = 750;
    localparam [19:0] EXPECT_LO = 20'd357952, EXPECT_HI = 20'd357957;

    assign pclk = ~clk74;

    reg [10:0] x = 0;
    reg [9:0]  y = 0;
    reg [8:0]  frames = 0;
    reg [2:0]  perm = 0;
    always @(posedge clk74) begin
        if (x == H_TOT - 1) begin
            x <= 0;
            if (y == V_TOT - 1) begin
                y <= 0;
                if (frames == 479) begin
                    frames <= 0;
                    perm <= (perm == 5) ? 3'd0 : perm + 3'd1;
                end else
                    frames <= frames + 9'd1;
            end else
                y <= y + 10'd1;
        end else
            x <= x + 11'd1;
    end

    // Gray count into this domain (2 flops), back to binary, difference once per frame.
    reg [19:0] g1 = 0, g2 = 0, prev = 0, count = 0;
    wire [19:0] gbin;
    genvar i;
    generate for (i = 0; i < 20; i = i + 1) begin : g2b
        assign gbin[i] = ^(g2 >> i);
    end endgenerate
    always @(posedge clk74) begin
        g1 <= pgray;
        g2 <= g1;
        if (x == 0 && y == 0) begin
            count <= gbin - prev;
            prev  <= gbin;
        end
    end
    wire ok   = count >= EXPECT_LO && count <= EXPECT_HI;
    wire dead = count == 0;

    wire hs = (x >= H_ACT + H_FP) && (x < H_ACT + H_FP + H_SYNC);
    wire vs = (y >= V_ACT + V_FP) && (y < V_ACT + V_FP + V_SYNC);
    wire de = (x < H_ACT) && (y < V_ACT);

    // Pattern position counters (no per-pixel division, so it meets timing at 74.25 MHz).
    // Top band: perm+1 white boxes (as vtest): 100 px wide on a 160 px pitch from x = 40.
    reg [7:0]  bpos = 0;
    reg [3:0]  box = 0;
    // Count bits: 20 cells on a 60 px pitch from x = 40, MSB first.
    reg [5:0]  cpos = 0;
    reg [4:0]  bcell = 0;
    always @(posedge clk74) begin
        if (x == 39 || x == H_TOT - 1) begin
            bpos <= 0; box <= 0; cpos <= 0; bcell <= 0;
        end else begin
            if (bpos == 159) begin bpos <= 0; box <= box + 4'd1; end
            else bpos <= bpos + 8'd1;
            if (cpos == 59) begin cpos <= 0; bcell <= bcell + 5'd1; end
            else cpos <= cpos + 6'd1;
        end
    end
    wire        in_band = (y >= 20) && (y < 100);
    wire        in_box  = in_band && (x >= 40) && (bpos < 100) && (box <= perm);
    wire        in_row  = (y >= 140) && (y < 220) && (x >= 40) && (x < 40 + 20 * 60);
    wire        in_cell = cpos < 40;
    wire        bit_on  = count[5'd19 - bcell];
    wire        bit_px  = in_row && in_cell && (bit_on || y >= 210);

    // Status block.
    wire        in_stat = (y >= 300) && (y < 600) && (x >= 40) && (x < 1240);
    wire        stat_px = in_stat && (ok ? 1'b1 : dead ? 1'b0 : x[5]);

    always @(posedge clk74) begin
        {ch1, ch2, ch3} <= (de && (in_box || bit_px || stat_px)) ? 24'hffffff : 24'h000000;
        case (perm)     // {s0, s1, s2} = {P16, M16, M18}
            3'd0: {s0, s1, s2} <= {hs, vs, de};
            3'd1: {s0, s1, s2} <= {hs, de, vs};
            3'd2: {s0, s1, s2} <= {vs, hs, de};
            3'd3: {s0, s1, s2} <= {vs, de, hs};
            3'd4: {s0, s1, s2} <= {de, hs, vs};
            default: {s0, s1, s2} <= {de, vs, hs};
        endcase
    end
endmodule
