// make sim-memtest: quartus/memtest (v3) with 4 rows per bank against models: U4 =
// quartus/hwtest/sim/sdram_model.v (x16, 512 columns, one edge late: clean at r4 and f4.5),
// byte A masked (as on the console), byte B's DQM on AB10; U5/U16 = two x8_model.v chips with
// CL 2 (one clock earlier, as v2 saw): G1 on the shared bus with its DQM on J8 (cand 20), G2
// with its DQM on B13 (cand 17) and its own address pins on cand 0-9 (A0-A9), 10 (A11) and
// 11-12 (BA), plus D17 as A10. After two passes: U4 byte B clean, byte A not; G1 clean at
// f2.5/r3 and its column walk too; the probe table (newest pass) classifies G2's pins.
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
    wire [22:0] tie_hold;
    wire mclk, ma11, g1cs, g1ras, g1cas, g1we, g1a10, g2cs, g2ras, g2cas, g2we, g2a10;
    wire [9:0] ma;
    wire [1:0] mba;
    tri [7:0] g1dq;
    wire [7:0] g2dq;
    tri1 c13, c15;                      // weak pull-ups
    tri1 [20:0] cand;
    tri1 [1:0] hi;
    localparam integer G1_DQM = 20, G2_DQM = 17;
    pullup p2 [7:0] (g2dq);
    top #(.SD_ROWS(12'd3), .INIT_NOP(16'd200), .SETTLE(18'd1000), .PAGE_FRAMES(1),
          .SCREEN_HEX("../memtest/screen.hex"), .FONT_HEX("../hwtest/font.hex")) dut (
        .clk(clk), .pclk(pclk), .s0(s0), .s1(s1), .s2(s2), .ch1(ch1), .ch2(ch2), .ch3(ch3),
        .sd_clk(sclk), .sd_cs_n(cs), .sd_ras_n(ras), .sd_cas_n(cas), .sd_we_n(we), .sd_a(a),
        .sd_ba(ba), .sd_dq(dq), .sd_cke(ab10), .tie3(tie3), .tie_hold(tie_hold),
        .m_clk(mclk), .m_a(ma), .m_a11(ma11), .m_ba(mba), .g1_cs_n(g1cs), .g1_ras_n(g1ras),
        .g1_cas_n(g1cas), .g1_we_n(g1we), .g1_a10(g1a10), .g2_cs_n(g2cs), .g2_ras_n(g2ras),
        .g2_cas_n(g2cas), .g2_we_n(g2we), .g2_a10(g2a10), .g1_dq(g1dq), .g2_dq(g2dq),
        .m_c13(c13), .m_c15(c15), .cand(cand), .hi_pins(hi));
    sdram_model u4 (.clk(sclk), .cs_n(cs), .ras_n(ras), .cas_n(cas), .we_n(we), .dqm_a(1'b1),
                    .dqm_b(ab10), .a(a), .ba(ba), .dq(dq));
    wire #5.0 mclk_d = mclk;
    x8_model #(.NAME("G1"), .CL(2)) m1 (.clk(mclk_d), .cs_n(g1cs), .ras_n(g1ras), .cas_n(g1cas),
        .we_n(g1we), .dqm(cand[G1_DQM]), .a(ma), .a10(g1a10), .a11(ma11), .ba(mba), .dq(g1dq));
    x8_model #(.NAME("G2"), .CL(2), .MRS_PINS(10'd0), .STRICT(0)) m2 (.clk(mclk_d), .cs_n(g2cs),
        .ras_n(g2ras), .cas_n(g2cas), .we_n(g2we), .dqm(cand[G2_DQM]), .a(cand[9:0]), .a10(g2a10),
        .a11(cand[10]), .ba(cand[12:11]), .dq(g2dq));
    integer h, k, bad = 0, cls;
    reg [7:0] x0, xa, xw, b1, b2;
    initial begin
        wait (dut.m2_passes == 2 && dut.u4_passes == 2 && !dut.running);
        #1000;
        for (h = 0; h < 2; h = h + 1) begin
            $write("slot %0d U4 A", h);
            for (k = 0; k < 8; k = k + 1) begin
                if (k == 4) $write(" B");
                $write(" %0d", dut.r_u4[h][24*k +: 24]);
            end
            $write(" | G1");
            for (k = 0; k < 12; k = k + 1) begin
                if (k == 6) $write(" G2");
                $write(" %0d", dut.r_m2[h][25*k +: 25]);
            end
            $display("");
            if (dut.r_u4[h][24*1 +: 24] == 0 || dut.r_u4[h][24*5 +: 24] != 0 || dut.r_u4[h][24*6 +: 24] != 0 ||
                dut.r_m2[h][25*0 +: 25] != 0 || dut.r_m2[h][25*1 +: 25] != 0) begin
                $display("  ^ unexpected"); bad = bad + 1;
            end
        end
        $write("column walk");
        for (k = 0; k < 12; k = k + 1) $write(" %03h", dut.r_cw[11*k +: 11]);
        $display("");
        if (dut.r_cw[10:0] != 0 || dut.r_cw[21:11] != 0) bad = bad + 1;
        for (k = 0; k < 22; k = k + 1) begin
            x0 = 8'h11 + k; xa = 8'h81 + k; xw = 8'hC1 + k;
            b1 = dut.r_pr[32*k + 24 +: 8]; b2 = dut.r_pr[32*k + 8 +: 8];
            cls = b1 == x0 && b2 == x0 ? 2 : b1 == x0 && b2 == xw ? 1 : b1 == xa && b2 == xw ? 0 : 3;
            $display("probe %2d: b1 %h b2 %h -> %0d", k, b1, b2, cls);
            if (cls != (k < 10 || k == 11 || k == 12 ? 2 : k == 10 || k == 21 ? 1 : 0)) bad = bad + 1;
        end
        if (m1.errors || m2.errors) bad = bad + 1;
        if (bad == 0) $display("PASS"); else $display("FAIL");
        $finish;
    end
    initial begin #20_000_000_000; $display("TIMEOUT"); $finish; end
endmodule
