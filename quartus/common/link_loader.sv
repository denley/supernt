// SPDX-License-Identifier: GPL-3.0-or-later
// PIC32 link -> SDRAM loader (notes/snes-sdram.md, "Link loader"; link protocol in
// notes/pic-link.md). The link slave is the stock core's port as quartus/common/link_logger.sv
// implements it: A[2:0] register select, /WR and /RD strobes (active low), 8-bit data, a 32-bit
// address register written a byte at a time (A = 0/1/4/5), data writes at A = 2 with
// post-increment, A = 3 latch + increment, reads return the stock core's constants.
//
// Every data byte whose address falls in [WIN_BASE, WIN_BASE + WIN_SIZE) is stored in SDRAM:
// window offset o -> SDRAM word SD_BASE + o/2, low byte for even o, high byte for odd o (the
// little-endian ROM image the core reads). DQM can't mask bytes, so bytes are paired before a
// word is written:
//   - a pending half word waits for the other byte of the same word, also across address
//     register writes (a file sent in chunks with odd lengths still gives whole words);
//   - when a byte for another word arrives, after IDLE_FLUSH cycles without a strobe, or on
//     `flush`, a pending half word is written by read-modify-write (aux read port of
//     sdram_rom.sv), so the other byte of that word keeps its old SDRAM content (odd start/end).
// Words go through a FIFO (FIFO_AW address bits) to the controller's write port; bytes that find
// it full are dropped and counted. All of this needs the controller's ROM reads off (rom_en = 0:
// the core held in reset), as the aux read port is only served then.
module link_loader #(
    parameter [31:0] WIN_BASE   = 32'h0000_0000,
    parameter [31:0] WIN_SIZE   = 32'h0060_0000,   // bytes (6 MB)
    parameter [23:0] SD_BASE    = 24'd0,           // SDRAM word for window offset 0
    parameter integer IDLE_FLUSH = 85_000,         // ~1 ms at 85.77 MHz
    parameter integer FIFO_AW   = 4
) (
    input  wire        clk,             // controller clock (>= 40 MHz for the link synchronisers)
    // PIC32 link (pins as link_logger.sv)
    input  wire [2:0]  a,
    input  wire        n_rd,
    input  wire        n_wr,
    input  wire [7:0]  d_in,
    output reg  [7:0]  d_out = 8'd0,
    output reg         d_oe = 1'b0,
    input  wire        flush,           // write out a pending half word now
    // sdram_rom.sv write port
    output reg         wr_req = 1'b0,
    output reg  [23:0] wr_addr = 24'd0,
    output reg  [15:0] wr_data = 16'd0,
    input  wire        wr_ack,
    // sdram_rom.sv aux read port
    output reg         rd_req = 1'b0,
    output reg  [23:0] rd_addr = 24'd0,
    input  wire        rd_ack,
    input  wire        rd_valid,
    input  wire [15:0] rd_q,
    // status
    output reg  [31:0] addr = 32'd0,    // link address register
    output reg  [31:0] n_bytes = 0,     // bytes in the window
    output reg  [31:0] n_words = 0,     // SDRAM words written
    output reg  [31:0] n_partial = 0,   // of those, read-modify-write
    output reg  [31:0] n_dropped = 0,   // bytes lost to a full FIFO
    output wire        busy             // half word pending or FIFO not empty
);
    // ------------------------------------------------------------ link slave
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

    reg [31:0] lat = 32'd0;
    function [7:0] rdval(input [31:0] ad);   // stock core's read constants (notes/pic-link.md)
        case (ad)
            32'h2004_0000: rdval = 8'h02;
            32'h2008_0000: rdval = 8'h03;
            32'h2009_0000: rdval = 8'h64;
            default:       rdval = 8'h00;
        endcase
    endfunction

    reg        dbyte = 1'b0;            // a data byte for the window this cycle
    reg [31:0] doff;
    reg [7:0]  dval;
    wire [31:0] off_now = addr - WIN_BASE;
    always @(posedge clk) begin
        dbyte <= 1'b0;
        if (wr_fall) case (sa)
            3'd0: addr[7:0]   <= sd;
            3'd1: addr[15:8]  <= sd;
            3'd4: addr[23:16] <= sd;
            3'd5: addr[31:24] <= sd;
            3'd2: begin
                if (off_now < WIN_SIZE) begin
                    dbyte <= 1'b1; doff <= off_now; dval <= sd;
                end
                addr <= addr + 32'd1;
            end
            3'd3: begin lat <= addr; addr <= addr + 32'd1; end
            default: ;
        endcase
        if (rd_fall) begin
            d_out <= rdval(lat);
            d_oe  <= 1'b1;
        end
        if (rd_rise && d_oe) begin
            d_oe <= 1'b0;
            lat  <= addr;
            addr <= addr + 32'd1;
        end
        if (!wr_n) d_oe <= 1'b0;
    end

    // ------------------------------------------------------------ byte pairing
    localparam integer FD = 1 << FIFO_AW;
    reg [41:0] fifo [0:FD-1];           // {be[1:0], word[23:0], data[15:0]}
    reg [FIFO_AW:0] wp = 0, rp = 0;
    wire        f_empty = wp == rp;
    wire        f_full  = (wp - rp) == FD;
    reg  [1:0]  pv = 2'b00;             // pending half word: valid bytes {hi, lo}
    reg  [23:0] pw = 24'd0;
    reg  [15:0] pd = 16'd0;
    reg  [31:0] idle = 0;
    wire [23:0] bw = SD_BASE + doff[24:1];
    wire        bl = doff[0];
    wire        idle_out = pv != 2'b00 && (flush || idle == IDLE_FLUSH);
    reg         push;
    reg  [41:0] pent;
    always @(*) begin
        push = 1'b0;
        pent = {pv, pw, pd};
        if (dbyte) begin
            if (pv != 2'b00 && bw != pw) begin
                push = 1'b1;                           // other word: flush the pending half
            end else if ((pv | (bl ? 2'b10 : 2'b01)) == 2'b11) begin
                push = 1'b1;                           // completes the pending word
                pent = {2'b11, pw, bl ? {dval, pd[7:0]} : {pd[15:8], dval}};
            end
        end else if (idle_out)
            push = 1'b1;
    end
    always @(posedge clk) begin
        idle <= (wr_fall || rd_fall) ? 32'd0 : (idle == IDLE_FLUSH ? idle : idle + 32'd1);
        if (dbyte) n_bytes <= n_bytes + 1;
        if (push) begin
            if (f_full) n_dropped <= n_dropped + (pent[41] + pent[40]);
            else begin
                fifo[wp[FIFO_AW-1:0]] <= pent;
                wp <= wp + 1'd1;
            end
        end
        if (dbyte) begin
            if (pv != 2'b00 && bw != pw) begin         // start a new half word
                pv <= bl ? 2'b10 : 2'b01; pw <= bw;
                pd <= bl ? {dval, 8'h00} : {8'h00, dval};
            end else if ((pv | (bl ? 2'b10 : 2'b01)) == 2'b11)
                pv <= 2'b00;
            else begin
                pv <= pv | (bl ? 2'b10 : 2'b01); pw <= bw;
                if (bl) pd[15:8] <= dval; else pd[7:0] <= dval;
            end
        end else if (idle_out)
            pv <= 2'b00;
    end

    // ------------------------------------------------------------ SDRAM side
    wire [41:0] head = fifo[rp[FIFO_AW-1:0]];
    localparam [1:0] Q_IDLE = 0, Q_READ = 1, Q_WAIT = 2, Q_WRITE = 3;
    reg [1:0] qs = Q_IDLE;
    always @(posedge clk) begin
        case (qs)
            Q_IDLE: if (!f_empty) begin
                if (head[41:40] == 2'b11) begin
                    wr_req <= 1'b1; wr_addr <= head[39:16]; wr_data <= head[15:0];
                    qs <= Q_WRITE;
                end else begin
                    rd_req <= 1'b1; rd_addr <= head[39:16];
                    qs <= Q_READ;
                end
            end
            Q_READ: if (rd_ack) begin rd_req <= 1'b0; qs <= Q_WAIT; end
            Q_WAIT: if (rd_valid) begin
                wr_req  <= 1'b1; wr_addr <= head[39:16];
                wr_data <= {head[41] ? head[15:8] : rd_q[15:8], head[40] ? head[7:0] : rd_q[7:0]};
                n_partial <= n_partial + 1;
                qs <= Q_WRITE;
            end
            Q_WRITE: if (wr_ack) begin
                wr_req <= 1'b0;
                n_words <= n_words + 1;
                rp <= rp + 1'd1;
                qs <= Q_IDLE;
            end
        endcase
    end
    assign busy = pv != 2'b00 || !f_empty || qs != Q_IDLE;
endmodule
