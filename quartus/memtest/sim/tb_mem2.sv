// make sim-mem2: quartus/common/mem2_test.sv against two x8_model chips (CL 2, which puts the
// data one clock earlier than CL3, as memtest v2 saw on the console; 4 rows per bank). G1 sits
// on the shared address bus. G2 has its own address pins, modelled as probe pins 0-12 (A0-A9 =
// 0-9, A11 = 10, BA = 11-12; low unless the probe releases one, released = pulled up) plus
// D17 as its A10, so G2's main test hits one location (errors expected) and the probe must
// classify the pins. Group 2's data lines are open drain with a pull-up that takes T_RISE to
// bring a released line high.
// Checks: G1 clean at f2.5 and r3 (main test and column walk); probe: pins 0-9, 11, 12 = row/
// column/bank (b1 = b2 = X0), 10 and D17 = row-only (b1 = X0, b2 = Xw), 13-20 = not address;
// with T_RISE longer than WAIT_OD (EXPECT_SLOW) the probe's group 2 bytes go wrong.
`timescale 1ns/1ps
module tb_mem2;
    parameter real T_RISE = 1000.0;
    parameter integer EXPECT_SLOW = 0;
    localparam integer NP = 22;
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
    wire [4:0] pr_sel;
    wire pr_hi;
    wire [15:0] passes;
    wire [299:0] err;
    wire [131:0] cw;
    wire [127:0] raw;
    wire [32*NP-1:0] probe;
    mem2_test #(.ROWS(12'd3), .INIT_NOP(16'd200), .NPROBE(NP)) dut (
        .clk(clk), .start(start), .sd_clk(sclk), .g1_cmd(c1), .g1_a10(a10_1), .g2_cmd(c2),
        .g2_a10(a10_2), .sd_a(a), .sd_a11(a11), .sd_ba(ba), .g1_dq_in(dq1), .g1_dq_out(d1out),
        .g1_dq_oe(oe1), .g2_dq_in(dq2), .g2_low(low2), .pr_sel(pr_sel), .pr_hi(pr_hi),
        .busy(busy), .done(done), .passes(passes), .last_err(err), .last_cw(cw), .last_raw(raw),
        .last_probe(probe));
    // G2's own address pins: probe pins 0-12, low unless released (then high)
    wire [12:0] pp;
    generate for (g = 0; g < 13; g = g + 1) begin : g_pp
        assign pp[g] = pr_hi && pr_sel == g;
    end endgenerate
    wire #5.0 sclk_d = sclk;
    x8_model #(.NAME("G1"), .CL(2)) m1 (.clk(sclk_d), .cs_n(c1[3]), .ras_n(c1[2]), .cas_n(c1[1]),
        .we_n(c1[0]), .dqm(1'b0), .a(a), .a10(a10_1), .a11(a11), .ba(ba), .dq(dq1));
    // G2's mode register sees its own (all low) address pins; the probe's bank pins make
    // accesses to closed banks on purpose (ignored, as a real chip does)
    x8_model #(.NAME("G2"), .CL(2), .MRS_PINS(10'd0), .STRICT(0)) m2 (.clk(sclk_d), .cs_n(c2[3]), .ras_n(c2[2]),
        .cas_n(c2[1]), .we_n(c2[0]), .dqm(1'b0), .a(pp[9:0]), .a10(a10_2), .a11(pp[10]),
        .ba(pp[12:11]), .dq(dq2));
    integer k, bad = 0, cls;
    reg [7:0] x0, xa, xw, b1, b2;
    initial begin
        #500 @(posedge clk) start = 1; @(posedge clk) start = 0;
        @(posedge done); #100;
        $write("pass %0d errors G1", passes);
        for (k = 0; k < 12; k = k + 1) begin
            if (k == 6) $write(" | G2");
            $write(" %0d", err[25*k +: 25]);
        end
        $write("\ncolumn walk G1");
        for (k = 0; k < 12; k = k + 1) begin
            if (k == 6) $write(" | G2");
            $write(" %03h", cw[11*k +: 11]);
        end
        $display("\nraw r2-r7 %h %h %h %h %h %h exp %h %h", raw[15:0], raw[31:16], raw[47:32],
                 raw[63:48], raw[79:64], raw[95:80], raw[111:96], raw[127:112]);
        $display("model G1: %0d errors, %0d writes, %0d reads; G2: %0d errors", m1.errors, m1.n_wr,
                 m1.n_rd, m2.errors);
        if (m1.errors || m2.errors) bad = bad + 1;
        if (err[25*0 +: 25] || err[25*1 +: 25] || cw[11*0 +: 11] || cw[11*1 +: 11]) bad = bad + 1;
        for (k = 0; k < NP; k = k + 1) begin
            x0 = 8'h11 + k; xa = 8'h81 + k; xw = 8'hC1 + k;
            b1 = probe[32*k + 24 +: 8]; b2 = probe[32*k + 8 +: 8];   // r3 bytes
            cls = b1 == x0 && b2 == x0 ? 2 : b1 == x0 && b2 == xw ? 1 : b1 == xa && b2 == xw ? 0 : 3;
            $display("probe %2d: X0 %h Xa %h Xw %h  b1 %h %h  b2 %h %h  -> %s", k, x0, xa, xw,
                     probe[32*k + 24 +: 8], probe[32*k + 16 +: 8], probe[32*k + 8 +: 8],
                     probe[32*k +: 8], cls == 2 ? "row/col/bank" : cls == 1 ? "row-only" :
                     cls == 0 ? "not address" : "?");
            if (!EXPECT_SLOW && cls != (k < 10 || k == 11 || k == 12 ? 2 : k == 10 || k == 21 ? 1 : 0))
                bad = bad + 1;
            if (EXPECT_SLOW && cls != 3) bad = bad + 1;
        end
        if (bad == 0) $display("PASS"); else $display("FAIL");
        $finish;
    end
endmodule
