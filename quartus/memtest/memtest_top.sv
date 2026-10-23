// SPDX-License-Identifier: GPL-3.0-or-later
// Super Nt memory test core (memtest v3): tests all three SDRAM chips with the pin map of
// notes/sdram.md ("Which chip is which", "Controller 2", "memtest v2 result"), results on two
// text pages (screen.txt; 8 s each).
//   U4      - AS4C8M16SA x16 on the bottom-bank bus: sdram_test.sv at spc.cor's levels, errors
//             per byte: A = 2A (never answered so far), B = 3B (works)
//   U5/U16  - mem2_test.sv: G1 (works with J8 low, data at r3 in v2) and G2 (drives with B13
//             low, own address pins): errors at f2.5-r5, column walk, raw bytes, and the probe
//             for G2's address pins (page 2)
// v3 keeps every candidate pin at spc.cor's level (top-bank constants low, D9/E10 high,
// C13/C15 low; J8 and B13 among them) and shows the last four passes; the probe releases one
// probed pin at a time (A14 B5 G16 H13 A13 A15 B15 C11 E14 E15 E16 F13 F15 G15 G17 G18 A5 B16
// J17 C13 C15; D17 inside mem2_test).
// Pin rules (notes/STATUS.md): every pin here is one spc.cor drives, used as it does; group 2's
// data, C13/C15 and the candidates are only ever low or released, D9/E10 high; the constants at
// 4 mA, like hwtest's.
module top #(
    parameter SCREEN_HEX = "../../build/memtest/screen.hex",
    parameter FONT_HEX   = "../../build/hwtest/font.hex",
    parameter [11:0] SD_ROWS   = 12'd4095, // rows per bank (simulation: fewer)
    parameter [15:0] INIT_NOP  = 16'd20000,
    parameter [17:0] SETTLE    = 18'h3FFFF, // clocks between a pin change and the next pass
    parameter integer PAGE_FRAMES = 480
) (
    input  wire       clk,      // W16, 74.25 MHz
    // video (AD9889B)
    output wire       pclk,     // M22
    output reg        s0,       // P16 VSYNC
    output reg        s1,       // M16 DE
    output reg        s2,       // M18 HSYNC
    output reg  [7:0] ch1, ch2, ch3,
    // U4
    output wire       sd_clk,   // AB11
    output wire       sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n,
    output wire [11:0] sd_a,
    output wire [1:0] sd_ba,
    inout  wire [15:0] sd_dq,   // 7:0 byte A (2A), 15:8 byte B (3B)
    output wire       sd_cke,   // AB10: DQM of byte B, low
    output wire [18:0] tie3,    // spc.cor's constant pins, at their level
    output wire [22:0] tie_hold, // 4A constants, K19, K20 (J17 moved to cand)
    // top-bank constants: cand = A14 B5 G16 H13 A13 A15 B15 C11 E14 E15 E16 F13 F15 G15 G17
    // G18 A5 B13 B16 J17 J8 (0 in spc.cor), hi_pins = D9 E10 (1)
    inout  wire [20:0] cand,
    inout  wire [1:0] hi_pins,
    // U5/U16
    output wire       m_clk,    // H8
    output wire [9:0] m_a,      // N6 P6 P7 R7 P8 R9 H6 F7 D7 C8
    output wire       m_a11,    // M6
    output wire [1:0] m_ba,     // E9 C9
    output wire       g1_cs_n, g1_ras_n, g1_cas_n, g1_we_n, g1_a10,  // D12 D13 G13 E12 H9
    output wire       g2_cs_n, g2_ras_n, g2_cas_n, g2_we_n, g2_a10,  // B6 C6 A7 B7 D17
    inout  wire [7:0] g1_dq,    // N8 J7 J9 K7 H11 G12 F12 J11
    inout  wire [7:0] g2_dq,    // A8 A9 A10 A12 B10 B11 B12 C16 (low or released)
    inout  wire       m_c13,    // C13 (low or released)
    inout  wire       m_c15     // C15
);
    localparam [18:0] TIE3_LEVEL = 19'b111_0000000000000000;
    localparam [22:0] HOLD_LEVEL = 23'b00_11111111_0000000000000;
    assign tie3 = TIE3_LEVEL;
    assign tie_hold = HOLD_LEVEL;
    genvar gi;

    // ---------------------------------------------------------------- pins, pass history
    localparam integer NC = 21;
    reg  [1:0]  h = 2'd0;               // history slot of the pass running now
    reg  [15:0] round = 16'd0;
    reg  [17:0] settle = 18'd0;
    reg         running = 1'b0, start = 1'b0, u4_got = 1'b0, m2_got = 1'b0;
    wire [4:0]  pr_sel;
    wire        pr_hi;
    // probe index -> candidate (17 = B13 and 20 = J8 are never probed), 19/20 = C13/C15
    function [4:0] pmap(input [4:0] p);
        pmap = p < 5'd17 ? p : p == 5'd17 ? 5'd18 : p == 5'd18 ? 5'd19 : 5'd31;
    endfunction
    wire [4:0]  pc_idx = pmap(pr_sel);
    assign m_c13 = pr_hi && pr_sel == 5'd19 ? 1'bz : 1'b0;
    assign m_c15 = pr_hi && pr_sel == 5'd20 ? 1'bz : 1'b0;
    assign hi_pins = 2'b11;
    generate for (gi = 0; gi < NC; gi = gi + 1) begin : g_cand
        assign cand[gi] = pr_hi && pc_idx == gi ? 1'bz : 1'b0;
    end endgenerate

    // ---------------------------------------------------------------- U4
    wire [15:0]  sdq_out;
    wire         sdq_oe, u4_done;
    wire [15:0]  u4_passes;
    wire [191:0] u4_err;
    assign sd_dq = sdq_oe ? sdq_out : 16'hzzzz;
    sdram_test #(.ROWS(SD_ROWS), .INIT_NOP(INIT_NOP), .FIXED_STOCK(1)) u4 (
        .clk(clk), .start(start), .sd_clk(sd_clk), .sd_cs_n(sd_cs_n), .sd_ras_n(sd_ras_n),
        .sd_cas_n(sd_cas_n), .sd_we_n(sd_we_n), .sd_a(sd_a), .sd_ba(sd_ba), .sd_dq_in(sd_dq),
        .sd_dq_out(sdq_out), .sd_dq_oe(sdq_oe), .ab10(sd_cke), .od_low(), .tie_rel(),
        .passes(u4_passes), .hyp(), .hsel(4'd0), .err_row(), .raw_row(), .pass_done(u4_done),
        .last_err(u4_err));

    // ---------------------------------------------------------------- U5/U16
    wire [7:0]   g1_out, g2_low;
    wire         g1_oe, m2_done, m2_busy;
    wire [15:0]  m2_passes;
    wire [299:0] m2_err;
    wire [131:0] m2_cw;
    wire [127:0] m2_raw;
    wire [703:0] m2_probe;
    assign g1_dq = g1_oe ? g1_out : 8'hzz;
    generate for (gi = 0; gi < 8; gi = gi + 1) begin : g_od
        assign g2_dq[gi] = g2_low[gi] ? 1'b0 : 1'bz;
    end endgenerate
    mem2_test #(.ROWS(SD_ROWS), .INIT_NOP(INIT_NOP)) m2 (
        .clk(clk), .start(start), .sd_clk(m_clk),
        .g1_cmd({g1_cs_n, g1_ras_n, g1_cas_n, g1_we_n}), .g1_a10(g1_a10),
        .g2_cmd({g2_cs_n, g2_ras_n, g2_cas_n, g2_we_n}), .g2_a10(g2_a10),
        .sd_a(m_a), .sd_a11(m_a11), .sd_ba(m_ba), .g1_dq_in(g1_dq), .g1_dq_out(g1_out),
        .g1_dq_oe(g1_oe), .g2_dq_in(g2_dq), .g2_low(g2_low), .busy(m2_busy), .done(m2_done),
        .pr_sel(pr_sel), .pr_hi(pr_hi), .passes(m2_passes), .last_err(m2_err),
        .last_cw(m2_cw), .last_raw(m2_raw), .last_probe(m2_probe));

    // results of the last four passes (slot h = pass number mod 4), probe of the newest
    reg [191:0] r_u4  [0:3];
    reg [299:0] r_m2  [0:3];
    reg [131:0] r_cw  = 0;
    reg [127:0] r_raw = 0;
    reg [703:0] r_pr  = 0;
    reg [15:0]  r_pn  [0:3];
    reg [1:0]   newest = 2'd0;
    integer k;
    initial for (k = 0; k < 4; k = k + 1) begin r_u4[k] = 0; r_m2[k] = 0; r_pn[k] = 0; end
    // wait SETTLE, start both tests, wait for both, store, next
    always @(posedge clk) begin
        start <= 1'b0;
        if (!running) begin
            settle <= settle + 18'd1;
            if (settle == SETTLE) begin
                start <= 1'b1; running <= 1'b1; u4_got <= 1'b0; m2_got <= 1'b0;
            end
        end else begin
            if (u4_done) begin u4_got <= 1'b1; r_u4[h] <= u4_err; end
            if (m2_done) begin
                m2_got <= 1'b1; r_m2[h] <= m2_err; r_cw <= m2_cw; r_raw <= m2_raw; r_pr <= m2_probe;
            end
            if ((u4_got || u4_done) && (m2_got || m2_done)) begin
                r_pn[h] <= {round[13:0], h};
                newest <= h;
                running <= 1'b0; settle <= 18'd0;
                h <= h + 2'd1;
                if (h == 2'd3) round <= round + 16'd1;
            end
        end
    end

    // ---------------------------------------------------------------- display
    wire [7:0]  vr, vg, vb;
    wire        vhs, vvs, vde;
    wire [9:0]  vy;
    wire [4:0]  row_next;
    reg  [3:0]  page = 4'd0;
    reg  [9:0]  pframes = 10'd0;
    reg  [23:0] frames = 24'd0;
    reg  [9:0]  vy_d = 10'd0;
    always @(posedge clk) begin
        vy_d <= vy;
        if (vy == 10'd719 && vy_d == 10'd718) begin
            frames <= frames + 24'd1;
            if (pframes == PAGE_FRAMES - 1) begin pframes <= 10'd0; page <= {3'd0, ~page[0]}; end
            else pframes <= pframes + 10'd1;
        end
    end
    wire [767:0] stat;
    assign stat[0 +: 32]  = {round, 14'd0, newest};
    assign stat[32 +: 32] = {16'd0, u4_passes};
    assign stat[64 +: 32] = {16'd0, m2_passes};
    assign stat[96 +: 32] = {frames, 4'd0, page};
    assign stat[767:128]  = 640'd0;
    // table rows (screen.txt). Page 0: U4 rows 3-6 (passes, oldest first), G1 rows 9-12, G2
    // rows 13-16, column walk row 18, raw row 20. Page 1: probe rows 3-13, two entries each.
    wire [4:0] rn = row_next;
    wire [1:0] slot = newest + 2'd1 + rn[1:0] - 2'd3;   // rows 3-6 / 9-12 / 13-16: oldest first
    wire [1:0] slot2 = newest + 2'd1 + rn[1:0] - 2'd1;  // rows 9-12 (9 = 01)
    wire [1:0] slot3 = newest + 2'd1 + rn[1:0] - 2'd1;  // rows 13-16 (13 = 01)
    wire [4:0] pe0 = {rn - 5'd3, 1'b0};                  // probe entries of row rn
    reg  [255:0] rowstat = 256'd0;
    reg          row_blank = 1'b0;
    integer j;
    function [7:0] px(input [4:0] e, input [1:0] w);  // X0 / Xa / Xw of probe entry e
        px = w == 2'd0 ? 8'h11 + {3'd0, e} : w == 2'd1 ? 8'h81 + {3'd0, e} : 8'hC1 + {3'd0, e};
    endfunction
    always @(posedge clk) begin
        rowstat <= 256'd0;
        row_blank <= 1'b0;
        if (page == 4'd0) begin
            if (rn >= 5'd3 && rn <= 5'd6)
                for (j = 0; j < 8; j = j + 1)
                    rowstat[32*j +: 32] <= {j == 0 ? r_pn[slot][7:0] : 8'd0, r_u4[slot][24*j +: 24]};
            if (rn >= 5'd9 && rn <= 5'd12)
                for (j = 0; j < 6; j = j + 1) rowstat[32*j +: 32] <= {7'd0, r_m2[slot2][25*j +: 25]};
            if (rn >= 5'd13 && rn <= 5'd16)
                for (j = 0; j < 6; j = j + 1) rowstat[32*j +: 32] <= {7'd0, r_m2[slot3][25*(6+j) +: 25]};
            if (rn >= 5'd9 && rn <= 5'd12) rowstat[255:224] <= {16'd0, r_pn[slot2]};
            if (rn >= 5'd13 && rn <= 5'd16) rowstat[255:224] <= {16'd0, r_pn[slot3]};
            if (rn == 5'd18)
                for (j = 0; j < 6; j = j + 1)
                    rowstat[32*j +: 32] <= {5'd0, r_cw[11*(6+j) +: 11], 5'd0, r_cw[11*j +: 11]};
            if (rn == 5'd20) rowstat[127:0] <= r_raw;
        end else if (rn >= 5'd3 && rn <= 5'd13) begin
            rowstat[31:0]   <= {8'd0, px(pe0, 2'd0), px(pe0, 2'd1), px(pe0, 2'd2)};
            rowstat[63:32]  <= r_pr[32*pe0 +: 32];
            rowstat[95:64]  <= {8'd0, px(pe0 + 5'd1, 2'd0), px(pe0 + 5'd1, 2'd1), px(pe0 + 5'd1, 2'd2)};
            rowstat[127:96] <= r_pr[32*(pe0 + 5'd1) +: 32];
        end
    end
    textmode #(.SCREEN_HEX(SCREEN_HEX), .FONT_HEX(FONT_HEX), .PAGES(2), .FLAG_WORD(23)) txt (
        .clk(clk), .page(page), .stat(stat), .rowstat(rowstat), .row_blank(row_blank),
        .row_next(row_next), .r(vr), .g(vg), .b(vb), .hs(vhs), .vs(vvs), .de(vde), .frame_y(vy),
        .cx(), .cy(), .cell_row(), .cell_col(), .ext_q(8'h20), .fg());
    always @(posedge clk) begin
        {ch1, ch2, ch3} <= {vr, vg, vb};
        {s0, s1, s2}    <= {vvs, vde, vhs};
    end
    altddio_out #(
        .extend_oe_disable("OFF"), .intended_device_family("Cyclone V"),
        .invert_output("OFF"), .lpm_hint("UNUSED"), .lpm_type("altddio_out"),
        .oe_reg("UNREGISTERED"), .power_up_high("OFF"), .width(1)
    ) pclk_ddio (
        .datain_h(1'b0), .datain_l(1'b1), .outclock(clk), .dataout(pclk),
        .aclr(1'b0), .aset(1'b0), .oe(1'b1), .oe_out(), .outclocken(1'b1), .sclr(1'b0), .sset(1'b0)
    );
endmodule
