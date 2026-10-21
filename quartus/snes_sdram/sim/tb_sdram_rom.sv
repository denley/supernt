// SPDX-License-Identifier: GPL-3.0-or-later
// make sim-sdram-rom: quartus/common/sdram_rom.sv against the timed SDRAM model
// (sdram_model.v), with I/O and board delays between the FPGA registers and the chips:
//   D_CLK  FPGA clock edge -> SDRAM clock edge at the chips (DDIO output path + trace)
//   D_OUT  FPGA clock edge -> command/address/write data at the chips (IOE output registers)
//   D_IN   data at the chips -> FPGA input register
// The SDRAM clock is the inverted memory clock (DDIO), as on the board.
//
// A stand-in for the SA-1 drives the ROM port the way SA1.vhd does: one bus cycle per 2 clk_sys
// (CLK_CE high every other clk_sys cycle), new address after the CE edge, data latched at the
// next CE edge (8 memory clocks later), rfsh_ok = ~CLK_CE.
//   1. write ~2100 words through the write port (a block written top-down so a missing BURST
//      TERMINATE would corrupt the word above, random words over all 4 banks, page ends);
//      backdoor check of the model memory;
//   2. phase A: 6000 SA-1 cycles, a new random word in 60% of them (some odd-byte reads of the
//      word just read, which must not start a new read): every read must be right;
//   3. phase B: 600 SA-1 cycles with a new word in every one (no hidden-refresh slot at all):
//      refresh must still come within 15.6 us (forced, so some reads are late: counted only);
//   4. phase A again (2000 cycles), every read right.
// Prints PASS/FAIL. EXPECT_FAIL = 1 inverts the verdict for phases A (used to show that a wrong
// CAPTURE_HALF is caught).
`timescale 1ns/1ps
module tb_sdram_rom;
    parameter integer CAPTURE_HALF = 7;
    parameter real    D_CLK = 3.5, D_OUT = 3.5, D_IN = 1.0;
    parameter integer EXPECT_FAIL = 0;
    localparam real   TM = 1000.0 / 85.76784;          // memory clock period (ns)

    // ---------------------------------------------------------------- clocks (clk_sys = clk/4)
    reg clk = 0, clk_sys = 0;
    integer r = 0;
    initial forever begin
        #(TM / 2);
        clk = 1; r = r + 1;
        if (r % 4 == 0) clk_sys = 1; else if (r % 4 == 2) clk_sys = 0;
        #(TM / 2);
        clk = 0;
    end

    // ---------------------------------------------------------------- DUT
    reg         rom_en = 0, rom_word = 1, clk_ce = 0, sys_tog = 0;
    reg  [23:0] rom_addr = 0;
    wire [15:0] rom_q;
    reg         wr_req = 0;
    reg  [23:0] wr_addr = 0;
    reg  [15:0] wr_data = 0;
    wire        wr_ack, ready;
    wire        sd_clk, cs_n, ras_n, cas_n, we_n, dq_oe;
    wire [11:0] a;
    wire [1:0]  ba;
    wire [15:0] dq_out;
    reg  [15:0] dq_in_p = 16'hzzzz;
    wire [15:0] n_rf_forced, n_rf_stall, n_late;
    wire [10:0] rf_max;
    sdram_rom #(.CAPTURE_HALF(CAPTURE_HALF), .INIT_CYCLES(200)) dut (
        .clk(clk), .clk_sd(clk), .clk_cap(clk), .reset(1'b0), .ready(ready), .sys_tog(sys_tog),
        .rom_en(rom_en), .rom_addr(rom_addr), .rom_word(rom_word), .rom_q(rom_q), .rfsh_ok(~clk_ce),
        .wr_req(wr_req), .wr_addr(wr_addr), .wr_data(wr_data), .wr_ack(wr_ack),
        .aux_req(1'b0), .aux_addr(24'd0), .aux_ack(), .aux_valid(), .aux_q(),
        .sd_clk(sd_clk), .sd_cs_n(cs_n), .sd_ras_n(ras_n), .sd_cas_n(cas_n), .sd_we_n(we_n),
        .sd_a(a), .sd_ba(ba), .sd_dq_in(dq_in_p), .sd_dq_out(dq_out), .sd_dq_oe(dq_oe),
        .n_rf_forced(n_rf_forced), .n_rf_stall(n_rf_stall), .n_late(n_late), .rf_max(rf_max));

    // ---------------------------------------------------------------- board
    reg        sclk_p = 1'b1;
    reg [17:0] cmd_p = 18'h3ffff;
    reg [15:0] dqo_p = 16'd0;
    reg        oe_p = 1'b0;
    always @(sd_clk) sclk_p <= #(D_CLK) sd_clk;
    always @(cs_n, ras_n, cas_n, we_n, a, ba) cmd_p <= #(D_OUT) {cs_n, ras_n, cas_n, we_n, a, ba};
    always @(dq_out, dq_oe) begin dqo_p <= #(D_OUT) dq_out; oe_p <= #(D_OUT) dq_oe; end
    tri [15:0] dq_bus;
    assign dq_bus = oe_p ? dqo_p : 16'hzzzz;
    always @(dq_bus) dq_in_p <= #(D_IN) dq_bus;
    is42s_model mem (.clk(sclk_p), .cs_n(cmd_p[17]), .ras_n(cmd_p[16]), .cas_n(cmd_p[15]),
                     .we_n(cmd_p[14]), .a(cmd_p[13:2]), .ba(cmd_p[1:0]), .dq(dq_bus));
    integer contention = 0;
    always @(oe_p, mem.drive) if (oe_p && mem.drive) begin
        contention = contention + 1;
        $display("%t bus contention", $realtime);
    end

    // ---------------------------------------------------------------- test data
    function [15:0] dat(input [23:0] w);
        reg [31:0] x;
        begin
            x = {8'd0, w} * 32'h9E3779B1;
            dat = x[31:16] ^ x[15:0];
        end
    endfunction
    reg [31:0] lfsr = 32'h1234_5678;
    function [31:0] rnd(input integer dummy);
        begin
            lfsr = lfsr[0] ? (lfsr >> 1) ^ 32'hA300_0001 : lfsr >> 1;
            lfsr = lfsr[0] ? (lfsr >> 1) ^ 32'hA300_0001 : lfsr >> 1;
            rnd = lfsr;
        end
    endfunction
    localparam integer NW = 2112;
    reg [23:0] wl [0:NW-1];           // words written; [0, NROM) reachable from the ROM port
    integer    nrom = 0, nw = 0;

    // ---------------------------------------------------------------- SA-1 stand-in
    integer    mode = 0;              // 0 idle, 1 = phase A (60% new), 2 = phase B (100% new)
    integer    errs [0:3];
    integer    reads [0:3];
    integer    cycles = 0, ph = 0;
    reg        have_exp = 0;
    reg [15:0] exp;
    reg [23:0] cur_w;
    integer    pick;
    always @(posedge clk_sys) begin
        sys_tog <= ~sys_tog;
        if (mode != 0) begin
            clk_ce <= ~clk_ce;
            if (clk_ce) begin                       // SA-1 CE edge: latch data, next address
                if (have_exp) begin
                    reads[ph] = reads[ph] + 1;
                    if (rom_q !== exp) begin
                        errs[ph] = errs[ph] + 1;
                        if (errs[ph] <= 5 && ph != 2 && !EXPECT_FAIL)
                            $display("%t phase %0d: read %h got %h expected %h", $realtime, ph,
                                     rom_addr, rom_q, exp);
                    end
                end
                cycles = cycles + 1;
                pick = rnd(0) % 100;
                if (have_exp && mode == 1 && pick < 15 && rom_word && !rom_addr[0]) begin
                    // odd byte of the same word (no new read)
                    rom_addr <= rom_addr | 24'd1; rom_word <= 1'b0;
                    exp <= {dat(cur_w) >> 8} | (dat(cur_w) & 16'hff00);
                end else if (!have_exp || mode == 2 || pick < 60) begin
                    cur_w = wl[rnd(0) % nrom];
                    rom_addr <= {cur_w[22:0], 1'b0}; rom_word <= 1'b1;
                    exp <= dat(cur_w);
                end
                have_exp <= 1'b1;
            end
        end
    end

    // ---------------------------------------------------------------- sequence
    integer i, k, berr = 0, ok = 1;
    reg [23:0] w;
    initial begin
        for (i = 0; i < 4; i = i + 1) begin errs[i] = 0; reads[i] = 0; end
        // ROM-port words: a block written top-down, page ends, random words in banks 0-1
        for (i = 511; i >= 0; i = i - 1) begin wl[nw] = i; nw = nw + 1; end
        wl[nw] = 24'h0003FF; nw = nw + 1;           // last column of row 0 / first of row 1
        wl[nw] = 24'h000400; nw = nw + 1;
        wl[nw] = 24'h3FFFFF; nw = nw + 1;           // end of bank 0
        wl[nw] = 24'h400000; nw = nw + 1;           // start of bank 1
        wl[nw] = 24'h7FFFFF; nw = nw + 1;           // last ROM-port word
        while (nw < NW - 64) begin wl[nw] = rnd(0) & 24'h7FFFFF; nw = nw + 1; end
        nrom = nw;
        while (nw < NW) begin wl[nw] = (rnd(0) & 24'h7FFFFF) | 24'h800000; nw = nw + 1; end  // banks 2-3

        wait (ready);
        $display("%t init done (model: %0d REFs before MRS)", $realtime, mem.n_init_ref);
        for (i = 0; i < NW; i = i + 1) begin
            @(posedge clk);
            wr_req <= 1'b1; wr_addr <= wl[i]; wr_data <= dat(wl[i]);
            @(posedge clk);
            while (!wr_ack) @(posedge clk);
            wr_req <= 1'b0;
        end
        repeat (20) @(posedge clk);
        for (i = 0; i < NW; i = i + 1)
            if (mem.mem[wl[i]] !== dat(wl[i])) begin
                berr = berr + 1;
                if (berr <= 5) $display("backdoor: word %h = %h, expected %h", wl[i], mem.mem[wl[i]], dat(wl[i]));
            end
        $display("%t wrote %0d words (%0d via the ROM port range), backdoor errors %0d", $realtime, NW, nrom, berr);

        rom_en <= 1'b1;
        @(posedge clk_sys); ph = 1; mode = 1; cycles = 0;
        wait (cycles == 6000);
        k = n_late; $display("%t phase A: %0d reads, %0d errors, forced REF %0d, late %0d, REFs %0d, longest REF gap %0.0f ns",
                         $realtime, reads[1], errs[1], n_rf_forced, n_late, mem.n_ref, mem.max_ref_gap);
        ph = 2; mode = 2; cycles = 0;
        wait (cycles == 600);
        $display("%t phase B (a new word every SA-1 cycle): %0d reads, %0d errors, forced REF %0d, late %0d, longest REF gap %0.0f ns",
                 $realtime, reads[2], errs[2], n_rf_forced, n_late - k, mem.max_ref_gap);
        ph = 3; mode = 1; cycles = 0;
        wait (cycles == 2000);
        $display("%t phase A again: %0d reads, %0d errors", $realtime, reads[3], errs[3]);
        $display("model: %0d errors, %0d ACT, %0d READ, %0d words written, %0d REF, longest REF gap %0.0f ns; bus contention %0d; controller rf_max %0d cycles, stall %0d",
                 mem.errors, mem.n_act, mem.n_rd, mem.n_wr, mem.n_ref, mem.max_ref_gap, contention, rf_max, n_rf_stall);
        if (EXPECT_FAIL) begin
            ok = errs[1] + errs[3] > 0;
            $display("%s: CAPTURE_HALF %0d %s (phase A errors %0d)", ok ? "PASS" : "FAIL", CAPTURE_HALF,
                     ok ? "fails as expected" : "unexpectedly works", errs[1] + errs[3]);
        end else begin
            ok = errs[1] == 0 && errs[3] == 0 && berr == 0 && mem.errors == 0 && contention == 0 &&
                 mem.max_ref_gap <= 15625.0 && n_rf_forced > 0 && reads[1] > 3000;
            $display("%s: CAPTURE_HALF %0d, D_CLK %0.1f D_OUT %0.1f D_IN %0.1f", ok ? "PASS" : "FAIL",
                     CAPTURE_HALF, D_CLK, D_OUT, D_IN);
        end
        $finish;
    end
    initial begin #20_000_000; $display("FAIL: timeout"); $finish; end
endmodule
