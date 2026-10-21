// PIC32-link bus logger. Replaces spc.cor; when the user "plays" an .spc file the PIC32 talks to
// it as it would to the SPC player, and this core records what it does and shows it on screen.
//
// Every pin it touches is an input (notes/spc-core.md, bank 4A): the 8 data pins, the 4 strobe
// inputs, and 4 other unexplained inputs (shown live only). It never drives the bus, so PIC32
// reads see a floating bus and the PIC32 will probably give up or retry - the first transactions
// are what we want.
//
// Event = any change of the 4 synchronised strobe inputs. Stored: strobes, data byte, time since
// the previous event (units of 64 clocks = 0.86 us, saturating at ff). The first 1024 events are
// kept. Screen (16x16 px characters, 80x45):
//   row 0: P C CCC  S DD X   (P = sync-pin order 0-5, CCC = events stored, S/DD/X = live strobes,
//          data, other inputs)
//   rows 2-43: 10 events per row, "S:DD+TT". The page (events 0-419, 420-839, 840-1023) advances
//          after every full cycle of sync orders, or every 16 s when SYNC_PERM is fixed.
// Bit order: S = {AB20, AA20, AA19, U21}; DD = {AB21 AA22 AB22 W22 Y22 W21 Y21 V21} (bit 7..0);
// X = {T12, U22, H11, G12}.
module top (
    input  wire       clk,      // W16, 74.25 MHz
    output wire       pclk,     // M22
    output reg        s0,       // P16
    output reg        s1,       // M16
    output reg        s2,       // M18
    output reg  [7:0] ch1,
    output reg  [7:0] ch2,
    output reg  [7:0] ch3,
    input  wire [3:0] strobe,
    input  wire [7:0] data,
    input  wire [3:0] xin
);
    parameter integer SYNC_PERM = -1;   // -1: cycle all 6 orders (8 s each); 0-5: fixed

    localparam H_ACT = 1280, H_FP = 110, H_SYNC = 40, H_TOT = 1650;
    localparam V_ACT = 720,  V_FP = 5,   V_SYNC = 5,  V_TOT = 750;

    assign pclk = ~clk;

    // ---------------------------------------------------------------- capture
    reg [15:0] sync1 = 0, sync2 = 0;
    always @(posedge clk) begin
        sync1 <= {xin, strobe, data};
        sync2 <= sync1;
    end
    wire [7:0] d_now = sync2[7:0];
    wire [3:0] s_now = sync2[11:8];
    wire [3:0] x_now = sync2[15:12];

    reg [3:0]  s_prev = 0;
    reg [2:0]  arm = 0;                 // let the synchronisers fill before recording
    wire       armed = arm[2];
    reg [13:0] since = 0;               // clocks since last event, /64 -> 8 bits
    reg [10:0] count = 0;
    reg [19:0] mem [0:1023];
    wire       event_now = armed && (s_now != s_prev) && !count[10];
    wire [7:0] delta = since[13:6] == 8'hff || since[13] ? 8'hff : since[13:6];

    always @(posedge clk) begin
        s_prev <= s_now;
        if (!armed) arm <= arm + 3'd1;
        if (event_now) begin
            mem[count[9:0]] <= {s_now, d_now, delta};
            count <= count + 11'd1;
            since <= 0;
        end else if (since != 14'h3fff)
            since <= since + 14'd1;
    end

    // ---------------------------------------------------------------- timing
    reg [10:0] x = 0;
    reg [9:0]  y = 0;
    reg [9:0]  frames = 0;
    reg [2:0]  perm = (SYNC_PERM < 0) ? 3'd0 : SYNC_PERM[2:0];
    reg [1:0]  page = 0;

    always @(posedge clk) begin
        if (x == H_TOT - 1) begin
            x <= 0;
            if (y == V_TOT - 1) begin
                y <= 0;
                if (SYNC_PERM < 0) begin
                    if (frames == 479) begin
                        frames <= 0;
                        if (perm == 5) begin
                            perm <= 0;
                            page <= (page == 2) ? 2'd0 : page + 2'd1;
                        end else
                            perm <= perm + 3'd1;
                    end else
                        frames <= frames + 10'd1;
                end else if (frames == 959) begin
                    frames <= 0;
                    page <= (page == 2) ? 2'd0 : page + 2'd1;
                end else
                    frames <= frames + 10'd1;
            end else
                y <= y + 10'd1;
        end else
            x <= x + 11'd1;
    end

    // ---------------------------------------------------------------- text, 3-stage pipeline
    // Stage 1: character cell and the RAM address.
    reg [6:0]  col1;
    reg [5:0]  row1;
    reg [2:0]  gx1, gy1;
    reg        de1, hs1, vs1;
    reg [9:0]  raddr;
    reg        show1;
    wire [10:0] idx0 = (({5'd0, y[9:4]} - 11'd2) * 11'd10) + {7'd0, x[10:7]} + page * 11'd420;
    always @(posedge clk) begin
        col1 <= x[10:4];
        row1 <= y[9:4];
        gx1  <= x[3:1];
        gy1  <= y[3:1];
        de1  <= (x < H_ACT) && (y < V_ACT);
        hs1  <= (x >= H_ACT + H_FP) && (x < H_ACT + H_FP + H_SYNC);
        vs1  <= (y >= V_ACT + V_FP) && (y < V_ACT + V_FP + V_SYNC);
        raddr <= idx0[9:0];
        show1 <= (y[9:4] >= 2) && (y[9:4] < 44) && (idx0 < count);
    end

    // Stage 2: RAM data, pick the glyph.
    reg [19:0] ev2;
    reg [6:0]  col2;
    reg [5:0]  row2;
    reg [2:0]  gx2, gy2;
    reg        de2, hs2, vs2, show2;
    always @(posedge clk) begin
        ev2  <= mem[raddr];
        show2 <= show1;
        col2 <= col1; row2 <= row1; gx2 <= gx1; gy2 <= gy1;
        de2  <= de1;  hs2  <= hs1;  vs2  <= vs1;
    end

    localparam G_COLON = 5'd16, G_PLUS = 5'd17, G_SPACE = 5'd18;
    reg [4:0] glyph;
    always @* begin
        glyph = G_SPACE;
        if (row2 == 0) begin
            case (col2)
                0:  glyph = {2'b0, perm};
                2:  glyph = {4'b0, count[10]};
                3:  glyph = {1'b0, count[9:8] == 0 ? 4'd0 : {2'b0, count[9:8]}};
                4:  glyph = {1'b0, count[7:4]};
                5:  glyph = {1'b0, count[3:0]};
                7:  glyph = {1'b0, s_now};
                9:  glyph = {1'b0, d_now[7:4]};
                10: glyph = {1'b0, d_now[3:0]};
                12: glyph = {1'b0, x_now};
                default: glyph = G_SPACE;
            endcase
        end else if (show2) begin
            case (col2[2:0])
                0: glyph = {1'b0, ev2[19:16]};
                1: glyph = G_COLON;
                2: glyph = {1'b0, ev2[15:12]};
                3: glyph = {1'b0, ev2[11:8]};
                4: glyph = G_PLUS;
                5: glyph = {1'b0, ev2[7:4]};
                6: glyph = {1'b0, ev2[3:0]};
                default: glyph = G_SPACE;
            endcase
        end
    end

    // 8x8 font: rows top to bottom, bit 7 = leftmost pixel.
    function [7:0] font(input [4:0] g, input [2:0] r);
        reg [63:0] f;
        begin
            case (g)
                0:  f = 64'h3c666e7666663c00;
                1:  f = 64'h1838181818187e00;
                2:  f = 64'h3c66060c18307e00;
                3:  f = 64'h3c66061c06663c00;
                4:  f = 64'h0c1c2c4c7e0c0c00;
                5:  f = 64'h7e607c0606663c00;
                6:  f = 64'h3c60607c66663c00;
                7:  f = 64'h7e06060c18181800;
                8:  f = 64'h3c66663c66663c00;
                9:  f = 64'h3c66663e06063c00;
                10: f = 64'h183c66667e666600;
                11: f = 64'h7c66667c66667c00;
                12: f = 64'h3c66606060663c00;
                13: f = 64'h786c6666666c7800;
                14: f = 64'h7e60607c60607e00;
                15: f = 64'h7e60607c60606000;
                16: f = 64'h0018180000181800;
                17: f = 64'h0018187e18180000;
                default: f = 64'h0;
            endcase
            font = f[63 - 8 * r -: 8];
        end
    endfunction

    // Stage 3: pixel out.
    wire [7:0] frow = font(glyph, gy2);
    wire on = frow[7 - gx2];
    always @(posedge clk) begin
        {ch1, ch2, ch3} <= (de2 && on) ? 24'hffffff : 24'h000000;
        case (perm)     // {s0, s1, s2} = {P16, M16, M18}, same order table as vtest
            3'd0: {s0, s1, s2} <= {hs2, vs2, de2};
            3'd1: {s0, s1, s2} <= {hs2, de2, vs2};
            3'd2: {s0, s1, s2} <= {vs2, hs2, de2};
            3'd3: {s0, s1, s2} <= {vs2, de2, hs2};
            3'd4: {s0, s1, s2} <= {de2, hs2, vs2};
            default: {s0, s1, s2} <= {de2, vs2, hs2};
        endcase
    end
endmodule
