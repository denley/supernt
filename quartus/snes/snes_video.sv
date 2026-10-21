// SPDX-License-Identifier: GPL-3.0-or-later
// SNES picture -> 1280x720p60 (CEA-861 VIC 4 timing) for the AD9889B, through a 16-line ring
// buffer in M10K. Strategy and numbers: notes/snes-quartus.md, "Video".
//
// Capture (clk_sys): the PPU outputs one colour per half dot (DOTCLK = 1: sub screen = left
// hi-res pixel, DOTCLK = 0: main screen = right pixel / the normal pixel). Every line is stored
// 512 columns wide: hi-res lines as they come, normal lines with each pixel written twice.
// Colours are kept as 6:6:6 (one 512x20 M10K per line).
//
// Output (clk_vid = 74.25 MHz): 3x line repetition (224 lines -> 672, centred; 239 -> 717),
// horizontal nearest-neighbour from 512 columns to OUT_W pixels (default 768 = 3x a 256-pixel
// line, 1.5x a hi-res one), centred. Pixels outside the picture are black.
//
// Frame lock: clk_sys (snes_pll.v, 21.44196 MHz) makes an NTSC SNES frame exactly as long as a
// standard 1650 x 750 frame at 74.25 MHz (60.000 Hz), so every output frame has the standard
// totals.
// (Varying the line count to stay locked - 748/749-line frames - made a projector drop the
// signal.) Once per SNES frame the capture side sends an event at a fixed point (VDE rise in
// 239-line mode, ~8.2 SNES lines earlier in 224-line mode). If it arrives outside lines
// LOCK_LINE-1 +- LOCK_WIN, the output's line counter jumps to LOCK_LINE (in the vertical back
// porch) at the end of that line: once at startup, and again only after a mode change or if
// the fractional-PLL rounding ever drifts the two apart by more than LOCK_WIN lines. Aligned,
// the output starts reading each SNES line 2.3-3.7 output lines after it was completely written
// (+- LOCK_WIN); the writer stays less than 16 lines ahead, so the ring never overflows
// (checked in simulation, sim/tb_snes.cpp). LOCK = 0 never jumps.
module snes_video #(
    parameter OUT_W     = 768,     // picture width in output pixels (>= 512; 896 = 4:3)
    parameter LOCK      = 1,       // 1: align output frames to the SNES (jumps, see above)
    parameter LOCK_LINE = 746,     // output line to jump to on the SNES frame event
    parameter LOCK_WIN  = 1,       // lines of drift tolerated before re-aligning
    parameter SYNC_ORDER = -1      // -1: cycle the 6 HS/VS/DE pin orders every 8 s; 0-5: fixed
) (
    // capture side, clk_sys
    input  wire        clk_sys,
    input  wire [7:0]  r, g, b,
    input  wire        dotclk, hde, vde, high_res, v224,

    // output side
    input  wire        clk_vid,
    output reg  [7:0]  vr, vg, vb,     // colour, registered
    output reg         s0, s1, s2,     // HS/VS/DE in the order selected by `perm`
    output reg  [2:0]  perm = 3'd0     // current sync order (0-5, table below)
);
    // ------------------------------------------------------------------ capture (clk_sys)
    reg        dc_d = 1'b0;
    reg        hde_d /* verilator public_flat_rd */ = 1'b0;
    reg        vde_d /* verilator public_flat_rd */ = 1'b0;
    reg        main_2nd = 1'b0;          // second cycle of a main (DOTCLK = 0) phase
    reg  [7:0] k = 8'd0;                 // dot within the line
    reg  [3:0] wslot /* verilator public_flat_rd */ = 4'd0;  // ring slot of the line being written
    reg  [8:0] sl = 9'd0, plen = 9'd262; // lines since VDE rise / lines in the previous frame
    reg        ev_tog = 1'b0;            // frame event, toggled
    reg        lb_we = 1'b0;
    reg [12:0] lb_wa = 13'd0;
    reg [17:0] lb_wd = 18'd0;

    wire [17:0] rgb666 = {r[7:2], g[7:2], b[7:2]};
    wire        sub_start  = dotclk & ~dc_d;
    wire        main_start = ~dotclk & dc_d;
    wire        hde_fall   = hde_d & ~hde;
    wire        vde_rise   = vde & ~vde_d;
    wire [8:0]  ev_lead    = v224 ? 9'd8 : 9'd0;   // event at ~8.2 SNES lines before VDE rise

    always @(posedge clk_sys) begin
        dc_d     <= dotclk;
        hde_d    <= hde;
        vde_d    <= vde;
        main_2nd <= main_start;
        lb_we    <= 1'b0;

        if (hde && vde) begin
            if (sub_start && high_res) begin
                lb_we <= 1'b1; lb_wa <= {wslot, k, 1'b0}; lb_wd <= rgb666;
            end
            if (main_start) begin
                lb_we <= 1'b1; lb_wa <= {wslot, k, high_res}; lb_wd <= rgb666;
            end
            if (main_2nd) begin
                if (!high_res) begin
                    lb_we <= 1'b1; lb_wa <= {wslot, k, 1'b1};
                end
                k <= k + 8'd1;
            end
        end

        if (hde_fall) begin
            k  <= 8'd0;
            sl <= sl + 9'd1;
            if (vde) wslot <= wslot + 4'd1;
            if (ev_lead != 0 && sl + 9'd1 == plen - ev_lead) ev_tog <= ~ev_tog;
        end
        if (vde_rise) begin
            wslot <= 4'd0;
            sl    <= 9'd0;
            plen  <= sl;
            if (ev_lead == 0) ev_tog <= ~ev_tog;
        end
    end

    // ------------------------------------------------------------------ line buffer
    (* ramstyle = "M10K", max_depth = 512 *) reg [17:0] lb [0:8191];
    reg [17:0] lb_q;
    reg [12:0] lb_ra;
    always @(posedge clk_sys)
        if (lb_we) lb[lb_wa] <= lb_wd;
    always @(posedge clk_vid)
        lb_q <= lb[lb_ra];

    // ------------------------------------------------------------------ output (clk_vid)
    localparam H_ACT = 1280, H_FP = 110, H_SYNC = 40, H_TOT = 1650;
    localparam V_ACT = 720,  V_FP = 5,   V_SYNC = 5,  V_TOT = 750;
    localparam X0 = (H_ACT - OUT_W) / 2;

    // Clock-domain crossing: the frame event toggle and the (quasi-static) 224/239 mode.
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg [2:0] ev_sync = 3'd0;
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg [1:0] m_sync = 2'b11;
    always @(posedge clk_vid) begin
        ev_sync <= {ev_sync[1:0], ev_tog};
        m_sync  <= {m_sync[0], v224};
    end
    wire ev_vid = ev_sync[2] ^ ev_sync[1];

    reg [10:0] hx /* verilator public_flat_rd */ = 11'd0;
    reg [9:0]  vy /* verilator public_flat_rd */ = 10'd0;
    reg        lock_req = 1'b0;
    reg [8:0]  frames = 9'd0;
    reg [9:0]  top = 10'd24;               // first picture line
    reg [8:0]  nlines = 9'd224;
    reg [7:0]  sy /* verilator public_flat_rd */ = 8'd0;    // SNES line shown on this output line
    reg [1:0]  rep = 2'd0;                 // 0-2: repetition of that line
    reg        vpic /* verilator public_flat_rd */ = 1'b0;  // this output line shows picture
    reg [8:0]  col = 9'd0;                 // source column (0-511)
    reg [10:0] acc = 11'd0;                // horizontal phase accumulator

    wire line_end = (hx == H_TOT - 1);
    wire in_win = (vy >= LOCK_LINE - 1 - LOCK_WIN) && (vy <= LOCK_LINE - 1 + LOCK_WIN);
    wire ev_out = ev_vid && !in_win;                      // event outside the window
    wire jump = LOCK && (lock_req || ev_out);             // at line_end: go to LOCK_LINE
    wire [9:0] vy_next = jump ? LOCK_LINE[9:0] : (vy == V_TOT - 1) ? 10'd0 : vy + 10'd1;
    always @(posedge clk_vid) begin
        hx <= line_end ? 11'd0 : hx + 11'd1;
        if (line_end) begin
            vy <= vy_next;
            lock_req <= 1'b0;
        end else if (ev_out && LOCK)
            lock_req <= 1'b1;

        // Per-frame state, updated at the start of the vertical blank.
        if (line_end && vy == V_ACT - 1) begin
            top     <= m_sync[1] ? 10'd24 : 10'd1;
            nlines  <= m_sync[1] ? 9'd224 : 9'd239;
            if (frames == 9'd479) begin
                frames <= 9'd0;
                perm   <= (perm == 3'd5) ? 3'd0 : perm + 3'd1;
            end else
                frames <= frames + 9'd1;
        end

        // Source line for the next output line (computed at the end of the current one).
        if (line_end) begin
            if (vy_next == top) begin
                sy <= 8'd0; rep <= 2'd0; vpic <= 1'b1;
            end else if (vpic) begin
                if (rep == 2'd2) begin
                    rep <= 2'd0;
                    sy  <= sy + 8'd1;
                    if (sy + 9'd1 == nlines) vpic <= 1'b0;
                end else
                    rep <= rep + 2'd1;
            end
            if (vy_next >= V_ACT) vpic <= 1'b0;
        end

        // Horizontal source column: 512 columns over OUT_W pixels.
        if (hx == X0 - 1) begin
            col <= 9'd0; acc <= 11'd0;
        end else if (acc + 11'd512 >= OUT_W) begin
            acc <= acc + 11'd512 - OUT_W[10:0];
            col <= col + 9'd1;
        end else
            acc <= acc + 11'd512;
        lb_ra <= {sy[3:0], col};
    end

    // Pipeline: hx/vy (cycle 0) -> lb_ra (1) -> lb_q (2) -> outputs (3).
    wire hs = (hx >= H_ACT + H_FP) && (hx < H_ACT + H_FP + H_SYNC);
    wire vs = (vy >= V_ACT + V_FP) && (vy < V_ACT + V_FP + V_SYNC);
    wire de = (hx < H_ACT) && (vy < V_ACT);
    wire inpic = vpic && (hx >= X0) && (hx < X0 + OUT_W);
    // Sync-order indicator: perm+1 small white boxes in the top border (only outside the
    // picture), so a photo tells which order works.
    wire [2:0] order = (SYNC_ORDER >= 0) ? SYNC_ORDER[2:0] : perm;
    wire [10:0] bx = hx - 11'd16;
    wire box = !vpic && vy >= 4 && vy < 16 && hx >= 16 && bx[4:0] < 5'd20 && bx[10:5] <= order;
    reg  [1:0] hs_p, vs_p, de_p, pic_p, box_p;
    always @(posedge clk_vid) begin
        hs_p  <= {hs_p[0], hs};
        vs_p  <= {vs_p[0], vs};
        de_p  <= {de_p[0], de};
        pic_p <= {pic_p[0], inpic};
        box_p <= {box_p[0], box};
    end
    wire h = hs_p[1], v = vs_p[1], d = de_p[1];
    always @(posedge clk_vid) begin
        if (d && pic_p[1]) begin
            vr <= {lb_q[17:12], lb_q[17:16]};
            vg <= {lb_q[11:6],  lb_q[11:10]};
            vb <= {lb_q[5:0],   lb_q[5:4]};
        end else if (d && box_p[1])
            {vr, vg, vb} <= 24'hffffff;
        else
            {vr, vg, vb} <= 24'h000000;
        case (order)    // {s0, s1, s2} = {P16, M16, M18}, same table as hw/vtest/vtest.v
            3'd0: {s0, s1, s2} <= {h, v, d};
            3'd1: {s0, s1, s2} <= {h, d, v};
            3'd2: {s0, s1, s2} <= {v, h, d};
            3'd3: {s0, s1, s2} <= {v, d, h};
            3'd4: {s0, s1, s2} <= {d, h, v};
            default: {s0, s1, s2} <= {d, v, h};
        endcase
    end
endmodule
