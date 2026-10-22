// SPDX-License-Identifier: GPL-3.0-or-later
// PIC32 link slave + transaction logger (notes/pic-link.md). Implements the stock core's port
// as decoded from spc.cor: A[2:0] register select, /WR and /RD strobes (active low), 8-bit data.
//   write A=0/1/4/5: address byte 0/1/2/3      write A=2: data byte at ADDR, ADDR += 1
//   write A=3: latch ADDR (read prefetch), ADDR += 1
//   read: drive the byte for the latched address while /RD is low; afterwards latch ADDR and
//         ADDR += 1
// Reads answer like the stock core (notes/pic-link.md, "Status 0x2004_0000"): 0x2xx4_xxxx
// (bits 31-28 = 2, 19-16 = 4, the rest ignored) = {6'b0, PLL locked, bit 0}, everything else
// 0x00. The PIC polls 0x2004_0000 (two bytes) before it sends a file; v1's 02 00 kept it
// waiting. The decode gives 0x03 or, under another reading of one counter's clears, 0x02, so
// the answer steps through five candidates (cand_val), one per STEP_US window in which the PIC
// reads but writes fewer than 256 data bytes; it stays fixed once the PIC has written
// LOCK_BYTES data bytes after its first read (the answer worked).
//
// Every transaction is logged in compressed form: consecutive writes (or reads) to consecutive
// addresses extend one "run". A run is flushed when the next transaction doesn't continue it,
// or after ~1 ms of silence. A flushed run identical to the previous entry (kind, address,
// length, CRC) only bumps that entry's repeat count, so a polling loop takes one entry.
// Logs: all (1024 entries of 192 bits) and big (indices into `all` of write runs >= BIG
// bytes, 256 entries). Entry words: 0 start address; 1 byte count; 2 CRC-32 of the run's
// bytes (zlib/IEEE); 3 {2'b0, kind[1:0], first byte[7:0], first start time[19:0]};
// 4 repeats (1 = seen once); 5 last start time[19:0] (times in 1.024 ms units).
// kind: 0 = write run, 1 = read run (first byte = value we returned), 3 = write to A=6/7.
// A=3 latches end the current run but are not logged themselves (the next read run's address
// is the latched address), so a poll "address, A=3, read, read" merges into one entry.
module link_logger #(
    parameter integer BIG        = 32,
    parameter integer STEP_US    = 5000000,  // candidate step time (polling without writes)
    parameter integer LOCK_BYTES = 4096
) (
    input  wire        clk,             // 74.25 MHz
    input  wire [2:0]  a,               // AB20 AA20 AA19
    input  wire        n_rd,            // U21
    input  wire        n_wr,            // U22
    input  wire [7:0]  d_in,            // D7..D0 = AB21 AB22 AA22 Y21 Y22 W21 W22 V21
    input  wire        pll_locked,      // answered in bit 1 of 0x2004_0000
    output reg  [7:0]  d_out = 8'd0,
    output reg         d_oe = 1'b0,
    // display access: entry `idx` of the all log (sel 0) or of the big log (sel 1)
    input  wire        sel,
    input  wire [9:0]  idx,
    output reg  [191:0] entry,
    output reg  [9:0]  entry_idx,       // index in the all log of the entry shown
    output reg         entry_valid,
    // counters
    output reg  [31:0] n_wr_total = 0,  // A=2 data writes
    output reg  [31:0] n_rd_total = 0,
    output reg  [31:0] n_other = 0,     // address-byte, A=3 and A=6/7 writes
    output reg  [10:0] n_all = 0,       // entries in the all log
    output reg  [8:0]  n_big = 0,
    output reg  [10:0] first_rd = 11'h7ff, // all-log index of the first read run (7FF: none yet)
    output reg  [31:0] addr = 32'd0,
    output reg  [31:0] usec = 32'd0,
    output reg  [31:0] last_act = 32'd0, // time of the last strobe
    // handshake
    output reg  [2:0]  cand = 3'd0,     // 0x2004 answer candidate now in use
    output wire [7:0]  answer,          // its value
    output reg  [7:0]  n_steps = 8'd0,  // candidate steps so far
    output reg         cand_locked = 1'b0, // the PIC moved on: candidate fixed
    output reg  [31:0] n_wr_after = 0   // data bytes written after the first read
);
    // ------------------------------------------------------------ inputs: 2-FF synchronisers
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg [12:0] s1 = 13'h1800, s2 = 13'h1800;
    always @(posedge clk) begin
        s1 <= {n_rd, n_wr, a, d_in};
        s2 <= s1;
    end
    wire       rd_n = s2[12], wr_n = s2[11];
    wire [2:0] sa = s2[10:8];
    wire [7:0] sd = s2[7:0];
    reg rd_d = 1'b1, wr_d = 1'b1;
    always @(posedge clk) begin
        rd_d <= rd_n;
        wr_d <= wr_n;
    end
    wire wr_fall = wr_d && !wr_n;
    wire rd_fall = rd_d && !rd_n && wr_n;
    wire rd_rise = !rd_d && rd_n;

    // ------------------------------------------------------------ time base (~1 us)
    reg [6:0] udiv = 7'd0;
    wire      us_tick = udiv == 7'd73;
    always @(posedge clk)
        if (us_tick) begin
            udiv <= 7'd0;
            usec <= usec + 32'd1;
        end else
            udiv <= udiv + 7'd1;

    // ------------------------------------------------------------ status answers
    // candidates for 0x2xx4_xxxx (the same byte for every low address bit, as in spc.cor):
    // the two readings of the decode first (notes/pic-link.md, "Status 0x2004_0000"), then the
    // other bit patterns. v1 answered 02 at 0x2004_0000 but 00 at 0x2004_0001.
    function [7:0] cand_val(input [2:0] c, input lk);
        case (c)
            3'd0:    cand_val = {6'd0, lk, 1'b1};    // reconfig idle + locked (decode as is)
            3'd1:    cand_val = {6'd0, lk, 1'b0};    // ready flag low (lock timer reading)
            3'd2:    cand_val = 8'h01;
            3'd3:    cand_val = 8'h00;
            default: cand_val = 8'hFF;
        endcase
    endfunction
    assign answer = cand_val(cand, pll_locked);
    function [7:0] rdval(input [31:0] ad);
        if (ad[31:28] == 4'h2 && ad[19:16] == 4'h4) rdval = answer;
        else                                         rdval = 8'h00;
    endfunction

    // stepping: in each STEP_US window, if the PIC read something but wrote fewer than 256
    // data bytes, it is stuck: next candidate. Fixed once it has written LOCK_BYTES data
    // bytes after its first read (a file transfer).
    reg [31:0] win_us = 32'd0;
    reg [8:0]  win_wr = 9'd0;           // data writes in this window (saturating at 256)
    reg        win_rd = 1'b0;           // a read in this window
    always @(posedge clk) begin
        if (wr_fall && sa == 3'd2 && first_rd != 11'h7ff) n_wr_after <= n_wr_after + 32'd1;
        if (n_wr_after >= LOCK_BYTES) cand_locked <= 1'b1;
        if (us_tick && win_us == STEP_US - 1) begin
            win_us <= 32'd0;
            win_wr <= 9'd0;
            win_rd <= 1'b0;
            if (win_rd && !win_wr[8] && !cand_locked) begin
                cand <= cand == 3'd4 ? 3'd0 : cand + 3'd1;
                n_steps <= n_steps + 8'd1;
            end
        end else begin
            if (us_tick) win_us <= win_us + 32'd1;
            if (wr_fall && sa == 3'd2 && !win_wr[8]) win_wr <= win_wr + 9'd1;
            if (rd_fall) win_rd <= 1'b1;
        end
    end

    // ------------------------------------------------------------ the port
    reg [31:0] lat = 32'd0;             // latched (prefetch) address
    // events for the logger: kind, address, byte
    reg        ev = 1'b0;
    reg [1:0]  ev_kind;
    reg [31:0] ev_addr;
    reg [7:0]  ev_byte;
    always @(posedge clk) begin
        ev <= 1'b0;
        if (wr_fall) begin
            last_act <= usec;
            case (sa)
                3'd0: begin addr[7:0]   <= sd; n_other <= n_other + 1; end
                3'd1: begin addr[15:8]  <= sd; n_other <= n_other + 1; end
                3'd4: begin addr[23:16] <= sd; n_other <= n_other + 1; end
                3'd5: begin addr[31:24] <= sd; n_other <= n_other + 1; end
                3'd2: begin
                    ev <= 1'b1; ev_kind <= 2'd0; ev_addr <= addr; ev_byte <= sd;
                    addr <= addr + 32'd1;
                    n_wr_total <= n_wr_total + 1;
                end
                3'd3: begin
                    ev <= 1'b1; ev_kind <= 2'd2; ev_addr <= addr; ev_byte <= 8'd0;
                    lat <= addr;
                    addr <= addr + 32'd1;
                    n_other <= n_other + 1;
                end
                default: begin
                    ev <= 1'b1; ev_kind <= 2'd3; ev_addr <= {29'd0, sa}; ev_byte <= sd;
                    n_other <= n_other + 1;
                end
            endcase
        end
        if (rd_fall) begin
            last_act <= usec;
            d_out <= rdval(lat);
            d_oe  <= 1'b1;
            ev <= 1'b1; ev_kind <= 2'd1; ev_addr <= lat; ev_byte <= rdval(lat);
            n_rd_total <= n_rd_total + 1;
        end
        if (rd_rise && d_oe) begin
            d_oe <= 1'b0;
            lat  <= addr;
            addr <= addr + 32'd1;
        end
        if (!wr_n) d_oe <= 1'b0;        // never drive during a write
    end

    // ------------------------------------------------------------ run compression
    reg        run_on = 1'b0;
    reg [1:0]  run_kind;
    reg [31:0] run_addr, run_t;
    reg [21:0] run_cnt;
    reg [7:0]  run_first;
    reg [31:0] run_crc;
    reg        flush = 1'b0;
    reg [127:0] flush_e;                // {w3, w2, w1, w0}

    function [31:0] crc8(input [31:0] c, input [7:0] b);   // reflected CRC-32, one byte
        integer i;
        reg [31:0] r;
        begin
            r = c ^ {24'd0, b};
            for (i = 0; i < 8; i = i + 1)
                r = r[0] ? (r >> 1) ^ 32'hEDB88320 : r >> 1;
            crc8 = r;
        end
    endfunction

    wire [127:0] entry_now = {2'b00, run_kind, run_first, run_t[29:10], ~run_crc, 10'd0, run_cnt,
                              run_addr};
    wire cont = run_on && ev_kind == run_kind && (ev_kind == 2'd0 || ev_kind == 2'd1) &&
                ev_addr == run_addr + {10'd0, run_cnt} && run_cnt != 22'h3fffff;
    wire idle_out = run_on && (usec - last_act) > 32'd1000;
    always @(posedge clk) begin
        flush <= 1'b0;
        if (ev) begin
            if (cont) begin
                run_cnt <= run_cnt + 22'd1;
                run_crc <= crc8(run_crc, ev_byte);
            end else begin
                if (run_on) begin
                    flush   <= 1'b1;
                    flush_e <= entry_now;
                end
                run_on    <= ev_kind != 2'd2;  // A=3 latches end a run but aren't logged
                run_kind  <= ev_kind;
                run_addr  <= ev_addr;
                run_cnt   <= 22'd1;
                run_first <= ev_byte;
                run_crc   <= crc8(32'hFFFFFFFF, ev_byte);
                run_t     <= usec;
            end
        end else if (idle_out) begin
            flush   <= 1'b1;
            flush_e <= entry_now;
            run_on  <= 1'b0;
        end
    end

    // ------------------------------------------------------------ logs
    (* ramstyle = "M10K" *) reg [191:0] log_all [0:1023];
    (* ramstyle = "M10K" *) reg [9:0]   log_big [0:255];
    reg [127:0] last_e = 128'd0;        // words 0-3 of the newest entry
    reg [31:0]  last_rep = 32'd0;
    wire [21:0] f_cnt  = flush_e[53:32];
    wire [1:0]  f_kind = flush_e[125:124];
    // identical to the newest entry apart from the times (bits 115:96 of word 3)
    wire same = n_all != 11'd0 && flush_e[95:0] == last_e[95:0] &&
                flush_e[127:116] == last_e[127:116];
    always @(posedge clk) begin
        if (flush && same) begin
            last_rep <= last_rep + 32'd1;
            log_all[n_all[9:0] - 10'd1] <= {12'd0, flush_e[115:96], last_rep + 32'd1, last_e};
        end else if (flush && !n_all[10]) begin
            last_e   <= flush_e;
            last_rep <= 32'd1;
            log_all[n_all[9:0]] <= {12'd0, flush_e[115:96], 32'd1, flush_e};
            n_all <= n_all + 11'd1;
            if (f_kind == 2'd1 && first_rd == 11'h7ff) first_rd <= n_all;
            if (f_kind == 2'd0 && f_cnt >= BIG && !n_big[8]) begin
                log_big[n_big[7:0]] <= n_all[9:0];
                n_big <= n_big + 9'd1;
            end
        end
    end
    // display read: big index first (1 clock), then the all log
    reg [9:0]   bi_q;
    reg         sel_d, sel_dd;
    reg [9:0]   idx_d, idx_dd, ai;
    reg [191:0] q_all;
    always @(posedge clk) begin
        bi_q   <= log_big[idx[7:0]];
        sel_d  <= sel;
        idx_d  <= idx;
        ai     <= sel_d ? bi_q : idx_d;
        sel_dd <= sel_d;
        idx_dd <= idx_d;
        q_all  <= log_all[sel_d ? bi_q : idx_d];
        entry  <= q_all;
        entry_idx <= ai;
        entry_valid <= sel_dd ? ({2'd0, idx_dd} < {2'd0, n_big} && idx_dd < 10'd256)
                              : ({1'b0, idx_dd} < n_all);
    end
endmodule
