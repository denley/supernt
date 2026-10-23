// SPDX-License-Identifier: GPL-3.0-or-later
// Memory test for the IS42S81600F pair on the top-bank bus (U5 + U16; notes/sdram.md,
// "Controller 2", "memtest v2 result"). Group 1 (G1: D12 group) is one x8 chip on the shared
// address bus (A0-A9, A11, BA, clock H8; J8 low enables it); group 2 (G2: B6 group, its own
// data pins, B13 low enables it) has its own command pins and, as memtest v2 found, its own
// address pins too, apart from D17. Both get the same commands in the same cycles in the main
// test (G2 then hits one location over and over, which the main test counts as errors); a
// probe afterwards looks for G2's address pins.
//
// Written to work without the unknown parts of the pin map: any bijection of row and column
// bits onto A0-A9 works, the mode register sets only N6 and R7 (as spc.cor; memtest v2 saw
// G1's data one clock earlier than U4's, so this is CL2 or the board is faster), A10 is 0 in
// every READ/WRITE and 1 in every PRECHARGE (= precharge all), and every access is a single
// READ or WRITE (one per clock).
//
// Group 2's data pins are open drain in spc.cor (it only ever writes 0x00 there), and this
// test keeps them that way: the caller drives a line low where g2_low is 1 and otherwise
// releases it to its weak pull-up, so a written 1 needs time to rise. Group 2 gets one byte
// per row in the main test (on the pins WAIT_OD clocks before the row's writes).
//
// Read capture on both clock edges, compared at six points after the edge that puts the READ
// on the pins: f2.5 r3 f3.5 r4 f4.5 r5 (v2: G1 right at r3).
//
// A pass (~0.6 s at full size): init, write all 4 x 4096 rows x 1024 columns, read them back,
// column walk (bank 1 row 5, columns 0, 1, 2, 4 ... 512 written one at a time with WAIT_OD
// before each, then read back), then the G2 address probe: for each of NPROBE pins (the caller
// maps probe index pr_sel to a pin it otherwise holds low and releases it while pr_hi is 1;
// index NPROBE-1 is D17, handled here), with G1 deselected and base = every probed pin low:
//   write X0 to base; write Xa with the pin high during ACT only; read base -> b1;
//   write Xw with the pin high during WRITE only; read base -> b2.
// Not an address pin: b1 = Xa, b2 = Xw. Row-only bit (A10, A11): b1 = X0, b2 = Xw. Row and
// column bit (A0-A9) or bank bit: b1 = b2 = X0. b1/b2 are recorded at r3 and r4.
// A pass starts on a `start` pulse; `done` pulses at the end with the results in last_*.
module mem2_test #(
    parameter [11:0] ROWS     = 12'd4095,  // last row tested per bank (simulation uses fewer)
    parameter [15:0] INIT_NOP = 16'd20000, // NOP cycles before the init sequence (~270 us)
    parameter [15:0] WAIT_OD  = 16'd300,   // group 2 data / probe pin settling time (~4 us)
    parameter [9:0]  MRS_PINS = 10'b0000001001, // sd_a[0] (N6) and sd_a[3] (R7), as spc.cor
    parameter integer NPROBE  = 22
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
    output reg  [4:0]  pr_sel = 5'd31,    // probe: pin index (31 = none)
    output reg         pr_hi = 1'b0,      //        release it (else hold low)
    output wire        busy,
    output reg         done = 1'b0,
    output reg  [15:0] passes = 16'd0,
    // last pass: errors (25 bits each), index = 6 * group + point, points f2.5 r3 f3.5 r4
    // f4.5 r5, group 0 = G1, 1 = G2
    output reg  [299:0] last_err = 300'd0,
    // column walk, same indexing: bit i = entry i read wrong (0 = column 0, i = column 2^(i-1))
    output reg  [131:0] last_cw = 132'd0,
    // first READ of the read phase (bank 0 row 0): {G2, G1} at rising edges 2..7 after it,
    // then the expected words of columns 0 and 1
    output reg  [127:0] last_raw = 128'd0,
    // probe: entry j = {b1 r3, b1 r4, b2 r3, b2 r4} (G2 bytes)
    output reg  [32*NPROBE-1:0] last_probe = 0
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
    localparam [4:0] D17_IDX = NPROBE - 1;
    // powers up deselected (internal register: notes/quartus.md, "Power-up values")
    reg [3:0] sd_cmd = 4'b1111;
    reg       a10 = 1'b0;
    reg       g1_off = 1'b0;              // probe: G1 deselected
    assign g1_cmd = g1_off ? 4'b1111 : sd_cmd;
    assign g2_cmd = sd_cmd;
    assign g1_a10 = a10;
    assign g2_a10 = pr_sel == D17_IDX && pr_hi ? 1'b1 : a10;

    // ---------------------------------------------------------------- patterns
    function [7:0] pat1(input [1:0] b, input [11:0] r, input [9:0] c, input [15:0] p);
        reg [31:0] x;
        begin
            x = {b, r, c, 8'd0} ^ {p, p} ^ 32'h2545F491;
            x = x * 32'h9E3779B1;
            pat1 = x[31:24] ^ x[23:16] ^ x[15:8] ^ x[7:0];
        end
    endfunction
    // group 2: one byte per row, a different nonzero constant per bank/row bit
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
               S_PROBE = 18, S_DONE = 19;
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
    reg [4:0]  pj = 5'd0;                 // probe entry
    reg [4:0]  pop = 5'd0;                // probe step
    reg        prd = 1'b0;                // probe READ issued this cycle
    reg        prd2 = 1'b0;               //   it is the second one (b2)
    // read expectation stream: valid, expected {G2, G1}, tag (0 main, 1..11 column walk)
    reg        rv0 = 1'b0;
    reg [15:0] re0 = 16'd0;
    reg [3:0]  rt0 = 4'd0;
    reg [6:0]  rv = 7'd0;
    reg [15:0] re [1:7];
    reg [3:0]  rt [1:7];
    integer k;
    initial for (k = 1; k <= 7; k = k + 1) begin re[k] = 16'd0; rt[k] = 4'd0; end
    assign busy = st != S_IDLE;
    wire [7:0] px0 = 8'h11 + {3'd0, pj}, pxa = 8'h81 + {3'd0, pj}, pxw = 8'hC1 + {3'd0, pj};

    always @(posedge clk) begin
        sd_cmd <= C_NOP;
        rv0 <= 1'b0;
        raw_go <= 1'b0;
        pass_end <= 1'b0;
        prd <= 1'b0;
        g1_dq_oe <= 1'b0;
        if (wait_c != 16'd0) begin
            wait_c <= wait_c - 16'd1;
            if (st == S_IDLE) sd_cmd <= 4'b1111;
        end else case (st)
            S_IDLE: begin
                sd_cmd <= 4'b1111;              // deselected between passes
                g2_low <= 8'd0;
                g1_off <= 1'b0;
                pr_sel <= 5'd31; pr_hi <= 1'b0;
                if (start) begin
                    st <= S_IPRE; wait_c <= INIT_NOP; n <= 4'd0;
                    writing <= 1'b1; bank <= 2'd0; row <= 12'd0;
                end
            end
            S_IPRE: begin
                sd_cmd <= C_PRE; a10 <= 1'b1; wait_c <= 16'd3; st <= S_IREF;
            end
            S_IREF: begin
                sd_cmd <= C_REF; wait_c <= 16'd7; n <= n + 4'd1;
                if (n == 4'd7) st <= S_MRS;
            end
            S_MRS: begin
                sd_cmd <= C_MRS; sd_a <= MRS_PINS; a10 <= 1'b0; sd_a11 <= 1'b0; sd_ba <= 2'd0;
                wait_c <= 16'd3; st <= S_ROW;
            end
            S_ROW: begin
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
            S_BURST: begin
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
                    wait_c <= writing ? 16'd2 : 16'd4;
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
            S_CWREF: begin
                sd_cmd <= C_REF; wait_c <= 16'd7; n <= n + 4'd1;
                if (n == 4'd1) begin st <= S_CWACT; n <= 4'd0; end
            end
            S_CWACT: begin
                sd_cmd <= C_ACT; sd_ba <= 2'd1; sd_a <= 10'd5; a10 <= 1'b0; sd_a11 <= 1'b0;
                wait_c <= 16'd2; st <= S_CWSET;
            end
            S_CWSET: begin
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
                sd_cmd <= C_PRE; a10 <= 1'b1; wait_c <= 16'd8; st <= S_PROBE;
                pj <= 5'd0; pop <= 5'd0; g1_off <= 1'b1;
                sd_a <= 10'd0; sd_a11 <= 1'b0; sd_ba <= 2'd0;
            end
            // G2 address probe, entry pj, step pop (notes at the top)
            S_PROBE: begin
                pop <= pop + 5'd1;
                pr_sel <= pj;
                case (pop)
                    5'd0:  begin pr_hi <= 1'b0; g2_low <= ~px0; wait_c <= WAIT_OD; end
                    5'd1:  begin sd_cmd <= C_ACT; a10 <= 1'b0; wait_c <= 16'd2; end
                    5'd2:  begin sd_cmd <= C_WR; wait_c <= 16'd2; end
                    5'd3:  begin sd_cmd <= C_PRE; a10 <= 1'b1; wait_c <= 16'd3; end
                    5'd4:  begin pr_hi <= 1'b1; a10 <= 1'b0; g2_low <= ~pxa; wait_c <= WAIT_OD; end
                    5'd5:  begin sd_cmd <= C_ACT; wait_c <= 16'd2; end
                    5'd6:  begin pr_hi <= 1'b0; wait_c <= 16'd8; end
                    5'd7:  begin sd_cmd <= C_WR; wait_c <= 16'd2; end
                    5'd8:  begin sd_cmd <= C_PRE; a10 <= 1'b1; wait_c <= 16'd3; end
                    5'd9:  begin g2_low <= 8'd0; a10 <= 1'b0; wait_c <= 16'd8; end
                    5'd10: begin sd_cmd <= C_ACT; wait_c <= 16'd2; end
                    5'd11: begin sd_cmd <= C_RD; prd <= 1'b1; prd2 <= 1'b0; wait_c <= 16'd8; end
                    5'd12: begin sd_cmd <= C_PRE; a10 <= 1'b1; wait_c <= 16'd3; end
                    5'd13: begin a10 <= 1'b0; g2_low <= ~pxw; wait_c <= WAIT_OD; end
                    5'd14: begin sd_cmd <= C_ACT; wait_c <= 16'd2; end
                    5'd15: begin pr_hi <= 1'b1; wait_c <= WAIT_OD; end
                    5'd16: begin sd_cmd <= C_WR; wait_c <= 16'd2; end
                    5'd17: begin pr_hi <= 1'b0; wait_c <= 16'd8; end
                    5'd18: begin sd_cmd <= C_PRE; a10 <= 1'b1; wait_c <= 16'd3; end
                    5'd19: begin g2_low <= 8'd0; a10 <= 1'b0; wait_c <= 16'd8; end
                    5'd20: begin sd_cmd <= C_ACT; wait_c <= 16'd2; end
                    5'd21: begin sd_cmd <= C_RD; prd <= 1'b1; prd2 <= 1'b1; wait_c <= 16'd8; end
                    default: begin
                        sd_cmd <= C_PRE; a10 <= 1'b1; wait_c <= 16'd3; pop <= 5'd0;
                        if (pj == NPROBE - 1) st <= S_DONE;
                        else pj <= pj + 5'd1;
                    end
                endcase
            end
            S_DONE: begin
                pass_end <= 1'b1;
                pass <= pass + 16'd1;
                pr_sel <= 5'd31; pr_hi <= 1'b0; g1_off <= 1'b0;
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
    // as sdram_test.sv: rv[k] is high k+1 cycles after the READ appeared on the pins; with
    // c_v[k], c_p holds the pins at rising edge k+1 and c_n those at falling edge k+0.5
    reg [15:0] c_p = 0, c_n = 0;
    reg [6:0]  c_v = 0;
    reg [15:0] c_e3 = 0, c_e4 = 0, c_e5 = 0;
    reg [3:0]  c_t3 = 0, c_t4 = 0, c_t5 = 0;
    always @(posedge clk) begin
        c_p <= dq_p;
        c_n <= dq_n2;
        c_v <= rv;
        c_e3 <= re[3]; c_e4 <= re[4]; c_e5 <= re[5];
        c_t3 <= rt[3]; c_t4 <= rt[4]; c_t5 <= rt[5];
    end
    // index 6 * group + point; points f2.5 r3 f3.5 r4 f4.5 r5. !== so that an undefined bus
    // counts as a miss in simulation (synthesis: same as !=)
    wire [11:0] miss;
    wire [3:0]  mtag [0:11];
    genvar gg;
    generate for (gg = 0; gg < 2; gg = gg + 1) begin : g_cmp
        assign miss[6*gg + 0] = c_v[2] && c_n[8*gg +: 8] !== c_e3[8*gg +: 8];
        assign miss[6*gg + 1] = c_v[2] && c_p[8*gg +: 8] !== c_e3[8*gg +: 8];
        assign miss[6*gg + 2] = c_v[3] && c_n[8*gg +: 8] !== c_e4[8*gg +: 8];
        assign miss[6*gg + 3] = c_v[3] && c_p[8*gg +: 8] !== c_e4[8*gg +: 8];
        assign miss[6*gg + 4] = c_v[4] && c_n[8*gg +: 8] !== c_e5[8*gg +: 8];
        assign miss[6*gg + 5] = c_v[4] && c_p[8*gg +: 8] !== c_e5[8*gg +: 8];
        assign mtag[6*gg + 0] = c_t3, mtag[6*gg + 1] = c_t3, mtag[6*gg + 2] = c_t4;
        assign mtag[6*gg + 3] = c_t4, mtag[6*gg + 4] = c_t5, mtag[6*gg + 5] = c_t5;
    end endgenerate
    reg [24:0] pe [0:11];
    reg [10:0] pc [0:11];
    initial for (k = 0; k < 12; k = k + 1) begin pe[k] = 25'd0; pc[k] = 11'd0; end
    reg [15:0] rs [0:5];
    initial for (k = 0; k < 6; k = k + 1) rs[k] = 16'd0;
    reg [15:0] e0 = 0, e1 = 0;
    reg [3:0]  rcnt = 4'd0;
    reg        clr = 1'b0;
    // probe reads: G2 byte at r3 and r4 (same counting as the raw words)
    reg [3:0]  pcnt = 4'd0;
    reg        pis2 = 1'b0;
    reg [7:0]  pb3 = 8'd0;
    reg [32*NPROBE-1:0] probe = 0;
    integer j;
    always @(posedge clk) begin
        clr <= 1'b0;
        done <= 1'b0;
        for (k = 0; k < 12; k = k + 1)
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
        if (prd) begin
            pcnt <= 4'd1; pis2 <= prd2;
        end else if (pcnt != 4'd0) begin
            pcnt <= pcnt == 4'd4 ? 4'd0 : pcnt + 4'd1;
            if (pcnt == 4'd3) pb3 <= dq_p[15:8];
            if (pcnt == 4'd4) begin
                if (pis2) probe[32*pj +: 16] <= {pb3, dq_p[15:8]};
                else      probe[32*pj + 16 +: 16] <= {pb3, dq_p[15:8]};
            end
        end
        if (pass_end) begin
            for (j = 0; j < 12; j = j + 1) begin
                last_err[25*j +: 25] <= pe[j];
                last_cw[11*j +: 11] <= pc[j];
            end
            last_raw <= {e1, e0, rs[5], rs[4], rs[3], rs[2], rs[1], rs[0]};
            last_probe <= probe;
            passes <= passes + 16'd1;
            done <= 1'b1;
            clr <= 1'b1;
            rcnt <= 4'd0;
        end
    end
endmodule
