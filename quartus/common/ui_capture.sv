// SPDX-License-Identifier: GPL-3.0-or-later
// Copies of what the PIC writes for the SPC player's UI (hwtest v5, notes/hardware-tests.md),
// so the test screen can show the player's own screen. Every data write (A=2) whose address is
// in one of these windows lands in a 32 KB capture space (byte address `ca`):
//   0x0000-0x0FFF  0x1018_0000-0FFF  the screen (4 KB; v4b: redrawn after button presses,
//                                    ASCII text, 128-byte rows)
//   0x1000-0x2FFF  0x1006_0000-1FFF  8 KB written once after the poll (font / tiles?)
//   0x3000-0x33FF  0x1001_3000-33FF  0x300 bytes (palette?)
//   0x3400 111F_81xx, 0x3500 1010_00xx, 0x3600 1000_D1xx, 0x3700 1000_05xx, 0x3800 1000_90xx,
//   0x3900 1000_D2xx, 0x3A00 1000_00xx, 0x3B00 1000_80xx, 0x3C00 1000_C2xx, 0x3D00 1000_F0xx,
//   0x3E00 1000_D0xx (256 bytes each: the last value written to each register)
//   0x4000-0x7FFF  0x1017_0000-3FFF  (0x2500 bytes at 0x1017_0800 before the poll)
// Three copies: A (the screen, 16-bit words, for the map / text views), B (everything, 16-bit
// words, for glyphs, bit dumps and hex dumps) and C (everything, bytes, for the CRC scanner).
// Word w holds bytes 2w (bits 7:0) and 2w + 1 (bits 15:8); reads have one clock of latency.
//
// The scanner reads C round and round (3 clocks per byte, 1.3 ms per sweep) and keeps the
// CRC-32 (zlib) of each 4 KB block and of the regions the link log has CRCs for (font
// 0x1000-0x2FFF, palette 0x3000-0x32FF, 0x1017_0800 block 0x4800-0x6CFF). The screen is
// "settled" when a whole scan of block 0 saw no write and the last screen write is QUIET_US
// old; every settled CRC that differs from the previous one is a screen change, logged with
// its time and the virtual press current then (history, a ring of 64). The press table gets
// one entry per press when the next one starts: the press, its button and start time and the
// settled screen CRC just before the next press ("the screen after it").
module ui_capture #(
    parameter integer QUIET_US = 30000
) (
    input  wire        clk,
    input  wire [31:0] usec,
    input  wire        w_go,            // data write (link_logger)
    input  wire [31:0] w_addr,
    input  wire [7:0]  w_data,
    input  wire        press_go,        // vpress: a press starts (n_press, btn are the new one)
    input  wire [7:0]  n_press,
    input  wire [3:0]  btn,
    input  wire [10:0] a_addr,          // copy A: screen word address
    output reg  [15:0] a_q,
    input  wire [13:0] b_addr,          // copy B: capture word address
    output reg  [15:0] b_q,
    output reg  [255:0] crc_blk = 256'd0, // CRC of 4 KB block k at [32k +: 32]
    output reg  [31:0] crc_font = 32'd0,
    output reg  [31:0] crc_pal = 32'd0,
    output reg  [31:0] crc_x17 = 32'd0,
    output reg  [31:0] scr_crc = 32'd0, // settled screen CRC
    output reg  [31:0] n_scr_wr = 32'd0, // bytes written to the screen
    output reg  [31:0] scr_wr_t = 32'd0, // time of the last screen write
    output reg  [7:0]  n_upd = 8'd0,    // screen changes logged
    output reg  [31:0] upd_t = 32'd0,   // time of the last one
    input  wire [5:0]  h_idx,           // history entry (ring index)
    output reg  [63:0] h_q,             // {T[19:0], press #[7:0], button[3:0], CRC[31:0]}
    input  wire [5:0]  p_idx,           // press table entry (press p_idx + 1)
    output reg  [63:0] p_q,             // {press #[7:0], button[3:0], T[19:0], CRC after[31:0]}
    output reg  [7:0]  n_pt = 8'd0      // press table entries
);
    // ------------------------------------------------------------ address map
    function [15:0] cmap(input [31:0] ad);    // {hit, ca[14:0]}
        if (ad[31:12] == 20'h10180)       cmap = {1'b1, 15'h0000 + {3'd0, ad[11:0]}};
        else if (ad[31:13] == 19'h08030)  cmap = {1'b1, 15'h1000 + {2'd0, ad[12:0]}};  // 0x1006_0000-1FFF
        else if (ad[31:10] == 22'h04004C) cmap = {1'b1, 15'h3000 + {5'd0, ad[9:0]}};   // 0x1001_3000-33FF
        else if (ad[31:8] == 24'h111F81)  cmap = {1'b1, 15'h3400 + {7'd0, ad[7:0]}};
        else if (ad[31:8] == 24'h101000)  cmap = {1'b1, 15'h3500 + {7'd0, ad[7:0]}};
        else if (ad[31:8] == 24'h1000D1)  cmap = {1'b1, 15'h3600 + {7'd0, ad[7:0]}};
        else if (ad[31:8] == 24'h100005)  cmap = {1'b1, 15'h3700 + {7'd0, ad[7:0]}};
        else if (ad[31:8] == 24'h100090)  cmap = {1'b1, 15'h3800 + {7'd0, ad[7:0]}};
        else if (ad[31:8] == 24'h1000D2)  cmap = {1'b1, 15'h3900 + {7'd0, ad[7:0]}};
        else if (ad[31:8] == 24'h100000)  cmap = {1'b1, 15'h3A00 + {7'd0, ad[7:0]}};
        else if (ad[31:8] == 24'h100080)  cmap = {1'b1, 15'h3B00 + {7'd0, ad[7:0]}};
        else if (ad[31:8] == 24'h1000C2)  cmap = {1'b1, 15'h3C00 + {7'd0, ad[7:0]}};
        else if (ad[31:8] == 24'h1000F0)  cmap = {1'b1, 15'h3D00 + {7'd0, ad[7:0]}};
        else if (ad[31:8] == 24'h1000D0)  cmap = {1'b1, 15'h3E00 + {7'd0, ad[7:0]}};
        else if (ad[31:14] == 18'h0405C)  cmap = {1'b1, 15'h4000 + {1'd0, ad[13:0]}};  // 0x1017_0000-3FFF
        else                              cmap = 16'd0;
    endfunction

    // write pipeline: decode, then write all copies
    reg        we = 1'b0;
    reg [14:0] wa = 15'd0;
    reg [7:0]  wd = 8'd0;
    wire [15:0] m = cmap(w_addr);
    always @(posedge clk) begin
        we <= w_go && m[15];
        wa <= m[14:0];
        wd <= w_data;
    end

    (* ramstyle = "M10K, no_rw_check" *) reg [7:0] a_lo [0:2047];
    (* ramstyle = "M10K, no_rw_check" *) reg [7:0] a_hi [0:2047];
    (* ramstyle = "M10K, no_rw_check" *) reg [7:0] b_lo [0:16383];
    (* ramstyle = "M10K, no_rw_check" *) reg [7:0] b_hi [0:16383];
    (* ramstyle = "M10K, no_rw_check" *) reg [7:0] c_m  [0:32767];
    // the two small tables in MLABs: in M10Ks their write data paths missed hold in the fast
    // corner (register next to the M10K, 0.4 ns of clock skew)
    (* ramstyle = "MLAB" *) reg [63:0] hist [0:63];
    (* ramstyle = "MLAB" *) reg [63:0] ptab [0:63];
    // M10K blocks are zero after configuration; the same for simulation (Quartus stops loops
    // at 5000 iterations, and needs nothing here)
    // synthesis translate_off
    integer ii;
    initial begin
        for (ii = 0; ii < 2048; ii = ii + 1) begin a_lo[ii] = 8'd0; a_hi[ii] = 8'd0; end
        for (ii = 0; ii < 16384; ii = ii + 1) begin b_lo[ii] = 8'd0; b_hi[ii] = 8'd0; end
        for (ii = 0; ii < 32768; ii = ii + 1) c_m[ii] = 8'd0;
        for (ii = 0; ii < 64; ii = ii + 1) begin hist[ii] = 64'd0; ptab[ii] = 64'd0; end
    end
    // synthesis translate_on
    always @(posedge clk) begin
        if (we && wa[14:12] == 3'd0 && !wa[0]) a_lo[wa[11:1]] <= wd;
        if (we && wa[14:12] == 3'd0 &&  wa[0]) a_hi[wa[11:1]] <= wd;
        a_q <= {a_hi[a_addr], a_lo[a_addr]};
    end
    always @(posedge clk) begin
        if (we && !wa[0]) b_lo[wa[14:1]] <= wd;
        if (we &&  wa[0]) b_hi[wa[14:1]] <= wd;
        b_q <= {b_hi[b_addr], b_lo[b_addr]};
    end
    reg [14:0] sa = 15'd0;              // scanner address
    reg [7:0]  cq;
    always @(posedge clk) begin
        if (we) c_m[wa] <= wd;
        cq <= c_m[sa];
    end

    // ------------------------------------------------------------ CRC scanner
    function [31:0] crc4(input [31:0] c, input [3:0] n);   // reflected CRC-32, low nibble first
        integer i;
        reg [31:0] r;
        begin
            r = c ^ {28'd0, n};
            for (i = 0; i < 4; i = i + 1)
                r = r[0] ? (r >> 1) ^ 32'hEDB88320 : r >> 1;
            crc4 = r;
        end
    endfunction

    reg [1:0]  ph = 2'd0;
    reg [31:0] ca_crc = 32'hFFFFFFFF;   // per 4 KB block
    reg [31:0] cr_crc = 32'hFFFFFFFF;   // per region
    reg        wr0 = 1'b0;              // a screen write since block 0's scan began
    reg [31:0] h_crc = 32'd0;           // newest history CRC
    wire [31:0] na = crc4(sa[11:0] == 12'd0 ? 32'hFFFFFFFF : ca_crc, cq[3:0]);
    wire        rstart = sa == 15'h1000 || sa == 15'h3000 || sa == 15'h4800;
    wire [31:0] nr = crc4(rstart ? 32'hFFFFFFFF : cr_crc, cq[3:0]);
    wire [31:0] fa = crc4(ca_crc, cq[7:4]);
    wire [31:0] fr = crc4(cr_crc, cq[7:4]);
    wire        quiet = usec - scr_wr_t >= QUIET_US;

    reg        h_we = 1'b0;
    reg [63:0] h_wd;
    reg [7:0]  np_prev = 8'd0;
    reg [3:0]  btn_prev = 4'd0;
    reg [19:0] t_prev = 20'd0;
    reg        p_we = 1'b0;
    reg [63:0] p_wd;
    reg [5:0]  p_wa;

    always @(posedge clk) begin
        h_we <= 1'b0;
        p_we <= 1'b0;
        if (we && wa[14:12] == 3'd0) begin
            n_scr_wr <= n_scr_wr + 32'd1;
            scr_wr_t <= usec;
            wr0 <= 1'b1;
        end
        case (ph)
            2'd0: ph <= 2'd1;                       // cq <= mem[sa]
            2'd1: begin
                    ca_crc <= na;
                    cr_crc <= nr;
                    ph <= 2'd2;
                    if (sa == 15'd0 && !(we && wa[14:12] == 3'd0)) wr0 <= 1'b0;
                end
            default: begin
                    ca_crc <= fa;
                    cr_crc <= fr;
                    ph <= 2'd0;
                    sa <= sa + 15'd1;
                    if (sa[11:0] == 12'hFFF) begin
                        crc_blk[{sa[14:12], 5'd0} +: 32] <= ~fa;
                        if (sa[14:12] == 3'd0 && !wr0 && quiet && n_scr_wr != 0) begin
                            scr_crc <= ~fa;
                            if (n_upd == 8'd0 || ~fa != h_crc) begin
                                h_crc <= ~fa;
                                h_we <= 1'b1;
                                h_wd <= {usec[29:10], n_press, btn, ~fa};
                                upd_t <= usec;
                            end
                        end
                    end
                    if (sa == 15'h2FFF) crc_font <= ~fr;
                    if (sa == 15'h32FF) crc_pal <= ~fr;
                    if (sa == 15'h6CFF) crc_x17 <= ~fr;
                end
        endcase
        if (h_we) n_upd <= n_upd + 8'd1;
        // press table: the previous press, with the screen it left
        if (press_go) begin
            np_prev <= n_press;
            btn_prev <= btn;
            t_prev <= usec[29:10];
            if (np_prev != 8'd0) begin
                p_we <= 1'b1;
                p_wa <= np_prev[5:0] - 6'd1;
                p_wd <= {np_prev, btn_prev, t_prev, scr_crc};
            end
        end
        if (p_we) n_pt <= n_pt + 8'd1;
    end
    always @(posedge clk) begin
        if (h_we) hist[n_upd[5:0]] <= h_wd;
        h_q <= hist[h_idx];
    end
    always @(posedge clk) begin
        if (p_we) ptab[p_wa] <= p_wd;
        p_q <= ptab[p_idx];
    end
endmodule
