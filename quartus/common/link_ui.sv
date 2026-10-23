// SPDX-License-Identifier: GPL-3.0-or-later
// PIC32 link slave for quartus/snes_load (notes/snes-load.md; protocol notes/pic-link.md): the
// stock core's port as link_logger.sv/link_loader.sv implement it (A[2:0] register select, /WR
// and /RD strobes, 32-bit address register written a byte at a time at A = 0/1/4/5, data at
// A = 2 with post-increment, A = 3 latch + increment, reads drive the byte for the latched
// address while /RD is low). What it answers and keeps:
//   - status 0x2xx4_xxxx = 0x02 from power-up (the console's PIC wants 02 02, hwtest v3-v6);
//   - pad 1 like the stock core (notes/controllers.md, "Link registers"): 0x2000 = buttons 7-0
//     (RIGHT LEFT DOWN UP START SELECT Y B), 0x2001 = R L X A in bits 3-0, 0x2008 = 01 for a
//     standard pad (bit 1 = not a standard pad, bit 0 = not "device A"); the pad bits come in
//     as read from the port (raw serial order, 1 = pressed), straight through as the stock
//     core passes them; `pad_en` = 0 answers "standard pad, nothing pressed" (while a game runs,
//     so its buttons don't drive the player's file browser); everything else reads 0x00;
//   - the player's screen: writes to 0x1018_0000-0FFF (64 x 32 cells of {character, attribute})
//     go to a 4 KB RAM whose second port (clk_vid) the overlay reads as 16-bit cells;
//   - the file: data writes at 0x0000_FF00-0x0FFF_FFFF (the SPC player sends the file there,
//     link address 0xFF00 + file offset) come out on f_go/f_addr/f_data for the ROM loader;
//   - a log of everything but the file bytes (v2: reads, the UI loop and pad reads included):
//     consecutive transactions (writes or reads to consecutive addresses) form a run; runs go
//     into a 512-entry M10K log with times (see "Log" below); the file is only counted.
// Port timing: 2-FF synchronisers on clk (>= 40 MHz; 107.2 MHz in snes_load); reads are ignored until
// the port is armed (both strobes high for 1 us, or a write strobe seen), since the PIC holds
// /RD low until it sets up its port.
module link_ui #(
    parameter integer CLK_KHZ = 107210      // clk in kHz (ms tick)
) (
    input  wire        clk,
    input  wire [2:0]  a,
    input  wire        n_rd,
    input  wire        n_wr,
    input  wire [7:0]  d_in,
    output reg  [7:0]  d_out = 8'd0,
    output reg         d_oe = 1'b0,
    // pad (clk domain, synchronised by the caller)
    input  wire [11:0] pad,                 // raw bits 11-0 = R L X A RIGHT LEFT DOWN UP START SELECT Y B
    input  wire        pad_std,             // a standard pad answers
    input  wire        pad_en,              // 1: pass the pad to the PIC
    // file stream
    output reg         f_go = 1'b0,
    output reg  [31:0] f_addr = 32'd0,
    output reg  [7:0]  f_data = 8'd0,
    // screen, read port (clk_vid): cell w = {attribute, character} of bytes 2w, 2w + 1
    input  wire        clk_vid,
    input  wire [10:0] scr_addr,
    output reg  [15:0] scr_q,
    // log (see below), read port on clk_vid: entry log_idx (physical index 0-511), registered
    input  wire [8:0]  log_idx,
    output reg  [136:0] log_q,
    output reg  [31:0] n_log = 32'd0,       // entries made
    output reg  [26:0] newest = 27'd0,      // indices of the 3 newest entries (newest in [8:0])
    output wire [8:0]  log_a_n,             // entries in 0-383 (after the first file byte)
    // counters (clk domain)
    output reg  [31:0] ms = 32'd0,          // milliseconds since configuration
    output reg  [31:0] n_stat = 32'd0,      // status reads (0x2xx4)
    output reg  [31:0] n_ui = 32'd0,        // UI loop writes (0x1000_D120)
    output reg  [31:0] n_padrd = 32'd0,     // pad register reads
    output reg  [31:0] n_data = 32'd0,      // data writes (A = 2), all
    output reg  [31:0] n_scr = 32'd0,       // screen bytes written
    output reg  [31:0] last_ui_ms = 32'd0,  // time of the newest UI loop write
    output reg  [31:0] addr = 32'd0,        // the link address register
    output reg  [31:0] n_rdall = 32'd0,     // reads (all)
    output reg  [31:0] last_txn_ms = 32'd0, // time of the newest transaction (not file bytes)
    output reg  [31:0] last_scr_ms = 32'd0, // time of the newest screen write
    output reg  [7:0]  r21 = 8'd0,          // the newest byte written to 0x1000_0021
    output reg  [31:0] r21_ms = 32'd0,      // and when
    output reg  [15:0] n_r21 = 16'd0
);
    // ------------------------------------------------------------ port
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

    // ms and us ticks
    reg [16:0] mdiv = 17'd0;
    wire       ms_tick = mdiv == CLK_KHZ - 1;
    reg [6:0]  udiv = 7'd0;
    wire       us_tick = udiv == (CLK_KHZ + 500) / 1000 - 1;
    always @(posedge clk) begin
        mdiv <= ms_tick ? 17'd0 : mdiv + 17'd1;
        if (ms_tick) ms <= ms + 32'd1;
        udiv <= us_tick ? 7'd0 : udiv + 7'd1;
    end

    reg       armed = 1'b0;
    reg [3:0] hi_us = 4'd0;
    wire      arm_now = armed || (wr_d && !wr_n && rd_n);
    wire      wr_fall = arm_now && wr_d && !wr_n;
    wire      rd_fall = armed && rd_d && !rd_n && wr_n;
    wire      rd_rise = !rd_d && rd_n;
    always @(posedge clk)
        if (!armed) begin
            if (!rd_n || !wr_n) hi_us <= 4'd0;
            else if (us_tick) hi_us <= hi_us + 4'd1;
            if (hi_us == 4'd1 || arm_now) armed <= 1'b1;
        end

    reg  [31:0] lat = 32'd0;            // latched (prefetch) address
    wire [11:0] pad_q = pad_en ? pad : 12'd0;
    wire [7:0]  r2008 = pad_en ? {6'd0, !pad_std, !pad_std} : 8'h01;
    // (the pad values are arguments: Quartus doesn't see module-level signals read inside a
    // function, warning 10036)
    function [7:0] rdval(input [31:0] ad, input [11:0] pq, input [7:0] r8);
        if (ad[31:28] != 4'h2)        rdval = 8'h00;
        else case (ad[19:16])
            4'h0:    rdval = pq[7:0];
            4'h1:    rdval = {4'd0, pq[11:8]};
            4'h4:    rdval = 8'h02;
            4'h8:    rdval = r8;
            default: rdval = 8'h00;
        endcase
    endfunction
    wire is_pad = lat[31:28] == 4'h2 && lat[19:16] != 4'h4 && lat[19:16] <= 4'h9;
    wire is_ui  = addr == 32'h1000_D120;
    wire is_scr = addr[31:12] == 20'h10180;
    wire is_file = addr[31:28] == 4'h0 && addr >= 32'h0000_FF00;

    // events for the log: {kind, address, byte}
    reg        ev = 1'b0;
    reg        ev_kind = 1'b0;          // 0 write, 1 read
    reg [31:0] ev_addr = 32'd0;
    reg [7:0]  ev_byte = 8'd0;
    reg        scr_we = 1'b0;
    reg [11:0] scr_wa = 12'd0;
    reg [7:0]  scr_wd = 8'd0;
    always @(posedge clk) begin
        ev <= 1'b0;
        f_go <= 1'b0;
        scr_we <= 1'b0;
        if (wr_fall) case (sa)
            3'd0: addr[7:0]   <= sd;
            3'd1: addr[15:8]  <= sd;
            3'd4: addr[23:16] <= sd;
            3'd5: addr[31:24] <= sd;
            3'd2: begin
                n_data <= n_data + 32'd1;
                if (is_file) begin
                    f_go <= 1'b1; f_addr <= addr; f_data <= sd;
                end else begin
                    ev <= 1'b1; ev_kind <= 1'b0; ev_addr <= addr; ev_byte <= sd;
                    last_txn_ms <= ms;
                end
                if (is_ui) begin
                    n_ui <= n_ui + 32'd1;
                    last_ui_ms <= ms;
                end
                if (addr == 32'h1000_0021) begin
                    r21 <= sd; r21_ms <= ms; n_r21 <= n_r21 + 16'd1;
                end
                if (is_scr) begin
                    scr_we <= 1'b1; scr_wa <= addr[11:0]; scr_wd <= sd;
                    n_scr <= n_scr + 32'd1;
                    last_scr_ms <= ms;
                end
                addr <= addr + 32'd1;
            end
            3'd3: begin lat <= addr; addr <= addr + 32'd1; end
            default: ;
        endcase
        if (rd_fall) begin
            d_out <= rdval(lat, pad_q, r2008);
            d_oe  <= 1'b1;
            if (lat[31:28] == 4'h2 && lat[19:16] == 4'h4) n_stat <= n_stat + 32'd1;
            if (is_pad) n_padrd <= n_padrd + 32'd1;
            n_rdall <= n_rdall + 32'd1;
            last_txn_ms <= ms;
            ev <= 1'b1; ev_kind <= 1'b1; ev_addr <= lat; ev_byte <= rdval(lat, pad_q, r2008);
        end
        if (rd_rise && d_oe) begin
            d_oe <= 1'b0;
            lat  <= addr;
            addr <= addr + 32'd1;
        end
        if (!wr_n) d_oe <= 1'b0;        // never drive during a write
    end

    // ------------------------------------------------------------ screen RAM (two byte lanes)
    (* ramstyle = "M10K, no_rw_check" *) reg [7:0] scr_lo [0:2047];
    (* ramstyle = "M10K, no_rw_check" *) reg [7:0] scr_hi [0:2047];
    // synthesis translate_off
    integer ii;
    initial for (ii = 0; ii < 2048; ii = ii + 1) begin scr_lo[ii] = 8'd0; scr_hi[ii] = 8'd0; end
    // synthesis translate_on
    always @(posedge clk) begin
        if (scr_we && !scr_wa[0]) scr_lo[scr_wa[11:1]] <= scr_wd;
        if (scr_we &&  scr_wa[0]) scr_hi[scr_wa[11:1]] <= scr_wd;
    end
    always @(posedge clk_vid) scr_q <= {scr_hi[scr_addr], scr_lo[scr_addr]};

    // ------------------------------------------------------------ run compression and log
    // A run = consecutive transactions of one kind at consecutive addresses; it ends at the
    // first transaction that doesn't continue it or after 2 ms without any.
    reg        run_on = 1'b0;
    reg        run_kind = 1'b0;
    reg [31:0] run_addr = 32'd0;
    reg [15:0] run_cnt = 16'd0;
    reg [7:0]  run_first = 8'd0;
    reg [23:0] run_t = 24'd0;
    reg [31:0] last_act = 32'd0;
    wire cont = run_on && ev_kind == run_kind && ev_addr == run_addr + {16'd0, run_cnt} &&
                run_cnt != 16'hffff;
    reg        flush = 1'b0;
    reg        fl_kind = 1'b0;
    reg [31:0] fl_addr = 32'd0;
    reg [15:0] fl_cnt = 16'd0;
    reg [7:0]  fl_d0 = 8'd0;
    reg [23:0] fl_t = 24'd0;
    always @(posedge clk) begin
        flush <= 1'b0;
        if (ev) begin
            last_act <= ms;
            if (cont) run_cnt <= run_cnt + 16'd1;
            else begin
                if (run_on) begin
                    flush <= 1'b1;
                    {fl_kind, fl_addr, fl_cnt, fl_d0, fl_t} <= {run_kind, run_addr, run_cnt, run_first, run_t};
                end
                run_on <= 1'b1; run_kind <= ev_kind; run_addr <= ev_addr; run_cnt <= 16'd1;
                run_first <= ev_byte; run_t <= ms[23:0];
            end
        end else if (run_on && ms - last_act > 32'd2) begin
            flush <= 1'b1;
            {fl_kind, fl_addr, fl_cnt, fl_d0, fl_t} <= {run_kind, run_addr, run_cnt, run_first, run_t};
            run_on <= 1'b0;
        end
    end

    // Log: 512 entries in M10K, {kind, seq[15:0], repeats[15:0], t_last[23:0], t_first[23:0],
    // first byte, count[15:0], address} (137 bits). Before the first file byte new entries go to
    // a ring at 384-511; from the first file byte on to 0-383 in order until those are full,
    // then to the ring again. A run equal (kind, address, count, first byte) to one of the 8
    // newest entries only updates that entry (repeats + 1, t_last), so a loop of a few different
    // runs (the UI loop, the status poll) stays a few entries.
    (* ramstyle = "M10K, no_rw_check" *) reg [136:0] logm [0:511];
    integer li, lj, lk;
    // synthesis translate_off
    initial for (li = 0; li < 512; li = li + 1) logm[li] = 137'd0;
    // synthesis translate_on
    reg         lw = 1'b0;
    reg  [8:0]  lw_a = 9'd0;
    reg  [136:0] lw_d = 137'd0;
    always @(posedge clk) if (lw) logm[lw_a] <= lw_d;
    always @(posedge clk_vid) log_q <= logm[log_idx];

    reg         mark = 1'b0;            // the first file byte has come
    reg  [8:0]  a_n = 9'd0;             // entries in 0-383
    reg  [6:0]  ring_p = 7'd0;          // next ring slot (384 + ring_p)
    reg  [56:0] cam_sig [0:7];          // {kind, address, count, first byte}
    reg  [8:0]  cam_idx [0:7];
    reg  [15:0] cam_rep [0:7], cam_seq [0:7];
    reg  [23:0] cam_tf [0:7];
    reg  [7:0]  cam_v = 8'd0;
    initial for (li = 0; li < 8; li = li + 1) begin
        cam_sig[li] = 57'd0; cam_idx[li] = 9'd0; cam_rep[li] = 16'd0; cam_seq[li] = 16'd0; cam_tf[li] = 24'd0;
    end
    wire [56:0] fl_sig = {fl_kind, fl_addr, fl_cnt, fl_d0};
    reg  [2:0]  hit_j;
    reg         hit;
    always @(*) begin
        hit = 1'b0; hit_j = 3'd0;
        for (lj = 7; lj >= 0; lj = lj - 1)
            if (cam_v[lj] && cam_sig[lj] == fl_sig) begin hit = 1'b1; hit_j = lj[2:0]; end
    end
    wire [8:0]  new_idx = mark && a_n != 9'd384 ? a_n : {2'b11, ring_p};
    // (the compare takes a cycle: flushes come >= 2 cycles apart, transactions do)
    reg         flush_d = 1'b0, hit_q = 1'b0;
    reg  [2:0]  hit_jq = 3'd0;
    always @(posedge clk) begin
        flush_d <= flush;
        hit_q <= hit;
        hit_jq <= hit_j;
    end
    wire [15:0] rep_q = cam_rep[hit_jq] == 16'hffff ? 16'hffff : cam_rep[hit_jq] + 16'd1;
    always @(posedge clk) begin
        lw <= 1'b0;
        if (f_go) mark <= 1'b1;
        if (flush_d) begin
            lw <= 1'b1;
            if (hit_q) begin
                lw_a <= cam_idx[hit_jq];
                lw_d <= {fl_kind, cam_seq[hit_jq], rep_q, fl_t, cam_tf[hit_jq], fl_d0, fl_cnt, fl_addr};
                cam_rep[hit_jq] <= rep_q;
            end else begin
                lw_a <= new_idx;
                lw_d <= {fl_kind, n_log[15:0], 16'd1, fl_t, fl_t, fl_d0, fl_cnt, fl_addr};
                if (mark && a_n != 9'd384) a_n <= a_n + 9'd1;
                else ring_p <= ring_p + 7'd1;
                n_log <= n_log + 32'd1;
                newest <= {newest[17:0], new_idx};
                for (lk = 7; lk > 0; lk = lk - 1) begin
                    cam_sig[lk] <= cam_sig[lk - 1]; cam_idx[lk] <= cam_idx[lk - 1];
                    cam_rep[lk] <= cam_rep[lk - 1]; cam_seq[lk] <= cam_seq[lk - 1];
                    cam_tf[lk] <= cam_tf[lk - 1];
                end
                cam_v <= {cam_v[6:0], 1'b1};
                cam_sig[0] <= fl_sig; cam_idx[0] <= new_idx; cam_rep[0] <= 16'd1;
                cam_seq[0] <= n_log[15:0]; cam_tf[0] <= fl_t;
            end
        end
    end
    assign log_a_n = a_n;
endmodule
