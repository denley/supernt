// SPDX-License-Identifier: GPL-3.0-or-later
// make sim-sdram-rom8: quartus/common/sdram_rom8.sv (chip B alone, 8 bit, 512-column pages)
// against the timed SDRAM model (quartus/snes_sdram/sim/sdram_model.v with COL_BITS 9), with I/O
// and board delays as tb_sdram_rom.sv (D_CLK, D_OUT, D_IN). The model drives both DQ bytes; the
// controller must only use DQ[15:8].
//   1. write ~2100 bytes through the write port (a block top-down so a missing BURST TERMINATE
//      would corrupt the byte above, page ends incl. column 511, all 4 banks, the last byte of
//      the 8 MB); backdoor check; 64 aux-port reads (the loader's read-back);
//   2. phase A: 6000 SA-1 cycles as SA1.vhd makes them (one bus cycle per 2 clk_sys, address
//      after the CE edge, data latched 2 clk_sys = 10 clk cycles later; clk = 5 x clk_sys as in
//      quartus/snes_load), rom_word = 1: a new random byte
//      address in 50%, the other byte of the same word in 20% (after an even start no new read
//      may be needed), byte reads (rom_word = 0, the Lo/HiROM mapper) in 10%. At each latch the
//      lane the consumers pick (address bit 0) must hold byte A; a word read at an even address
//      is held for a second SA-1 cycle, at whose latch both lanes must hold {A + 1, A} (the
//      SA-1's VBP word with sa1_vbp.patch);
//   3. phase B: 600 cycles with a new address in every one (no hidden refresh slot): refresh
//      within 15.6 us, late reads only counted;
//   4. phase A again (2000 cycles).
// PASS/FAIL; EXPECT_FAIL = 1 inverts the verdict (a wrong CAPTURE_HALF must be caught).
`timescale 1ns/1ps
module tb_sdram_rom8;
    parameter integer CAPTURE_HALF = 8;
    parameter real    D_CLK = 3.5, D_OUT = 3.5, D_IN = 1.0;
    parameter integer EXPECT_FAIL = 0;
    localparam real   TM = 1000.0 / 107.2098;           // clk = 5 x clk_sys

    reg clk = 0, clk_sys = 0;
    integer r = 0;
    initial forever begin
        #(TM / 2);
        clk = 1; r = r + 1;
        if (r % 5 == 0) clk_sys = 1; else if (r % 5 == 3) clk_sys = 0;   // (duty doesn't matter)
        #(TM / 2);
        clk = 0;
    end

    reg         rom_en = 0, rom_word = 1, clk_ce = 0, sys_tog = 0;
    reg  [23:0] rom_addr = 0;
    wire [15:0] rom_q;
    reg         wr_req = 0, aux_req = 0;
    reg  [22:0] wr_addr = 0, aux_addr = 0;
    reg  [7:0]  wr_data = 0;
    wire        wr_ack, ready, aux_ack, aux_valid;
    wire [7:0]  aux_q;
    wire        sd_clk, cs_n, ras_n, cas_n, we_n, dq_oe;
    wire [11:0] a;
    wire [1:0]  ba;
    wire [15:0] dq_out;
    reg  [15:0] dq_in_p = 16'hzzzz;
    wire [15:0] n_rf_forced, n_rf_stall, n_late;
    wire [10:0] rf_max;
    wire [31:0] n_reads;
    sdram_rom8 #(.CAPTURE_HALF(CAPTURE_HALF), .INIT_CYCLES(250)) dut (
        .clk(clk), .clk_sd(clk), .clk_cap(clk), .reset(1'b0), .ready(ready), .sys_tog(sys_tog),
        .rom_en(rom_en), .rom_addr(rom_addr), .rom_word(rom_word), .rom_q(rom_q), .rfsh_ok(~clk_ce),
        .wr_req(wr_req), .wr_addr(wr_addr), .wr_data(wr_data), .wr_ack(wr_ack),
        .aux_req(aux_req), .aux_addr(aux_addr), .aux_ack(aux_ack), .aux_valid(aux_valid), .aux_q(aux_q),
        .sd_clk(sd_clk), .sd_cs_n(cs_n), .sd_ras_n(ras_n), .sd_cas_n(cas_n), .sd_we_n(we_n),
        .sd_a(a), .sd_ba(ba), .sd_dq_in(dq_in_p), .sd_dq_out(dq_out), .sd_dq_oe(dq_oe),
        .n_rf_forced(n_rf_forced), .n_rf_stall(n_rf_stall), .n_late(n_late), .rf_max(rf_max),
        .n_reads(n_reads));

    // board
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
    is42s_model #(.COL_BITS(9)) mem (.clk(sclk_p), .cs_n(cmd_p[17]), .ras_n(cmd_p[16]),
        .cas_n(cmd_p[15]), .we_n(cmd_p[14]), .a(cmd_p[13:2]), .ba(cmd_p[1:0]), .dq(dq_bus));
    integer contention = 0;
    always @(oe_p, mem.drive) if (oe_p && mem.drive) begin
        contention = contention + 1;
        $display("%t bus contention", $realtime);
    end

    // test data: byte at SDRAM byte address b (the model keeps 16-bit words: chip B's byte is
    // the high one; the low byte is chip A's, which we never read)
    function [7:0] dat(input [22:0] b);
        reg [31:0] x;
        begin
            x = {9'd0, b} * 32'h9E3779B1;
            dat = x[31:24] ^ x[15:8] ^ x[7:0];
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
    reg [22:0] wl [0:NW-1];           // bytes written (pairs: wl[2k] even, wl[2k+1] = +1)
    integer    nw = 0;

    // SA-1 stand-in
    integer    mode = 0;
    integer    errs [0:3];
    integer    vbp_errs [0:3];
    integer    reads [0:3];
    integer    cycles = 0, ph = 0;
    reg        have_exp = 0, chk_hi = 0, hold = 0;
    reg [7:0]  exp_b, exp_hi, exp_lo;
    reg [22:0] cur;
    integer    pick, j;
    always @(posedge clk_sys) begin
        sys_tog <= ~sys_tog;
        if (mode != 0) begin
            clk_ce <= ~clk_ce;
            if (clk_ce) begin                       // SA-1 CE edge: latch data, next address
                if (have_exp) begin
                    reads[ph] = reads[ph] + 1;
                    if ((rom_addr[0] && rom_word ? rom_q[15:8] : rom_q[7:0]) !== exp_b) begin
                        errs[ph] = errs[ph] + 1;
                        if (errs[ph] <= 5 && ph != 2 && EXPECT_FAIL != 1)
                            $display("%t phase %0d: read %h (word %0d) got %h expected %h", $realtime,
                                     ph, rom_addr, rom_word, rom_q, exp_b);
                    end
                    if (chk_hi && !hold && (rom_q[15:8] !== exp_hi || rom_q[7:0] !== exp_lo)) begin
                        vbp_errs[ph] = vbp_errs[ph] + 1;
                        if (vbp_errs[ph] <= 2 && ph != 2 && !EXPECT_FAIL)
                            $display("%t phase %0d: word %h high byte got %h expected %h", $realtime,
                                     ph, rom_addr, rom_q[15:8], exp_hi);
                    end
                end
                cycles = cycles + 1;
                pick = rnd(0) % 100;
                if (hold) begin
                    hold <= 1'b0;                   // VBP: same address, word taken now
                end else if (have_exp && mode == 1 && pick < 20 && rom_word) begin
                    // the other byte of the same word
                    cur = rom_addr[22:0] ^ 23'd1;
                    rom_addr <= {1'b0, cur};
                    exp_b <= dat(cur);
                    chk_hi <= 1'b0;
                end else if (!have_exp || mode == 2 || pick < 70) begin
                    j = rnd(0) % nw;
                    cur = wl[j];
                    rom_addr <= {1'b0, cur};
                    rom_word <= mode == 2 || pick >= 60 ? 1'b1 : (pick % 2 == 0);
                    exp_b <= dat(cur);
                    // the VBP word: an even address whose partner was written too
                    chk_hi <= !cur[0] && (mode == 2 || pick >= 60 || pick % 2 == 0) && j + 1 < nw &&
                              wl[j + 1] == cur + 23'd1 && pick % 3 == 0 && mode == 1;
                    hold <= !cur[0] && (mode == 2 || pick >= 60 || pick % 2 == 0) && j + 1 < nw &&
                            wl[j + 1] == cur + 23'd1 && pick % 3 == 0 && mode == 1;
                    exp_hi <= dat(cur + 23'd1);
                    exp_lo <= dat(cur);
                end
                have_exp <= 1'b1;
            end
        end
    end

    integer i, k, berr = 0, aerr = 0, ok = 1;
    reg [22:0] b;
    initial begin
        for (i = 0; i < 4; i = i + 1) begin errs[i] = 0; vbp_errs[i] = 0; reads[i] = 0; end
        // pairs (even, even + 1): a block top-down (both bytes of each pair), page ends, banks
        for (i = 255; i >= 0; i = i - 1) begin wl[nw] = 2 * i; wl[nw + 1] = 2 * i + 1; nw = nw + 2; end
        wl[nw] = 23'h0001FE; wl[nw + 1] = 23'h0001FF; nw = nw + 2;    // last two columns of row 0
        wl[nw] = 23'h000200; wl[nw + 1] = 23'h000201; nw = nw + 2;    // first of row 1
        wl[nw] = 23'h1FFFFE; wl[nw + 1] = 23'h1FFFFF; nw = nw + 2;    // end of bank 0
        wl[nw] = 23'h200000; wl[nw + 1] = 23'h200001; nw = nw + 2;    // bank 1
        wl[nw] = 23'h7FFFFE; wl[nw + 1] = 23'h7FFFFF; nw = nw + 2;    // last bytes of the 8 MB
        while (nw < NW) begin
            b = rnd(0) & 23'h7FFFFE;
            wl[nw] = b; wl[nw + 1] = b + 23'd1; nw = nw + 2;
        end

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
            if (mem.mem[{1'b0, wl[i]}][15:8] !== dat(wl[i])) begin
                berr = berr + 1;
                if (berr <= 5) $display("backdoor: byte %h = %h, expected %h", wl[i], mem.mem[{1'b0, wl[i]}][15:8], dat(wl[i]));
            end
        $display("%t wrote %0d bytes, backdoor errors %0d", $realtime, NW, berr);
        for (i = 0; i < 64; i = i + 1) begin
            @(posedge clk);
            aux_req <= 1'b1; aux_addr <= wl[(i * 37) % NW];
            @(posedge clk);
            while (!aux_ack) @(posedge clk);
            aux_req <= 1'b0;
            while (!aux_valid) @(posedge clk);
            if (aux_q !== dat(wl[(i * 37) % NW])) begin
                aerr = aerr + 1;
                if (aerr <= 5 && !EXPECT_FAIL) $display("aux read %h got %h expected %h", wl[(i * 37) % NW], aux_q, dat(wl[(i * 37) % NW]));
            end
        end
        $display("%t 64 aux reads, %0d errors", $realtime, aerr);

        rom_en <= 1'b1;
        repeat (4) @(posedge clk_sys);              // (the core leaves reset well after this)
        ph = 1; mode = 1; cycles = 0;
        wait (cycles == 6000);
        k = n_late;
        $display("%t phase A: %0d reads (%0d SDRAM reads), %0d errors, %0d VBP-word errors, forced REF %0d, late %0d, REFs %0d, longest REF gap %0.0f ns",
                 $realtime, reads[1], n_reads, errs[1], vbp_errs[1], n_rf_forced, n_late, mem.n_ref, mem.max_ref_gap);
        ph = 2; mode = 2; cycles = 0;
        wait (cycles == 600);
        $display("%t phase B (a new byte every SA-1 cycle): %0d reads, %0d errors, forced REF %0d, late %0d, longest REF gap %0.0f ns",
                 $realtime, reads[2], errs[2], n_rf_forced, n_late - k, mem.max_ref_gap);
        mode = 1; cycles = 0;                       // 100 cycles to settle (counted as phase B:
        wait (cycles == 100);                       // a refresh forced there may still delay one)
        ph = 3; cycles = 0;
        wait (cycles == 2000);
        $display("%t phase A again: %0d reads, %0d errors, %0d VBP-word errors", $realtime, reads[3], errs[3], vbp_errs[3]);
        $display("model: %0d errors, %0d ACT, %0d READ, %0d words written, %0d REF, longest REF gap %0.0f ns; bus contention %0d; controller rf_max %0d cycles, stall %0d",
                 mem.errors, mem.n_act, mem.n_rd, mem.n_wr, mem.n_ref, mem.max_ref_gap, contention, rf_max, n_rf_stall);
        if (EXPECT_FAIL) begin
            ok = errs[1] + errs[3] > 0;
            $display("%s: CAPTURE_HALF %0d %s (phase A errors %0d)", ok ? "PASS" : "FAIL", CAPTURE_HALF,
                     ok ? "fails as expected" : "unexpectedly works", errs[1] + errs[3]);
        end else begin
            ok = errs[1] == 0 && errs[3] == 0 && vbp_errs[1] == 0 && vbp_errs[3] == 0 && berr == 0 &&
                 aerr == 0 && mem.errors == 0 && contention == 0 && mem.max_ref_gap <= 15625.0 &&
                 n_rf_forced > 0 && reads[1] > 3000;
            $display("%s: CAPTURE_HALF %0d, D_CLK %0.1f D_OUT %0.1f D_IN %0.1f", ok ? "PASS" : "FAIL",
                     CAPTURE_HALF, D_CLK, D_OUT, D_IN);
        end
        $finish;
    end
    initial begin #20_000_000; $display("FAIL: timeout"); $finish; end
endmodule
