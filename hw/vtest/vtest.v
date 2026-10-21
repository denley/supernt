// 720p60 video test for the HDMI transmitter (AD9889B) pins, from the 74.25 MHz board clock.
//
// Unknowns this resolves from a photo of the screen (pin map: notes/spc-core.md):
// - Which of P16/M16/M18 is HSYNC/VSYNC/DE. The core cycles through all 6 assignments, 8 s each.
//   When the TV locks, the row of white boxes at the top shows which one (1-6 boxes = index 0-5).
// - The colour pin order. Below the boxes are 24 stripes, each driving exactly one colour pin, in
//   the proposed order ch1 bit 7..0, ch2 bit 7..0, ch3 bit 7..0. If the proposal is right they
//   read as three fading groups of one primary colour each. Right-hand block: all pins high.
//
// Assumes the firmware/PIC32 has configured the AD9889B for 24-bit RGB with separate syncs, as it
// is for the SPC player. Pixel clock out (M22) is the inverted board clock, so the transmitter's
// rising edge falls mid-way through each registered data bit.
module top (
    input  wire       clk,      // W16, 74.25 MHz
    output wire       pclk,     // M22
    output reg        s0,       // P16
    output reg        s1,       // M16
    output reg        s2,       // M18
    output reg  [7:0] ch1,      // N19 N16 P18 P19 R21 R22 P22 N20 (bit 7..0)
    output reg  [7:0] ch2,      // T22 R15 T18 T17 L22 M20 K22 K21
    output reg  [7:0] ch3       // R17 P17 N21 M21 R16 T19 T15 T20
);
    // CEA-861 1280x720p60 (VIC 4): 1650 x 750 total, positive syncs.
    localparam H_ACT = 1280, H_FP = 110, H_SYNC = 40, H_TOT = 1650;
    localparam V_ACT = 720,  V_FP = 5,   V_SYNC = 5,  V_TOT = 750;

    assign pclk = ~clk;

    reg [10:0] x = 0;
    reg [9:0]  y = 0;
    reg [8:0]  frames = 0;      // 480 frames = 8 s per sync assignment
    reg [2:0]  perm = 0;

    always @(posedge clk) begin
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

    wire hs = (x >= H_ACT + H_FP) && (x < H_ACT + H_FP + H_SYNC);
    wire vs = (y >= V_ACT + V_FP) && (y < V_ACT + V_FP + V_SYNC);
    wire de = (x < H_ACT) && (y < V_ACT);

    // Pattern state is kept in counters (no per-pixel division) so it meets timing at 74.25 MHz.
    // Top band: perm+1 white boxes, 100 px wide on a 160 px pitch, from x = 40.
    reg [7:0]  bpos = 0;            // position within the 160 px pitch
    reg [3:0]  box = 0;
    always @(posedge clk) begin
        if (x == 39 || x == H_TOT - 1) begin
            bpos <= 0;
            box  <= 0;
        end else if (bpos == 159) begin
            bpos <= 0;
            box  <= box + 4'd1;
        end else
            bpos <= bpos + 8'd1;
    end
    wire in_band = (y >= 20) && (y < 100);
    wire in_box  = in_band && (x >= 40) && (bpos < 100) && (box <= perm);

    // Stripes: 24 x 25 px from y = 120; stripe k lights pin k only (x < 1024). x >= 1088: white.
    reg [4:0]  stripe = 0, sline = 0;
    reg [23:0] one = 0;
    always @(posedge clk)
        if (x == H_TOT - 1) begin
            if (y == 119) begin
                stripe <= 0; sline <= 0; one <= 24'h800000;
            end else if (sline == 24) begin
                sline <= 0;
                stripe <= stripe + 5'd1;
                one <= one >> 1;
            end else
                sline <= sline + 5'd1;
        end
    wire in_strip = (y >= 120) && (stripe < 24);
    wire [23:0] pix = in_box                ? 24'hffffff :
                      in_strip && x < 1024  ? one :
                      x >= 1088             ? 24'hffffff : 24'h000000;

    always @(posedge clk) begin
        {ch1, ch2, ch3} <= de ? pix : 24'h000000;
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
