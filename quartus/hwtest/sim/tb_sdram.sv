// make sim-sdram: sdram_test.sv against sdram_model.v (4 rows per bank, 3 passes).
`timescale 1ns/1ps
module tb_sdram;
    reg clk = 0;
    always #6.734 clk = ~clk;
    wire sclk, cs, ras, cas, we, oe, dqm;
    wire [11:0] a;
    wire [1:0] ba;
    wire [15:0] dout, dq;
    assign dq = oe ? dout : 16'hzzzz;
    wire [31:0] e0, e1, e2, e3, e4, e5, e6, e7, ed0, edz, fb;
    wire [15:0] passes, fg, fe;
    sdram_test #(.ROWS(12'd3)) dut (
        .clk(clk), .sd_clk(sclk), .sd_cs_n(cs), .sd_ras_n(ras), .sd_cas_n(cas), .sd_we_n(we),
        .sd_a(a), .sd_ba(ba), .sd_dq_in(dq), .sd_dq_out(dout), .sd_dq_oe(oe), .dqm_low(dqm),
        .err0(e0), .err1(e1), .err2(e2), .err3(e3), .err4(e4), .err5(e5), .err6(e6), .err7(e7), .passes(passes),
        .err_dqm0(ed0), .err_dqmz(edz), .first_bad(fb), .first_got(fg), .first_exp(fe));
    sdram_model mem (.clk(sclk), .cs_n(cs), .ras_n(ras), .cas_n(cas), .we_n(we), .a(a), .ba(ba), .dq(dq));
    always @(passes) if (passes != 0) begin
        $display("pass %0d: rise3 %0d fall2.5 %0d rise4 %0d fall3.5 %0d rise5 %0d fall4.5 %0d rise6 %0d fall5.5 %0d | dqm0 %0d dqmz %0d first_bad %h got %h exp %h",
                 passes, e0, e1, e2, e3, e4, e5, e6, e7, ed0, edz, fb, fg, fe);
        if (passes == 3) $finish;
    end
endmodule
