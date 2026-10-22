// make sim-sdram: sdram_test.sv against sdram_model.v (4 rows per bank, 512-column page). The
// model's chip B DQM is AB10 (as v2 found on the console) and chip A's is one of the switched
// constant pins, tie3[CHIP_A_TIE] (released = pulled up = masked). Checks one round of the
// 16 hypotheses: chip B clean at r4 and f4.5 except in 13 (AB10 high); chip A clean exactly in
// the hypotheses that keep tie pin CHIP_A_TIE at its stock level, so that the pattern of
// hypotheses 2-11 spells out its index.
`timescale 1ns/1ps
module tb_sdram;
    localparam integer CHIP_A_TIE = 5;
    reg clk = 0;
    always #6.734 clk = ~clk;
    wire sclk, cs, ras, cas, we, oe, ab10;
    wire [7:0] odl;
    wire [18:0] rel;
    wire [11:0] a;
    wire [1:0] ba;
    wire [15:0] dout;
    tri0 [15:0] dq;                     // undriven bus reads 0
    assign dq = oe ? dout : 16'hzzzz;
    wire [15:0] passes;
    wire [3:0] hyp;
    reg  [3:0] hsel = 0;
    wire [191:0] er;
    wire [159:0] raw;
    sdram_test #(.ROWS(12'd3), .INIT_NOP(16'd200)) dut (
        .clk(clk), .sd_clk(sclk), .sd_cs_n(cs), .sd_ras_n(ras), .sd_cas_n(cas), .sd_we_n(we),
        .sd_a(a), .sd_ba(ba), .sd_dq_in(dq), .sd_dq_out(dout), .sd_dq_oe(oe), .ab10(ab10),
        .od_low(odl), .tie_rel(rel), .passes(passes), .hyp(hyp), .hsel(hsel), .err_row(er),
        .raw_row(raw));
    // chip A's DQM: tie pin CHIP_A_TIE, stock level 0, released = pulled up
    wire dqm_a = rel[CHIP_A_TIE];
    sdram_model mem (.clk(sclk), .cs_n(cs), .ras_n(ras), .cas_n(cas), .we_n(we), .dqm_a(dqm_a),
                     .dqm_b(ab10), .a(a), .ba(ba), .dq(dq));
    integer h, k, bad = 0;
    reg a_ok, b_ok, a_want, b_want;
    reg [4:0] idx = 0;
    always @(passes) if (passes == 16) begin
        #2000;
        for (h = 0; h < 16; h = h + 1) begin
            @(posedge clk) hsel = h;
            @(posedge clk); @(posedge clk); #1;
            $write("hyp %2d (passes %0d): A", h, raw[159:144]);
            for (k = 0; k < 8; k = k + 1) begin
                if (k == 4) $write(" | B");
                $write(" %0d", er[24*k +: 24]);
            end
            $write(" | raw r2-r7 %h %h %h %h %h %h exp %h %h idle %h\n", raw[15:0], raw[31:16],
                   raw[47:32], raw[63:48], raw[79:64], raw[95:80], raw[111:96], raw[127:112],
                   raw[143:128]);
            a_ok = er[24*1 +: 24] == 0 && er[24*2 +: 24] == 0;   // r4, f4.5
            b_ok = er[24*5 +: 24] == 0 && er[24*6 +: 24] == 0;
            a_want = h == 1 ? 0 : (h >= 2 && h <= 6) ? !((CHIP_A_TIE >> (h - 2)) & 1) :
                     (h >= 7 && h <= 11) ? ((CHIP_A_TIE >> (h - 7)) & 1) : 1;
            b_want = h != 13;
            if (a_ok != a_want || b_ok != b_want || raw[159:144] != 1) begin
                $display("  ^ unexpected (chip A ok %0d want %0d, chip B ok %0d want %0d)",
                         a_ok, a_want, b_ok, b_want);
                bad = bad + 1;
            end
            if (h >= 2 && h <= 6 && !a_ok) idx[h - 2] = 1;
        end
        $display("chip A's tie index from hypotheses 2-6: %0d (model: %0d)", idx, CHIP_A_TIE);
        if (idx != CHIP_A_TIE) bad = bad + 1;
        if (bad == 0) $display("PASS"); else $display("FAIL");
        $finish;
    end
endmodule
