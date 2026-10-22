// make sim-sdram: sdram_test.sv against sdram_model.v (4 rows per bank), with AB10 wired to
// the model's DQM: hypotheses 0/1 (AB10 low) must pass at the expected capture points (2 =
// rise 4, 5 = fall 4.5), 2/3 (AB10 high: reads masked, the bus floats low) must fail
// everywhere. Two rounds of the four hypotheses.
`timescale 1ns/1ps
module tb_sdram;
    reg clk = 0;
    always #6.734 clk = ~clk;
    wire sclk, cs, ras, cas, we, oe, ab10, dqm;
    wire [11:0] a;
    wire [1:0] ba;
    wire [15:0] dout;
    tri0 [15:0] dq;                     // undriven bus reads 0
    assign dq = oe ? dout : 16'hzzzz;
    wire [15:0] passes, hp;
    wire [1:0] hyp;
    reg  [1:0] hsel = 0;
    wire [255:0] er;
    wire [143:0] raw;
    sdram_test #(.ROWS(12'd3), .INIT_NOP(16'd200)) dut (
        .clk(clk), .sd_clk(sclk), .sd_cs_n(cs), .sd_ras_n(ras), .sd_cas_n(cas), .sd_we_n(we),
        .sd_a(a), .sd_ba(ba), .sd_dq_in(dq), .sd_dq_out(dout), .sd_dq_oe(oe), .ab10(ab10),
        .dqm_low(dqm), .passes(passes), .hyp(hyp), .hsel(hsel), .err_row(er), .raw_row(raw),
        .hyp_passes(hp));
    sdram_model mem (.clk(sclk), .cs_n(cs), .ras_n(ras), .cas_n(cas), .we_n(we), .dqm(ab10),
                     .a(a), .ba(ba), .dq(dq));
    integer h, k, bad = 0;
    always @(passes) if (passes == 8) begin
        #2000;
        for (h = 0; h < 4; h = h + 1) begin
            hsel = h; #1;
            $write("hyp %0d (passes %0d):", h, hp);
            for (k = 0; k < 8; k = k + 1) $write(" %0d", er[32*k +: 32]);
            $write(" | raw r2-r7 %h %h %h %h %h %h exp %h %h idle %h\n", raw[15:0], raw[31:16],
                   raw[47:32], raw[63:48], raw[79:64], raw[95:80], raw[111:96], raw[127:112],
                   raw[143:128]);
            if (hp != 2) bad = bad + 1;
            if (h < 2 && (er[32*2 +: 32] != 0 || er[32*5 +: 32] != 0)) bad = bad + 1;
            for (k = 0; k < 8; k = k + 1) if (h >= 2 && er[32*k +: 32] == 0) bad = bad + 1;
        end
        if (bad == 0) $display("PASS"); else $display("FAIL");
        $finish;
    end
endmodule
