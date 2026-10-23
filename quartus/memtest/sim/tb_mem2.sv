// make sim-mem2: quartus/common/mem2_test.sv against two x8_model chips (4 rows per bank).
// Group 2's data lines are open drain with a pull-up that takes T_RISE to bring a released
// line high (a line read as 0 before that), so a write that doesn't wait WAIT_OD stores 0s.
// Checks: with DQM low, both groups clean at f3.5 and r4 (the datasheet window at these model
// delays), column walk clean; with T_RISE longer than WAIT_OD, group 2 fails; with an address
// pin stuck at group 2's chip (G2_STUCK), its column walk flags column 0.
`timescale 1ns/1ps
module tb_mem2;
    parameter real T_RISE = 1000.0;
    parameter integer EXPECT_G2_FAIL = 0;
    parameter integer G2_STUCK = -1;    // >= 0: that address pin stuck low at group 2's chip
    reg clk = 0;
    always #6.734 clk = ~clk;
    wire sclk;
    wire [3:0] c1, c2;
    wire a10_1, a10_2, a11;
    wire [9:0] a;
    wire [1:0] ba;
    wire [7:0] d1out, low2;
    wire oe1;
    tri  [7:0] dq1;
    assign dq1 = oe1 ? d1out : 8'hzz;
    // group 2: open drain + slow pull-up
    wire [7:0] dq2;
    genvar g;
    generate for (g = 0; g < 8; g = g + 1) begin : g_od
        wire up;
        assign #(T_RISE, 0) up = !low2[g];
        assign (weak0, weak1) dq2[g] = up;
        assign dq2[g] = low2[g] ? 1'b0 : 1'bz;
    end endgenerate
    reg start = 0;
    wire busy, done;
    wire [15:0] passes;
    wire [199:0] err;
    wire [87:0] cw;
    wire [127:0] raw;
    mem2_test #(.ROWS(12'd3), .INIT_NOP(16'd200)) dut (
        .clk(clk), .start(start), .sd_clk(sclk), .g1_cmd(c1), .g1_a10(a10_1), .g2_cmd(c2),
        .g2_a10(a10_2), .sd_a(a), .sd_a11(a11), .sd_ba(ba), .g1_dq_in(dq1), .g1_dq_out(d1out),
        .g1_dq_oe(oe1), .g2_dq_in(dq2), .g2_low(low2), .busy(busy), .done(done),
        .passes(passes), .last_err(err), .last_cw(cw), .last_raw(raw));
    // board: SDRAM clock edge 5 ns after clk's falling edge (DDIO output + trace), which puts
    // both f3.5 and r4 in the read window (as on the console for U4, notes/sdram.md)
    wire #5.0 sclk_d = sclk;
    x8_model #(.NAME("G1")) m1 (.clk(sclk_d), .cs_n(c1[3]), .ras_n(c1[2]), .cas_n(c1[1]), .we_n(c1[0]),
        .dqm(1'b0), .a(a), .a10(a10_1), .a11(a11), .ba(ba), .dq(dq1));
    x8_model #(.NAME("G2")) m2 (.clk(sclk_d), .cs_n(c2[3]), .ras_n(c2[2]), .cas_n(c2[1]), .we_n(c2[0]),
        .dqm(1'b0), .a(G2_STUCK >= 0 ? a & ~(10'd1 << G2_STUCK) : a), .a10(a10_2), .a11(a11), .ba(ba), .dq(dq2));
    integer k, bad = 0;
    initial begin
        #500 @(posedge clk) start = 1; @(posedge clk) start = 0;
        @(posedge done); #100;
        $write("pass %0d errors G1", passes);
        for (k = 0; k < 8; k = k + 1) begin
            if (k == 4) $write(" | G2");
            $write(" %0d", err[25*k +: 25]);
        end
        $write("\ncolumn walk G1");
        for (k = 0; k < 8; k = k + 1) begin
            if (k == 4) $write(" | G2");
            $write(" %03h", cw[11*k +: 11]);
        end
        $display("\nraw r2-r7 %h %h %h %h %h %h exp %h %h", raw[15:0], raw[31:16], raw[47:32],
                 raw[63:48], raw[79:64], raw[95:80], raw[111:96], raw[127:112]);
        $display("model G1: %0d errors, %0d writes, %0d reads, %0d refreshes; G2: %0d errors",
                 m1.errors, m1.n_wr, m1.n_rd, m1.n_ref, m2.errors);
        if (m1.errors || m2.errors) bad = bad + 1;
        if (err[25*0 +: 25] || err[25*1 +: 25] || cw[11*0 +: 11] || cw[11*1 +: 11]) bad = bad + 1;
        if (G2_STUCK >= 0) begin
            // column 2^G2_STUCK lands on column 0: entry 0 reads entry G2_STUCK+1's byte
            if (cw[11*4 +: 11] != 11'h001 || cw[11*5 +: 11] != 11'h001) bad = bad + 1;
        end else if (EXPECT_G2_FAIL) begin
            if (err[25*4 +: 25] == 0 || err[25*5 +: 25] == 0) bad = bad + 1;
        end else if (err[25*4 +: 25] || err[25*5 +: 25] || cw[11*4 +: 11] || cw[11*5 +: 11])
            bad = bad + 1;
        if (m1.n_wr != 16 * 1024 + 11 || m1.n_rd != 16 * 1024 + 11) bad = bad + 1;
        // second pass on a new start (results must repeat, pass seed changes the patterns)
        @(posedge clk) start = 1; @(posedge clk) start = 0;
        @(posedge done); #100;
        $display("pass %0d: G1 r4 %0d G2 r4 %0d", passes, err[25*1 +: 25], err[25*5 +: 25]);
        if (passes != 2) bad = bad + 1;
        if (!EXPECT_G2_FAIL && G2_STUCK < 0 && (err[25*1 +: 25] || err[25*5 +: 25])) bad = bad + 1;
        if (bad == 0) $display("PASS"); else $display("FAIL");
        $finish;
    end
endmodule
