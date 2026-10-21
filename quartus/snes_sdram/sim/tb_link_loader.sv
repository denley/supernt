// SPDX-License-Identifier: GPL-3.0-or-later
// make sim-link-loader: quartus/common/link_loader.sv + sdram_rom.sv (ROM reads off, as while
// loading) + the timed SDRAM model, driven by a PIC32 stand-in on the link (PMP-style strobes,
// 120 ns /WR low, 80 ns between accesses). The SDRAM is prefilled (backdoor) with a pattern so
// read-modify-write is visible. Transfers (window = link 0x0100_0000 + 64 KB -> SDRAM word
// 0x123400):
//   1. 300 bytes from offset 0x100 (even start/end: whole words only)
//   2. 7 bytes from 0x301 (odd start: high byte alone, merged with the old low byte)
//   3. 5 bytes from 0x400 (odd end: the last low byte flushed after the idle time)
//   4. 3 bytes from 0x500, a new address 0x503, 3 more: the chunk boundary pairs up without RMW
//   5. bytes just below the window and at its end (ignored), address-latch (A=3) and A=6 writes
//   6. a 4 KB block from 0xF000 (throughput, no FIFO drops)
// Then every byte of the window region is compared with the expected image, and the counters
// (bytes, words, read-modify-writes, drops) with the expected values. Prints PASS/FAIL.
`timescale 1ns/1ps
module tb_link_loader;
    localparam real   TM = 1000.0 / 85.76784;
    localparam [31:0] BASE = 32'h0100_0000;
    localparam [23:0] SDB = 24'h123400;
    reg clk = 0;
    always #(TM / 2) clk = ~clk;

    // link
    reg  [2:0] la = 0;
    reg        nrd = 1, nwr = 1;
    reg  [7:0] ld = 0;
    wire [7:0] lq;
    wire       loe;
    // controller <-> loader
    wire        wr_req, wr_ack, rd_req, rd_ack, rd_valid, ready, busy;
    wire [23:0] wr_addr, rd_addr;
    wire [15:0] wr_data, rd_q;
    wire [31:0] laddr, n_bytes, n_words, n_partial, n_dropped;
    link_loader #(.WIN_BASE(BASE), .WIN_SIZE(32'h10000), .SD_BASE(SDB), .IDLE_FLUSH(2000)) ld_i (
        .clk(clk), .a(la), .n_rd(nrd), .n_wr(nwr), .d_in(ld), .d_out(lq), .d_oe(loe), .flush(1'b0),
        .wr_req(wr_req), .wr_addr(wr_addr), .wr_data(wr_data), .wr_ack(wr_ack),
        .rd_req(rd_req), .rd_addr(rd_addr), .rd_ack(rd_ack), .rd_valid(rd_valid), .rd_q(rd_q),
        .addr(laddr), .n_bytes(n_bytes), .n_words(n_words), .n_partial(n_partial),
        .n_dropped(n_dropped), .busy(busy));
    wire        sd_clk, cs_n, ras_n, cas_n, we_n, dq_oe;
    wire [11:0] a;
    wire [1:0]  ba;
    wire [15:0] dq_out;
    reg  [15:0] dq_in_p = 16'hzzzz;
    sdram_rom #(.INIT_CYCLES(200)) ctl (
        .clk(clk), .clk_sd(clk), .clk_cap(clk), .reset(1'b0), .ready(ready), .sys_tog(1'b0),
        .rom_en(1'b0), .rom_addr(24'd0), .rom_word(1'b1), .rom_q(), .rfsh_ok(1'b1),
        .wr_req(wr_req), .wr_addr(wr_addr), .wr_data(wr_data), .wr_ack(wr_ack),
        .aux_req(rd_req), .aux_addr(rd_addr), .aux_ack(rd_ack), .aux_valid(rd_valid), .aux_q(rd_q),
        .sd_clk(sd_clk), .sd_cs_n(cs_n), .sd_ras_n(ras_n), .sd_cas_n(cas_n), .sd_we_n(we_n),
        .sd_a(a), .sd_ba(ba), .sd_dq_in(dq_in_p), .sd_dq_out(dq_out), .sd_dq_oe(dq_oe),
        .n_rf_forced(), .n_rf_stall(), .n_late(), .rf_max());
    // board delays as tb_sdram_rom.sv
    reg        sclk_p = 1'b1;
    reg [17:0] cmd_p = 18'h3ffff;
    reg [15:0] dqo_p = 16'd0;
    reg        oe_p = 1'b0;
    always @(sd_clk) sclk_p <= #(3.5) sd_clk;
    always @(cs_n, ras_n, cas_n, we_n, a, ba) cmd_p <= #(3.5) {cs_n, ras_n, cas_n, we_n, a, ba};
    always @(dq_out, dq_oe) begin dqo_p <= #(3.5) dq_out; oe_p <= #(3.5) dq_oe; end
    tri [15:0] dq_bus;
    assign dq_bus = oe_p ? dqo_p : 16'hzzzz;
    always @(dq_bus) dq_in_p <= #(1.0) dq_bus;
    is42s_model mem (.clk(sclk_p), .cs_n(cmd_p[17]), .ras_n(cmd_p[16]), .cas_n(cmd_p[15]),
                     .we_n(cmd_p[14]), .a(cmd_p[13:2]), .ba(cmd_p[1:0]), .dq(dq_bus));

    // expected image of window offsets 0..0xFFFF (bytes)
    reg [7:0] img [0:65535];
    integer i, errs = 0, nb_exp = 0;
    function [15:0] pre(input [23:0] w); pre = w[15:0] ^ 16'hA55A; endfunction

    task wr_strobe(input [2:0] r, input [7:0] v);
        begin
            la = r; ld = v; #40; nwr = 0; #120; nwr = 1; #80;
        end
    endtask
    task set_addr(input [31:0] ad);
        begin
            wr_strobe(0, ad[7:0]); wr_strobe(1, ad[15:8]); wr_strobe(4, ad[23:16]); wr_strobe(5, ad[31:24]);
        end
    endtask
    function [7:0] bval(input [31:0] ad); bval = ad[7:0] ^ ad[15:8] ^ 8'h3C; endfunction
    task send(input [31:0] ad, input integer n);   // n data bytes from link address ad
        integer k;
        begin
            set_addr(ad);
            for (k = 0; k < n; k = k + 1) begin
                wr_strobe(2, bval(ad + k));
                if (ad + k - BASE < 32'h10000) begin img[ad + k - BASE] = bval(ad + k); nb_exp = nb_exp + 1; end
            end
        end
    endtask

    integer w;
    initial begin
        wait (ready);
        for (w = 0; w < 32768; w = w + 1) begin
            mem.mem[SDB + w] = pre(SDB + w);
            img[2 * w] = pre(SDB + w) & 8'hff; img[2 * w + 1] = pre(SDB + w) >> 8;
        end
        send(BASE + 32'h100, 300);
        send(BASE + 32'h301, 7);
        send(BASE + 32'h400, 5);
        #30000;                                   // idle flush of the last half word
        send(BASE + 32'h500, 3);
        send(BASE + 32'h503, 3);
        send(BASE - 32'd2, 4);                    // 2 below the window, 2 at its start
        send(BASE + 32'hFFFE, 4);                 // 2 at its end, 2 beyond
        wr_strobe(3, 8'h00); wr_strobe(6, 8'h55);  // latch, unused register
        send(BASE + 32'hF000, 4096);
        #30000;
        wait (!busy);
        #2000;
        for (i = 0; i < 65536; i = i + 1)
            if (((mem.mem[SDB + i / 2] >> (8 * (i % 2))) & 8'hff) !== img[i]) begin
                errs = errs + 1;
                if (errs <= 10) $display("offset %h: SDRAM %h expected %h", i,
                                         (mem.mem[SDB + i / 2] >> (8 * (i % 2))) & 8'hff, img[i]);
            end
        $display("bytes in window %0d (expected %0d), words written %0d, read-modify-write %0d, dropped %0d, model errors %0d, byte mismatches %0d",
                 n_bytes, nb_exp, n_words, n_partial, n_dropped, mem.errors, errs);
        // words: 150 + 4 + 3 + 3 (0x502/0x503 paired across the chunk) + 1 (offsets 0/1) + 1
        // (0xFFFE/F) + 2048 = 2210; read-modify-write only for 0x301 (high byte alone) and 0x404
        // (low byte alone, idle flush)
        if (errs == 0 && n_bytes == nb_exp && n_words == 2210 && n_partial == 2 && n_dropped == 0 &&
            mem.errors == 0)
            $display("PASS: link loader");
        else
            $display("FAIL: link loader");
        $finish;
    end
    initial begin #50_000_000; $display("FAIL: timeout"); $finish; end
endmodule
