// SPDX-License-Identifier: GPL-3.0-or-later
// Super Nt memory test core (memtest v1): tests all three SDRAM chips with the pin map of
// notes/sdram.md ("Which chip is which", "Controller 2"), results on a 2-page text screen
// (screen.txt; pages alternate every 6 s).
//   U4      - AS4C8M16SA x16 on the bottom-bank bus: sdram_test.sv at spc.cor's levels (AB10
//             low, constant pins at their stock level), errors per byte: A = 2A (never
//             answered so far), B = 3B (works)
//   U5/U16  - IS42S81600F pair on the top-bank bus: mem2_test.sv, errors per chip, column walk,
//             raw bytes of the first read
// Hypotheses (one pass of both tests each, then the next; ~1 s per hypothesis): C13 and C15,
// which spc.cor drives low from controller 2's logic and every earlier core left released,
// are 0 both released, 1 both low, 2 C13 low, 3 C15 low. If U4's second DQM ("chip A") or
// the pair's DQM is one of them, the matching rows go clean.
// Pin rules (notes/STATUS.md): every pin here is one spc.cor drives, used as it does; group 2's
// data and C13/C15 are only ever low or released.
module top #(
    parameter SCREEN_HEX = "../../build/memtest/screen.hex",
    parameter FONT_HEX   = "../../build/hwtest/font.hex",
    parameter [11:0] SD_ROWS   = 12'd4095, // rows per bank (simulation: fewer)
    parameter [15:0] INIT_NOP  = 16'd20000,
    parameter [17:0] SETTLE    = 18'h3FFFF, // clocks between a pin change and the next pass
    parameter integer PAGE_FRAMES = 360
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
    output wire [23:0] tie_hold,
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
    localparam [23:0] HOLD_LEVEL = 24'b1_00_11111111_0000000000000;
    assign tie3 = TIE3_LEVEL;
    assign tie_hold = HOLD_LEVEL;

    // ---------------------------------------------------------------- hypotheses
    reg  [1:0]  h = 2'd0;
    reg  [15:0] round = 16'd0;
    reg  [17:0] settle = 18'd0;
    reg         running = 1'b0, start = 1'b0, u4_got = 1'b0, m2_got = 1'b0;
    wire        c13_low = h == 2'd1 || h == 2'd2;
    wire        c15_low = h == 2'd1 || h == 2'd3;
    assign m_c13 = c13_low ? 1'b0 : 1'bz;
    assign m_c15 = c15_low ? 1'b0 : 1'bz;

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
    wire [199:0] m2_err;
    wire [87:0]  m2_cw;
    wire [127:0] m2_raw;
    assign g1_dq = g1_oe ? g1_out : 8'hzz;
    genvar gi;
    generate for (gi = 0; gi < 8; gi = gi + 1) begin : g_od
        assign g2_dq[gi] = g2_low[gi] ? 1'b0 : 1'bz;
    end endgenerate
    mem2_test #(.ROWS(SD_ROWS), .INIT_NOP(INIT_NOP)) m2 (
        .clk(clk), .start(start), .sd_clk(m_clk),
        .g1_cmd({g1_cs_n, g1_ras_n, g1_cas_n, g1_we_n}), .g1_a10(g1_a10),
        .g2_cmd({g2_cs_n, g2_ras_n, g2_cas_n, g2_we_n}), .g2_a10(g2_a10),
        .sd_a(m_a), .sd_a11(m_a11), .sd_ba(m_ba), .g1_dq_in(g1_dq), .g1_dq_out(g1_out),
        .g1_dq_oe(g1_oe), .g2_dq_in(g2_dq), .g2_low(g2_low), .busy(m2_busy), .done(m2_done),
        .passes(m2_passes), .last_err(m2_err), .last_cw(m2_cw), .last_raw(m2_raw));

    // results of each hypothesis's last pass
    reg [191:0] r_u4  [0:3];
    reg [199:0] r_m2  [0:3];
    reg [87:0]  r_cw  [0:3];
    reg [127:0] r_raw [0:3];
    reg [7:0]   r_n   [0:3];
    integer k;
    initial for (k = 0; k < 4; k = k + 1) begin
        r_u4[k] = 0; r_m2[k] = 0; r_cw[k] = 0; r_raw[k] = 0; r_n[k] = 0;
    end
    // set the pins of hypothesis h, wait SETTLE, start both tests, wait for both, store, next
    always @(posedge clk) begin
        start <= 1'b0;
        if (!running) begin
            settle <= settle + 18'd1;
            if (settle == SETTLE) begin
                start <= 1'b1; running <= 1'b1; u4_got <= 1'b0; m2_got <= 1'b0;
            end
        end else begin
            if (u4_done) begin u4_got <= 1'b1; r_u4[h] <= u4_err; end
            if (m2_done) begin m2_got <= 1'b1; r_m2[h] <= m2_err; r_cw[h] <= m2_cw; r_raw[h] <= m2_raw; end
            if ((u4_got || u4_done) && (m2_got || m2_done)) begin
                r_n[h] <= r_n[h] + 8'd1;
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
    assign stat[0 +: 32]  = {round, 14'd0, h};
    assign stat[32 +: 32] = {16'd0, u4_passes};
    assign stat[64 +: 32] = {16'd0, m2_passes};
    assign stat[96 +: 32] = {frames, 4'd0, page};
    assign stat[767:128]  = 640'd0;
    // table rows (screen.txt): page 0 U4 rows 5-8, U5/U16 rows 12-15; page 1 column walk rows
    // 5-8, raw rows 12-15
    wire [4:0] rn = row_next;
    wire       t1 = rn >= 5'd5 && rn <= 5'd8;
    wire       t2 = rn >= 5'd12 && rn <= 5'd15;
    wire [1:0] th = t1 ? rn[1:0] - 2'd1 : rn[1:0];   // 5-8 -> 0-3, 12-15 -> 0-3
    reg  [255:0] rowstat = 256'd0;
    reg          row_blank = 1'b0;
    integer j;
    always @(posedge clk) begin
        rowstat <= 256'd0;
        row_blank <= 1'b0;
        if (page == 4'd0 && t1)
            for (j = 0; j < 8; j = j + 1) rowstat[32*j +: 32] <= {r_n[th], r_u4[th][24*j +: 24]};
        else if (page == 4'd0 && t2)
            for (j = 0; j < 8; j = j + 1) rowstat[32*j +: 32] <= {7'd0, r_m2[th][25*j +: 25]};
        else if (page == 4'd1 && t1)
            for (j = 0; j < 8; j = j + 1) rowstat[32*j +: 32] <= {21'd0, r_cw[th][11*j +: 11]};
        else if (page == 4'd1 && t2)
            rowstat[127:0] <= r_raw[th];
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
