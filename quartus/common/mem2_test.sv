// SPDX-License-Identifier: GPL-3.0-or-later
// Memory test for the IS42S81600F pair on the top-bank bus (U5 + U16; notes/sdram.md,
// "Controller 2"): two x8 chips sharing A0-A9, A11, BA and the clock (H8), each with its own
// CS#/RAS#/CAS#/WE#, A10 and 8 data pins (group 1 = D12 group, group 2 = B6 group). Both
// groups get the same commands in the same cycles, so one pass tests both chips.
//
// Written to work without the unknown parts of the pin map: any bijection of row and column
// bits onto A0-A9 works, the mode register sets only A4/A5 (N6 and R7, whichever is which:
// CL3, burst length 1, sequential), A10 is 0 in every READ/WRITE and 1 in every PRECHARGE (=
// precharge all), and every access is a single READ or WRITE (one per clock, BL1).
//
// Group 2's data pins are open drain in spc.cor (it only ever writes 0x00 there), and this
// test keeps them that way: the caller drives a line low where g2_low is 1 and otherwise
// releases it to its weak pull-up. A written 1 bit therefore needs time to rise, so group 2
// gets one byte per row: the row's byte goes on the pins WAIT_OD clocks before the row's
// writes start and stays there for all 1024 of them. Group 1 is push-pull and gets a
// different byte in every column. A column walk afterwards checks group 2's column address
// bits: bank 1 row 5, columns 0, 1, 2, 4 ... 512 written one at a time (WAIT_OD before each),
// then read back.
//
// Clock: the controller runs on clk (74.25 MHz); the SDRAM clock is the inverted clk (DDIO on
// H8), as sdram_test.sv does on AB11. Read data is captured on both edges and compared at the
// same four capture points as sdram_test.sv (f3.5, r4, f4.5, r5 after the edge that puts the
// READ on the pins; CL3 puts the data at about r4).
//
// A pass (~0.6 s at full size): init, write all 4 x 4096 rows, read them back, column walk.
// A pass starts on a `start` pulse; `done` pulses at the end with the results in last_*.
module mem2_test #(
    parameter [11:0] ROWS     = 12'd4095,  // last row tested per bank (simulation uses fewer)
    parameter [15:0] INIT_NOP = 16'd20000, // NOP cycles before the init sequence (~270 us)
    parameter [15:0] WAIT_OD  = 16'd300,   // group 2 data set-up time for the pull-ups (~4 us)
    parameter [9:0]  MRS_PINS = 10'b0000001001 // A4/A5 = sd_a[0] (N6) and sd_a[3] (R7)
) (
    input  wire        clk,
    input  wire        start,
    output wire        sd_clk,            // H8 (DDIO, inverted clk)
    output wire [3:0]  g1_cmd,            // {CS#, RAS#, CAS#, WE#}: D12 D13 G13 E12
    output wire        g1_a10,            // H9
    output wire [3:0]  g2_cmd,            // B6 C6 A7 B7
    output wire        g2_a10,            // D17
    output reg  [9:0]  sd_a = 10'd0,      // N6 P6 P7 R7 P8 R9 H6 F7 D7 C8
    output reg         sd_a11 = 1'b0,     // M6
    output reg  [1:0]  sd_ba = 2'd0,      // E9 C9
    input  wire [7:0]  g1_dq_in,          // N8 J7 J9 K7 H11 G12 F12 J11
    output reg  [7:0]  g1_dq_out = 8'd0,
    output reg         g1_dq_oe = 1'b0,
    input  wire [7:0]  g2_dq_in,          // A8 A9 A10 A12 B10 B11 B12 C16
    output reg  [7:0]  g2_low = 8'd0,     // 1 = drive that group 2 line low, 0 = release
    output wire        busy,
    output reg         done = 1'b0,
    output reg  [15:0] passes = 16'd0,
    // last pass: errors (25 bits each) G1 f3.5 r4 f4.5 r5, G2 f3.5 r4 f4.5 r5 (index 0..7)
    output reg  [199:0] last_err = 200'd0,
    // column walk: per capture point and group as last_err, bit i = column index i wrong
    // (index 0 = column 0, i = 1..10 = column 2^(i-1))
    output reg  [87:0]  last_cw = 88'd0,
    // first READ of the read phase (bank 0 row 0): {G2, G1} at rising edges 2..7 after it,
    // then the expected words of columns 0 and 1
    output reg  [127:0] last_raw = 128'd0
);
    altddio_out #(
        .extend_oe_disable("OFF"), .intended_device_family("Cyclone V"),
        .invert_output("OFF"), .lpm_hint("UNUSED"), .lpm_type("altddio_out"),
        .oe_reg("UNREGISTERED"), .power_up_high("OFF"), .width(1)
    ) clk_ddio (
        .datain_h(1'b0), .datain_l(1'b1), .outclock(clk), .dataout(sd_clk),
        .aclr(1'b0), .aset(1'b0), .oe(1'b1), .oe_out(), .outclocken(1'b1), .sclr(1'b0), .sset(1'b0)
    );

    localparam C_NOP = 4'b0111, C_ACT = 4'b0011, C_RD = 4'b0101, C_WR = 4'b0100,
               C_PRE = 4'b0010, C_REF = 4'b0001, C_MRS = 4'b0000;
    // powers up deselected (internal register: notes/quartus.md, "Power-up values")
    reg [3:0] sd_cmd = 4'b1111;
    reg       a10 = 1'b0;
    assign g1_cmd = sd_cmd, g2_cmd = sd_cmd;
    assign g1_a10 = a10, g2_a10 = a10;

    // ---------------------------------------------------------------- patterns
    // group 1: a different byte in every column
    function [7:0] pat1(input [1:0] b, input [11:0] r, input [9:0] c, input [15:0] p);
        reg [31:0] x;
        begin
            x = {b, r, c, 8'd0} ^ {p, p} ^ 32'h2545F491;
            x = x * 32'h9E3779B1;
            pat1 = x[31:24] ^ x[23:16] ^ x[15:8] ^ x[7:0];
        end
    endfunction
    // group 2: one byte per row, a different nonzero constant XORed in for each of the 14 bank
    // and row bits, so rows whose addresses differ in one or two bits always differ
    function [7:0] pat2(input [1:0] b, input [11:0] r, input [15:0] p);
        reg [13:0] ad;
        reg [7:0]  x;
        integer i;
        reg [111:0] g;
        begin
            g = 112'h01_02_04_08_10_20_40_80_03_06_0C_18_30_60;
            ad = {b, r};
            x = p[7:0] * 8'h3B ^ 8'hA5 ^ p[15:8];
            for (i = 0; i < 14; i = i + 1)
                if (ad[i]) x = x ^ g[8*i +: 8];
            pat2 = x;
        end
    endfunction
    // column walk data (11 entries, all different, none 00/FF)
    function [7:0] cw1(input [3:0] i); cw1 = {i, ~i}; endfunction
    function [7:0] cw2(input [3:0] i); cw2 = {~i, i} ^ 8'h5A; endfunction
    function [9:0] cwcol(input [3:0] i); cwcol = i == 4'd0 ? 10'd0 : 10'd1 << (i - 4'd1); endfunction

    // ---------------------------------------------------------------- read capture
    wire [15:0] dq_in = {g2_dq_in, g1_dq_in};
    reg [15:0] dq_p = 0, dq_n = 0, dq_n2 = 0;
    always @(posedge clk) dq_p <= dq_in;
    always @(negedge clk) dq_n <= dq_in;
    always @(posedge clk) dq_n2 <= dq_n;

    // ---------------------------------------------------------------- sequencer
    localparam S_IDLE = 0, S_IPRE = 1, S_IREF = 2, S_MRS = 3, S_ROW = 4, S_REF2 = 5,
               S_ACT = 6, S_BURST = 7, S_BEND = 8, S_NEXT = 9, S_CWREF = 10, S_CWACT = 11,
               S_CWSET = 12, S_CWWR = 13, S_CWPRE = 14, S_CRACT = 15, S_CRRD = 16, S_CREND = 17,
               S_DONE = 18;
    reg [4:0]  st = S_IDLE;
    reg [15:0] wait_c = 16'd0;
    reg [3:0]  n = 4'd0;
    reg        writing = 1'b1;
    reg [1:0]  bank = 2'd0;
    reg [11:0] row = 12'd0;
    reg [9:0]  col = 10'd0;
    reg [15:0] pass = 16'd0;
    reg        raw_go = 1'b0;
    reg        pass_end = 1'b0;
    // read expectation stream (as sdram_test.sv): valid, expected {G2, G1}, tag (0 = main
    // test, 1..11 = column walk entry 0..10)
    reg        rv0 = 1'b0;
    reg [15:0] re0 = 16'd0;
    reg [3:0]  rt0 = 4'd0;
    reg [6:0]  rv = 7'd0;
    reg [15:0] re [1:7];
    reg [3:0]  rt [1:7];
    integer k;
    initial for (k = 1; k <= 7; k = k + 1) begin re[k] = 16'd0; rt[k] = 4'd0; end
    assign busy = st != S_IDLE;

    always @(posedge clk) begin
        sd_cmd <= C_NOP;
        rv0 <= 1'b0;
        raw_go <= 1'b0;
        pass_end <= 1'b0;
        g1_dq_oe <= 1'b0;
        if (wait_c != 16'd0) begin
            wait_c <= wait_c - 16'd1;
            if (st == S_IDLE) sd_cmd <= 4'b1111;
        end else case (st)
            S_IDLE: begin
                sd_cmd <= 4'b1111;              // deselected between passes
                g2_low <= 8'd0;
                if (start) begin
                    st <= S_IPRE; wait_c <= INIT_NOP; n <= 4'd0;
                    writing <= 1'b1; bank <= 2'd0; row <= 12'd0;
                end
            end
            S_IPRE: begin                       // precharge all
                sd_cmd <= C_PRE; a10 <= 1'b1; wait_c <= 16'd3; st <= S_IREF;
            end
            S_IREF: begin                       // 8 x REF, tRC = 60 ns -> 8 clocks apart
                sd_cmd <= C_REF; wait_c <= 16'd7; n <= n + 4'd1;
                if (n == 4'd7) st <= S_MRS;
            end
            S_MRS: begin
                sd_cmd <= C_MRS; sd_a <= MRS_PINS; a10 <= 1'b0; sd_a11 <= 1'b0; sd_ba <= 2'd0;
                wait_c <= 16'd3; st <= S_ROW;
            end
            S_ROW: begin                        // two refreshes per row (~15-19 us per row)
                sd_cmd <= C_REF; wait_c <= 16'd7; st <= S_REF2;
                g2_low <= writing ? ~pat2(bank, row, pass) : 8'd0;
            end
            S_REF2: begin
                sd_cmd <= C_REF; st <= S_ACT;
                wait_c <= writing && WAIT_OD > 16'd7 ? WAIT_OD : 16'd7;
            end
            S_ACT: begin
                sd_cmd <= C_ACT; sd_ba <= bank; sd_a <= row[9:0]; a10 <= row[10]; sd_a11 <= row[11];
                wait_c <= 16'd2; st <= S_BURST; col <= 10'd0;
            end
            S_BURST: begin                      // one READ/WRITE per clock, columns 0-1023
                sd_cmd <= writing ? C_WR : C_RD;
                sd_a <= col; a10 <= 1'b0; sd_a11 <= 1'b0;
                if (writing) begin
                    g1_dq_oe <= 1'b1;
                    g1_dq_out <= pat1(bank, row, col, pass);
                end else begin
                    rv0 <= 1'b1; rt0 <= 4'd0;
                    re0 <= {pat2(bank, row, pass), pat1(bank, row, col, pass)};
                    if (bank == 2'd0 && row == 12'd0 && col == 10'd0) raw_go <= 1'b1;
                end
                col <= col + 10'd1;
                if (col == 10'd1023) begin
                    st <= S_BEND;
                    wait_c <= writing ? 16'd2 : 16'd4;   // tWR / last read data out
                end
            end
            S_BEND: begin
                sd_cmd <= C_PRE; a10 <= 1'b1; wait_c <= 16'd3; st <= S_NEXT;
            end
            S_NEXT: begin
                st <= S_ROW;
                if (bank == 2'd3) begin
                    bank <= 2'd0;
                    if (row == ROWS) begin
                        row <= 12'd0;
                        if (!writing) begin st <= S_CWREF; n <= 4'd0; end
                        writing <= ~writing;
                    end else
                        row <= row + 12'd1;
                end else
                    bank <= bank + 2'd1;
            end
            // column walk: bank 1 row 5; entry i -> column cwcol(i)
            S_CWREF: begin
                sd_cmd <= C_REF; wait_c <= 16'd7; n <= n + 4'd1;
                if (n == 4'd1) begin st <= S_CWACT; n <= 4'd0; end
            end
            S_CWACT: begin
                sd_cmd <= C_ACT; sd_ba <= 2'd1; sd_a <= 10'd5; a10 <= 1'b0; sd_a11 <= 1'b0;
                wait_c <= 16'd2; st <= S_CWSET;
            end
            S_CWSET: begin                      // entry n's group 2 byte, then wait
                g2_low <= ~cw2(n);
                wait_c <= WAIT_OD; st <= S_CWWR;
            end
            S_CWWR: begin
                sd_cmd <= C_WR; sd_a <= cwcol(n); a10 <= 1'b0;
                g1_dq_oe <= 1'b1; g1_dq_out <= cw1(n);
                n <= n + 4'd1;
                st <= n == 4'd10 ? S_CWPRE : S_CWSET;
                if (n == 4'd10) wait_c <= 16'd2;
            end
            S_CWPRE: begin
                sd_cmd <= C_PRE; a10 <= 1'b1; g2_low <= 8'd0; wait_c <= 16'd3; st <= S_CRACT;
                n <= 4'd0;
            end
            S_CRACT: begin
                sd_cmd <= C_ACT; sd_ba <= 2'd1; sd_a <= 10'd5; a10 <= 1'b0; sd_a11 <= 1'b0;
                wait_c <= 16'd2; st <= S_CRRD;
            end
            S_CRRD: begin
                sd_cmd <= C_RD; sd_a <= cwcol(n); a10 <= 1'b0;
                rv0 <= 1'b1; rt0 <= n + 4'd1; re0 <= {cw2(n), cw1(n)};
                n <= n + 4'd1;
                if (n == 4'd10) begin st <= S_CREND; wait_c <= 16'd4; end
            end
            S_CREND: begin
                sd_cmd <= C_PRE; a10 <= 1'b1; wait_c <= 16'd8; st <= S_DONE;
            end
            S_DONE: begin
                pass_end <= 1'b1;
                pass <= pass + 16'd1;
                st <= S_IDLE;
            end
            default: st <= S_IDLE;
        endcase
        rv <= {rv[5:0], rv0};
        re[1] <= re0;
        rt[1] <= rt0;
        for (k = 2; k <= 7; k = k + 1) begin re[k] <= re[k-1]; rt[k] <= rt[k-1]; end
    end

    // ---------------------------------------------------------------- compare
    // as sdram_test.sv: rv[k] is high k+1 cycles after the READ appeared on the pins
    reg [15:0] c_p = 0, c_n = 0;
    reg [6:0]  c_v = 0;
    reg [15:0] c_e4 = 0, c_e5 = 0;
    reg [3:0]  c_t4 = 0, c_t5 = 0;
    always @(posedge clk) begin
        c_p <= dq_p;
        c_n <= dq_n2;
        c_v <= rv;
        c_e4 <= re[4]; c_e5 <= re[5];
        c_t4 <= rt[4]; c_t5 <= rt[5];
    end
    // [0..3] G1 f3.5 r4 f4.5 r5, [4..7] G2
    // !== so that an undefined bus counts as a miss in simulation (synthesis: same as !=)
    wire [7:0] miss = {c_v[4] && c_p[15:8] !== c_e5[15:8], c_v[4] && c_n[15:8] !== c_e5[15:8],
                       c_v[3] && c_p[15:8] !== c_e4[15:8], c_v[3] && c_n[15:8] !== c_e4[15:8],
                       c_v[4] && c_p[7:0]  !== c_e5[7:0],  c_v[4] && c_n[7:0]  !== c_e5[7:0],
                       c_v[3] && c_p[7:0]  !== c_e4[7:0],  c_v[3] && c_n[7:0]  !== c_e4[7:0]};
    wire [3:0] mtag [0:7];
    assign mtag[0] = c_t4, mtag[1] = c_t4, mtag[2] = c_t5, mtag[3] = c_t5;
    assign mtag[4] = c_t4, mtag[5] = c_t4, mtag[6] = c_t5, mtag[7] = c_t5;
    reg [24:0] pe [0:7];
    reg [10:0] pc [0:7];
    initial for (k = 0; k < 8; k = k + 1) begin pe[k] = 25'd0; pc[k] = 11'd0; end
    reg [15:0] rs [0:5];
    initial for (k = 0; k < 6; k = k + 1) rs[k] = 16'd0;
    reg [15:0] e0 = 0, e1 = 0;
    reg [3:0]  rcnt = 4'd0;
    reg        clr = 1'b0;
    // results are taken 8 clocks after the last READ (S_CREND waits 4 + 8), so every compare
    // of the pass has happened
    integer j;
    always @(posedge clk) begin
        clr <= 1'b0;
        done <= 1'b0;
        for (k = 0; k < 8; k = k + 1)
            if (clr) begin
                pe[k] <= 25'd0; pc[k] <= 11'd0;
            end else if (miss[k]) begin
                if (mtag[k] == 4'd0) pe[k] <= pe[k] + 25'd1;
                else pc[k] <= pc[k] | (11'd1 << (mtag[k] - 4'd1));
            end
        if (raw_go) begin
            rcnt <= 4'd1;
            e0 <= {pat2(2'd0, 12'd0, pass), pat1(2'd0, 12'd0, 10'd0, pass)};
            e1 <= {pat2(2'd0, 12'd0, pass), pat1(2'd0, 12'd0, 10'd1, pass)};
        end else if (rcnt != 4'd0 && rcnt != 4'd8) begin
            if (rcnt >= 4'd2) rs[rcnt - 4'd2] <= dq_p;
            rcnt <= rcnt + 4'd1;
        end
        if (pass_end) begin
            for (j = 0; j < 8; j = j + 1) begin
                last_err[25*j +: 25] <= pe[j];
                last_cw[11*j +: 11] <= pc[j];
            end
            last_raw <= {e1, e0, rs[5], rs[4], rs[3], rs[2], rs[1], rs[0]};
            passes <= passes + 16'd1;
            done <= 1'b1;
            clr <= 1'b1;
            rcnt <= 4'd0;
        end
    end
endmodule
