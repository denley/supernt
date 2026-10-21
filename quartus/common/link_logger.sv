// SPDX-License-Identifier: GPL-3.0-or-later
// PIC32 link slave + transaction logger (notes/pic-link.md). Implements the stock core's port
// as decoded from spc.cor: A[2:0] register select, /WR and /RD strobes (active low), 8-bit data.
//   write A=0/1/4/5: address byte 0/1/2/3      write A=2: data byte at ADDR, ADDR += 1
//   write A=3: latch ADDR (read prefetch), ADDR += 1
//   read: drive the byte for the latched address (stock constants, below) while /RD is low;
//         afterwards latch ADDR and ADDR += 1
// Every transaction is logged in compressed form: consecutive writes (or reads) to consecutive
// addresses extend one "run". A run is flushed to the logs when the next transaction doesn't
// continue it, or after ~1 ms of silence. Logs (1024 x 128 bits each):
//   all  - every run, in order          big - runs of >= BIG bytes        rd - read runs
// Entry: word 0 = start address, word 1 = byte count, word 2 = CRC-32 of the run's bytes
// (zlib/IEEE), word 3 = {2'b0, kind[1:0], first byte[7:0], start time in 1.024 ms units[19:0]}.
// kind: 0 = write run, 1 = read run, 2 = A=3 latch, 3 = write to A=6/7.
module link_logger #(
    parameter integer BIG = 32
) (
    input  wire        clk,             // 74.25 MHz
    input  wire [2:0]  a,               // AB20 AA20 AA19
    input  wire        n_rd,            // U21
    input  wire        n_wr,            // U22
    input  wire [7:0]  d_in,            // D7..D0 = AB21 AB22 AA22 Y21 Y22 W21 W22 V21
    output reg  [7:0]  d_out = 8'd0,
    output reg         d_oe = 1'b0,
    // display access: row r of log `sel` (0 all, 1 big, 2 rd)
    input  wire [1:0]  sel,
    input  wire [9:0]  idx,
    output reg  [127:0] entry,
    output reg         entry_valid,
    // counters
    output reg  [31:0] n_wr_total = 0,  // A=2 data writes
    output reg  [31:0] n_rd_total = 0,
    output reg  [31:0] n_other = 0,     // address-byte, A=3 and A=6/7 writes
    output reg  [10:0] n_all = 0, n_big = 0, n_rdlog = 0,
    output reg  [31:0] addr = 32'd0,
    output reg  [31:0] usec = 32'd0,
    output reg  [31:0] last_act = 32'd0 // time of the last strobe
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
    always @(posedge clk)
        if (udiv == 7'd73) begin
            udiv <= 7'd0;
            usec <= usec + 32'd1;
        end else
            udiv <= udiv + 7'd1;

    // ------------------------------------------------------------ the port
    reg [31:0] lat = 32'd0;             // latched (prefetch) address
    function [7:0] rdval(input [31:0] ad);   // stock core's read constants (notes/pic-link.md)
        case (ad)
            32'h2004_0000: rdval = 8'h02;    // bit 1: PLL locked
            32'h2008_0000: rdval = 8'h03;    // bit 0 = 1, bit 1 unknown (1 here)
            32'h2009_0000: rdval = 8'h64;    // bits 6, 5, 2
            default:       rdval = 8'h00;
        endcase
    endfunction

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
    reg [127:0] flush_e;

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
                run_on    <= 1'b1;
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
    (* ramstyle = "M10K" *) reg [127:0] log_all [0:1023];
    (* ramstyle = "M10K" *) reg [127:0] log_big [0:1023];
    (* ramstyle = "M10K" *) reg [127:0] log_rd  [0:1023];
    wire [21:0] f_cnt  = flush_e[53:32];
    wire [1:0]  f_kind = flush_e[125:124];
    always @(posedge clk) begin
        if (flush && !n_all[10]) begin
            log_all[n_all[9:0]] <= flush_e;
            n_all <= n_all + 11'd1;
        end
        if (flush && f_kind == 2'd0 && f_cnt >= BIG && !n_big[10]) begin
            log_big[n_big[9:0]] <= flush_e;
            n_big <= n_big + 11'd1;
        end
        if (flush && f_kind == 2'd1 && !n_rdlog[10]) begin
            log_rd[n_rdlog[9:0]] <= flush_e;
            n_rdlog <= n_rdlog + 11'd1;
        end
    end
    reg [127:0] q_all, q_big, q_rd;
    reg [1:0]   sel_d;
    reg [9:0]   idx_d;
    always @(posedge clk) begin
        q_all <= log_all[idx];
        q_big <= log_big[idx];
        q_rd  <= log_rd[idx];
        sel_d <= sel;
        idx_d <= idx;
        entry <= sel_d == 2'd1 ? q_big : sel_d == 2'd2 ? q_rd : q_all;
        entry_valid <= {1'b0, idx_d} < (sel_d == 2'd1 ? n_big : sel_d == 2'd2 ? n_rdlog : n_all);
    end
endmodule
