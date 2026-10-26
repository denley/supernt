// SPDX-License-Identifier: GPL-3.0-or-later
// On-screen save RAM dump for quartus/snes_load v8 (notes/snes-load.md, "Save dump"): draws
// BW-RAM/SRAM as black and white cells for a photo or an HDMI capture, which tools/savedump.py
// reads back into a .sav. One page = 4 KB; the caller picks the page.
//
// Screen (1280x720, cells of 4 x 4 pixels, cell coordinates X = hx / 4, Y = vy / 4):
//   frame       white, 2 cells thick, outer box X 20-298, Y 14-165 (a black cell gap inside)
//   timing row  Y 17, X 23-295: white where X is odd (starts white at the corner X 23)
//   timing col  X 23, Y 17-162: white where Y is odd
//   data        X 24-295 (272 cells = 34 bytes, MSB first, 1 = white), Y 18-162 (145 rows)
//   page boxes  Y 4-9 above the frame: one 6-cell box per page at X 20 + 8 i, white = this page
// Rows (r = Y - 18), 34 bytes each:
//   r = 0         header: "SNTD", 1 (format), page, page count, 4 (cell pixels), dump size (4,
//                 LE), game ROM CRC-32 (4), dump id (4), ROM_TYPE, header RAM size byte, 0s;
//   r = 1-128     32 bytes of the page (RAM byte page * 4096 + (r - 1) * 32 + k; 0 past the
//                 dump size);
//   rows 0-128 end with CRC-16/CCITT-FALSE (poly 1021, init FFFF, big-endian) over the page
//                 number, r and the 32 bytes;
//   r = 129-144   parity: row 129 + g = XOR of all 34 bytes of the rows r <= 128 with r mod 16
//                 = g (one lost row per group can be rebuilt; any 16 adjacent rows are in
//                 different groups).
// Timing as overlay.sv: hx/vy are snes_video's counters (cycle 0), r/g/b/valid registered at
// cycle 6. RAM port: ram_addr registered, ram_q one clock later (the BW-RAM's second port).
module ram_dump #(
    parameter integer AW = 16
) (
    input  wire          clk,
    input  wire [10:0]   hx,
    input  wire [9:0]    vy,
    input  wire          on,
    input  wire [3:0]    page,
    input  wire [16:0]   size,          // bytes in the dump (0-65536)
    input  wire [31:0]   game_crc,
    input  wire [31:0]   dump_id,
    input  wire [7:0]    rom_type,
    input  wire [7:0]    ram_byte,      // the header's RAM size byte
    output reg  [AW-1:0] ram_addr = {AW{1'b0}},
    input  wire [7:0]    ram_q,
    output reg  [7:0]    r = 8'd0, g = 8'd0, b = 8'd0,
    output reg           valid = 1'b0
);
    function [15:0] crc16(input [15:0] c, input [7:0] d);
        integer i;
        reg [15:0] x;
        begin
            x = c ^ {d, 8'd0};
            for (i = 0; i < 8; i = i + 1)
                x = x[15] ? {x[14:0], 1'b0} ^ 16'h1021 : {x[14:0], 1'b0};
            crc16 = x;
        end
    endfunction

    // ---------------------------------------------------------------- per frame
    reg  [3:0]  pg = 4'd0;
    reg  [16:0] sz = 17'd0;
    reg  [4:0]  npg = 5'd0;
    reg  [31:0] gcrc = 32'd0, did = 32'd0;
    reg  [7:0]  rtyp = 8'd0, rbyte = 8'd0;
    always @(posedge clk)
        if (hx == 11'd0 && vy == 10'd725) begin
            pg <= page; sz <= size; gcrc <= game_crc; did <= dump_id; rtyp <= rom_type; rbyte <= ram_byte;
            npg <= size[16:12] + {4'd0, size[11:0] != 12'd0};
        end
    function [7:0] hdr(input [4:0] k);
        case (k)
            5'd0: hdr = "S";  5'd1: hdr = "N";  5'd2: hdr = "T";  5'd3: hdr = "D";
            5'd4: hdr = 8'd1; 5'd5: hdr = {4'd0, pg}; 5'd6: hdr = {3'd0, npg}; 5'd7: hdr = 8'd4;
            5'd8: hdr = sz[7:0]; 5'd9: hdr = sz[15:8]; 5'd10: hdr = {7'd0, sz[16]}; 5'd11: hdr = 8'd0;
            5'd12: hdr = gcrc[7:0]; 5'd13: hdr = gcrc[15:8]; 5'd14: hdr = gcrc[23:16]; 5'd15: hdr = gcrc[31:24];
            5'd16: hdr = did[7:0]; 5'd17: hdr = did[15:8]; 5'd18: hdr = did[23:16]; 5'd19: hdr = did[31:24];
            5'd20: hdr = rtyp; 5'd21: hdr = rbyte;
            default: hdr = 8'd0;
        endcase
    endfunction

    // ---------------------------------------------------------------- cycle 1
    reg  [8:0] cx1 = 9'd0;
    reg  [7:0] cy1 = 8'd0;
    reg  [1:0] sx1 = 2'd0, ly1 = 2'd0;
    always @(posedge clk) begin
        cx1 <= hx[10:2]; cy1 <= vy[9:2]; sx1 <= hx[1:0]; ly1 <= vy[1:0];
    end
    wire       row_on = cy1 >= 8'd18 && cy1 <= 8'd162;
    wire [7:0] rr = cy1 - 8'd18;                                 // row 0-144
    // byte kk = 0-34 is fetched at the first pixel of cell X = 16 + 8 kk (a byte before it is drawn)
    wire       fetch = row_on && cx1 >= 9'd16 && cx1 <= 9'd288 && cx1[2:0] == 3'd0 && sx1 == 2'd0;
    wire [5:0] kk = cx1[8:3] - 6'd2;
    wire       par = rr > 8'd128;
    wire [3:0] grp = par ? rr[3:0] - 4'd1 : rr[3:0];             // (129 + g) mod 16 = g + 1
    wire [6:0] rm1 = rr[6:0] - 7'd1;
    wire [16:0] la = {pg, rm1, kk[4:0]};                          // page * 4096 + (r - 1) * 32 + k

    // ---------------------------------------------------------------- cycle 2: addresses
    // source of a fetched byte: 0 header, 1 RAM, 2 zero, 3 CRC high, 4 CRC low, 5 parity
    reg        f2 = 1'b0, acc2 = 1'b0, first2 = 1'b0;
    reg  [2:0] src2 = 3'd0;
    reg  [9:0] aa2 = 10'd0;                                       // parity RAM {group, byte}
    reg  [15:0] crc = 16'hFFFF;
    reg  [7:0] nxt = 8'd0, cur = 8'd0;
    always @(posedge clk) begin
        f2 <= fetch && kk <= 6'd33;
        acc2 <= fetch && kk <= 6'd33 && !par && ly1 == 2'd0;      // accumulate once per row
        first2 <= rr < 8'd16;
        src2 <= par ? 3'd5 : kk == 6'd32 ? 3'd3 : kk == 6'd33 ? 3'd4 : rr == 8'd0 ? 3'd0 :
                la < sz ? 3'd1 : 3'd2;
        aa2 <= {grp, kk};
        ram_addr <= la[AW-1:0];
        if (fetch) cur <= nxt;
    end

    // ---------------------------------------------------------------- cycle 3: the byte
    (* ramstyle = "M10K" *) reg [7:0] acc [0:1023];
    reg  [7:0] acc_q = 8'd0;
    reg  [4:0] k3 = 5'd0;
    always @(posedge clk) begin
        acc_q <= acc[aa2];
        k3 <= aa2[4:0];
    end
    reg        f3 = 1'b0, acc3 = 1'b0, first3 = 1'b0;
    reg  [2:0] src3 = 3'd0;
    reg  [9:0] aa3 = 10'd0;
    always @(posedge clk) begin
        f3 <= f2; acc3 <= acc2; first3 <= first2; src3 <= src2; aa3 <= aa2;
    end
    wire [7:0] val3 = src3 == 3'd0 ? hdr(k3) : src3 == 3'd1 ? ram_q : src3 == 3'd3 ? crc[15:8] :
                      src3 == 3'd4 ? crc[7:0] : src3 == 3'd5 ? acc_q : 8'd0;
    always @(posedge clk) begin
        if (f3) nxt <= val3;
        if (acc3) acc[aa3] <= first3 ? val3 : val3 ^ acc_q;
        // CRC: from the page number and row before the row's first byte (X 8), then each data byte
        if (row_on && cx1 == 9'd8 && sx1 == 2'd0) crc <= crc16(crc16(16'hFFFF, {4'd0, pg}), rr);
        else if (f3 && src3 <= 3'd2) crc <= crc16(crc, val3);
    end

    // ---------------------------------------------------------------- cycle 2: the pixel
    reg  [8:0] cx2 = 9'd0;
    reg  [7:0] cy2 = 8'd0;
    always @(posedge clk) begin cx2 <= cx1; cy2 <= cy1; end
    wire in_box   = cx2 >= 9'd20 && cx2 <= 9'd298 && cy2 >= 8'd14 && cy2 <= 8'd165;
    wire in_frame = in_box && (cx2 <= 9'd21 || cx2 >= 9'd297 || cy2 <= 8'd15 || cy2 >= 8'd164);
    wire t_row    = cy2 == 8'd17 && cx2 >= 9'd23 && cx2 <= 9'd295;
    wire t_col    = cx2 == 9'd23 && cy2 >= 8'd17 && cy2 <= 8'd162;
    wire in_data  = cx2 >= 9'd24 && cx2 <= 9'd295 && cy2 >= 8'd18 && cy2 <= 8'd162;
    wire [8:0] bx = cx2 - 9'd20;                                  // page boxes
    wire in_pbox  = cy2 >= 8'd4 && cy2 <= 8'd9 && cx2 >= 9'd20 && bx[8:3] < {1'b0, npg} && bx[2:0] < 3'd6;
    wire [2:0] bit_i = 3'd7 - cx2[2:0];                           // data cell X 24 + 8 k + j: bit 7 - j
    wire white = in_frame || (t_row && cx2[0]) || (t_col && cy2[0]) || (in_data && cur[bit_i]) ||
                 (in_pbox && bx[6:3] == pg);
    wire grey  = in_pbox && bx[6:3] != pg;

    // ---------------------------------------------------------------- cycles 3-6
    reg [7:0] p3 = 8'd0, p4 = 8'd0, p5 = 8'd0;
    reg [2:0] v = 3'd0;
    always @(posedge clk) begin
        p3 <= white ? 8'hFF : grey ? 8'h50 : 8'h00;
        p4 <= p3;
        p5 <= p4;
        r <= p5; g <= p5; b <= p5;
        v <= {v[1:0], on};
        valid <= v[2];
    end
endmodule
