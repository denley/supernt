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
//   - a log of the rest: consecutive transactions (writes or reads to consecutive addresses)
//     form a run; runs go into a ring of 16 entries {address, count, first byte, kind,
//     repeats, time}; a run identical to the newest entry (kind, address, count, first byte)
//     only bumps its repeat count (the status poll). Not logged, only counted: the UI loop
//     (0x1000_D120 writes, pad reads at 0x2000-0x200F) and the file.
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
    // log, read port (any clock, registered here on clk_vid): entry k of the newest 16
    // (0 = newest): {repeats[15:0], kind[1:0], t_ms[21:0], first byte[7:0], count[23:0], addr[31:0]}
    input  wire [3:0]  log_idx,
    output reg  [103:0] log_q,
    output reg  [31:0] n_log = 32'd0,       // runs logged (new entries)
    // counters (clk domain)
    output reg  [31:0] ms = 32'd0,          // milliseconds since configuration
    output reg  [31:0] n_stat = 32'd0,      // status reads (0x2xx4)
    output reg  [31:0] n_ui = 32'd0,        // UI loop writes (0x1000_D120)
    output reg  [31:0] n_padrd = 32'd0,     // pad register reads
    output reg  [31:0] n_data = 32'd0,      // data writes (A = 2), all
    output reg  [31:0] n_scr = 32'd0,       // screen bytes written
    output reg  [31:0] last_ui_ms = 32'd0,  // time of the newest UI loop write
    output reg  [31:0] addr = 32'd0         // the link address register
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
                end else if (is_ui) begin
                    n_ui <= n_ui + 32'd1;
                    last_ui_ms <= ms;
                end else begin
                    ev <= 1'b1; ev_kind <= 1'b0; ev_addr <= addr; ev_byte <= sd;
                end
                if (is_scr) begin
                    scr_we <= 1'b1; scr_wa <= addr[11:0]; scr_wd <= sd;
                    n_scr <= n_scr + 32'd1;
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
            else begin
                ev <= 1'b1; ev_kind <= 1'b1; ev_addr <= lat; ev_byte <= rdval(lat, pad_q, r2008);
            end
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
    reg        run_on = 1'b0;
    reg        run_kind = 1'b0;
    reg [31:0] run_addr = 32'd0;
    reg [23:0] run_cnt = 24'd0;
    reg [7:0]  run_first = 8'd0;
    reg [21:0] run_t = 22'd0;
    reg [31:0] last_act = 32'd0;
    wire cont = run_on && ev_kind == run_kind && ev_addr == run_addr + {8'd0, run_cnt} &&
                run_cnt != 24'hffffff;
    reg        flush = 1'b0;
    reg [87:0] flush_e;                 // {kind, t, first, count, addr} (1 + 22 + 8 + 24 + 32 = 87)
    always @(posedge clk) begin
        flush <= 1'b0;
        if (ev) begin
            last_act <= ms;
            if (cont) run_cnt <= run_cnt + 24'd1;
            else begin
                if (run_on) begin
                    flush <= 1'b1;
                    flush_e <= {1'b0, run_kind, run_t, run_first, run_cnt, run_addr};
                end
                run_on <= 1'b1; run_kind <= ev_kind; run_addr <= ev_addr; run_cnt <= 24'd1;
                run_first <= ev_byte; run_t <= ms[21:0];
            end
        end else if (run_on && ms - last_act > 32'd2) begin
            flush <= 1'b1;
            flush_e <= {1'b0, run_kind, run_t, run_first, run_cnt, run_addr};
            run_on <= 1'b0;
        end
    end
    // ring of 16 entries in registers (read from the overlay's clock: quasi-static)
    (* ramstyle = "logic" *) reg [103:0] ring [0:15];
    reg [3:0]   head = 4'd0;            // newest entry
    integer k;
    initial for (k = 0; k < 16; k = k + 1) ring[k] = 104'd0;
    // the newest entry's fields and repeat count are kept apart, so a flush needs no read of
    // the ring (a 16:1 mux) before its write
    reg [87:0]  last_e = 88'd0;
    reg [15:0]  last_rep = 16'd0;
    wire same = n_log != 0 && flush_e[86] == last_e[86] && flush_e[63:0] == last_e[63:0];
    wire [15:0] rep_next = last_rep == 16'hffff ? last_rep : last_rep + 16'd1;
    always @(posedge clk)
        if (flush) begin
            if (same) begin
                last_rep <= rep_next;
                ring[head][103:88] <= rep_next;
            end else begin
                ring[head + 4'd1] <= {16'd1, flush_e};
                head <= head + 4'd1;
                last_e <= flush_e;
                last_rep <= 16'd1;
                n_log <= n_log + 32'd1;
            end
        end
    always @(posedge clk_vid) log_q <= ring[head - log_idx];
endmodule
