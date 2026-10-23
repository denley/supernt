// make sim-memtest: quartus/memtest top with 4 rows per bank against models: U4 =
// quartus/hwtest/sim/sdram_model.v (x16, 512 columns, one edge late: clean at r4 and f4.5),
// byte A's DQM on C15 (released = pulled up = masked), byte B's on AB10; U5/U16 = two
// x8_model.v chips whose DQM is C13. After one round of the four hypotheses: U4 byte B clean
// in all, byte A clean only where C15 is low (1, 3); U5/U16 clean at f3.5/r4 only where C13 is
// low (1, 2), column walk too.
`timescale 1ns/1ps
module tb;
    reg clk = 0;
    always #6.734 clk = ~clk;
    wire pclk, s0, s1, s2;
    wire [7:0] ch1, ch2, ch3;
    wire sclk, cs, ras, cas, we, ab10;
    wire [11:0] a;
    wire [1:0] ba;
    tri0 [15:0] dq;
    wire [18:0] tie3;
    wire [23:0] tie_hold;
    wire mclk, ma11, g1cs, g1ras, g1cas, g1we, g1a10, g2cs, g2ras, g2cas, g2we, g2a10;
    wire [9:0] ma;
    wire [1:0] mba;
    tri [7:0] g1dq;
    wire [7:0] g2dq;
    tri1 c13, c15;                      // weak pull-ups
    pullup p2 [7:0] (g2dq);
    top #(.SD_ROWS(12'd3), .INIT_NOP(16'd200), .SETTLE(18'd1000), .PAGE_FRAMES(1),
          .SCREEN_HEX("../memtest/screen.hex"), .FONT_HEX("../hwtest/font.hex")) dut (
        .clk(clk), .pclk(pclk), .s0(s0), .s1(s1), .s2(s2), .ch1(ch1), .ch2(ch2), .ch3(ch3),
        .sd_clk(sclk), .sd_cs_n(cs), .sd_ras_n(ras), .sd_cas_n(cas), .sd_we_n(we), .sd_a(a),
        .sd_ba(ba), .sd_dq(dq), .sd_cke(ab10), .tie3(tie3), .tie_hold(tie_hold),
        .m_clk(mclk), .m_a(ma), .m_a11(ma11), .m_ba(mba), .g1_cs_n(g1cs), .g1_ras_n(g1ras),
        .g1_cas_n(g1cas), .g1_we_n(g1we), .g1_a10(g1a10), .g2_cs_n(g2cs), .g2_ras_n(g2ras),
        .g2_cas_n(g2cas), .g2_we_n(g2we), .g2_a10(g2a10), .g1_dq(g1dq), .g2_dq(g2dq),
        .m_c13(c13), .m_c15(c15));
    sdram_model u4 (.clk(sclk), .cs_n(cs), .ras_n(ras), .cas_n(cas), .we_n(we), .dqm_a(c15),
                    .dqm_b(ab10), .a(a), .ba(ba), .dq(dq));
    wire #5.0 mclk_d = mclk;
    x8_model #(.NAME("U5")) m1 (.clk(mclk_d), .cs_n(g1cs), .ras_n(g1ras), .cas_n(g1cas), .we_n(g1we),
        .dqm(c13), .a(ma), .a10(g1a10), .a11(ma11), .ba(mba), .dq(g1dq));
    x8_model #(.NAME("U16")) m2 (.clk(mclk_d), .cs_n(g2cs), .ras_n(g2ras), .cas_n(g2cas), .we_n(g2we),
        .dqm(c13), .a(ma), .a10(g2a10), .a11(ma11), .ba(mba), .dq(g2dq));
    integer h, k, bad = 0;
    reg ua, ub, um, uc;
    initial begin
        wait (dut.round == 1);
        #1000;
        for (h = 0; h < 4; h = h + 1) begin
            $write("h%0d n%0d U4 A", h, dut.r_n[h]);
            for (k = 0; k < 8; k = k + 1) begin
                if (k == 4) $write(" B");
                $write(" %0d", dut.r_u4[h][24*k +: 24]);
            end
            $write(" | U5/U16 G1");
            for (k = 0; k < 8; k = k + 1) begin
                if (k == 4) $write(" G2");
                $write(" %0d", dut.r_m2[h][25*k +: 25]);
            end
            $write(" | cw");
            for (k = 0; k < 8; k = k + 1) $write(" %03h", dut.r_cw[h][11*k +: 11]);
            $display("");
            ua = dut.r_u4[h][24*1 +: 24] == 0 && dut.r_u4[h][24*2 +: 24] == 0;
            ub = dut.r_u4[h][24*5 +: 24] == 0 && dut.r_u4[h][24*6 +: 24] == 0;
            um = dut.r_m2[h][25*0 +: 25] == 0 && dut.r_m2[h][25*1 +: 25] == 0 &&
                 dut.r_m2[h][25*4 +: 25] == 0 && dut.r_m2[h][25*5 +: 25] == 0;
            uc = dut.r_cw[h][11*0 +: 11] == 0 && dut.r_cw[h][11*1 +: 11] == 0 &&
                 dut.r_cw[h][11*4 +: 11] == 0 && dut.r_cw[h][11*5 +: 11] == 0;
            if (ua != (h == 1 || h == 3) || !ub || um != (h == 1 || h == 2) ||
                uc != (h == 1 || h == 2) || dut.r_n[h] != 1) begin
                $display("  ^ unexpected"); bad = bad + 1;
            end
        end
        if (m1.errors || m2.errors) bad = bad + 1;
        if (bad == 0) $display("PASS"); else $display("FAIL");
        $finish;
    end
    initial begin #2_000_000_000; $display("TIMEOUT"); $finish; end
endmodule
