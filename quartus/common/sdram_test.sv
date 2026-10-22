// SPDX-License-Identifier: GPL-3.0-or-later
// Memory test for the x8 SDRAM pair (notes/sdram.md): two x8 chips sharing address and
// command lines, data on 2A (chip A, low byte) and 3B (chip B, high byte), used as one 16-bit
// memory. v3: 4 banks x 4096 rows x 512 columns (hwtest v2 showed a 512-column page: chip B's
// word at column 0 was the one written to column 512, the 1024-word burst had wrapped).
//
// Written to work without the uncertain parts of the pin map:
//   - mode register: spc.cor's exact pin pattern (MRS_PINS; 0x037 = CL3, full-page burst);
//   - every row is written and read as one 512-word burst from column 0 (all address pins 0,
//     so A10 = 0 whichever pin it is), ended by BURST TERMINATE, like the stock controller;
//     banks are precharged one at a time (A10 = 0);
//   - row addresses are any 12-bit pattern on the 12 address pins (any bit order works).
// Clock: the controller runs on clk (74.25 MHz); the SDRAM clock is the inverted clk (DDIO).
// Read data is captured on both clock edges and compared at four capture points, counted from
// the clock edge that puts the READ command on the pins: f3.5, r4, f4.5, r5 (v2: chip B right
// at r4 and f3.5), separately for each chip.
//
// Pin hypotheses, one per pass (re-initialise, write all rows, read them back, ~0.25 s):
// v2 found AB10 low = chip B drives (AB10 high: nothing does), chip A never drives. spc.cor
// configures every pin of the FPGA; the ones our cores leave unused (weak pull-up inputs) but
// spc.cor drives to a constant are candidates for chip A's DQM/CKE/CS. Here the 19 such pins of
// banks 3A/3B (tie[i], index i as in hwtest_top.sv / notes/sdram.md) are each either at
// spc.cor's level ("stock") or released (weak pull-up, as in v1/v2):
//   0       stock: all 19 at spc.cor's level, AB10 low, open-drain pins released
//   1       all 19 released (v2's hypothesis 0)
//   2-6     stock, except the pins whose index has bit (h-2) set are released
//   7-11    stock, except the pins whose index has bit (h-7) clear are released
//   12      stock + Y3 low (the open-drain pin in chip A's bank 2A)
//   13      stock + AB10 high
//   14      stock + all eight open-drain pins low
//   15      stock (again)
// If chip A needs exactly one of the pins at its stock level, it passes in 0, 12-15, fails in
// 1, and hypotheses 2-11 spell out the pin's index (bit k = 1: fails in 2+k, passes in 7+k).
module sdram_test #(
    parameter [11:0] MRS_PINS = 12'h037,  // a[k] high for spc's MRS pattern
    parameter [11:0] ROWS     = 12'd4095, // last row tested (simulation uses fewer)
    parameter [15:0] INIT_NOP = 16'd20000, // NOP cycles before the init sequence (~270 us)
    parameter integer NTIE    = 19
) (
    input  wire        clk,
    output wire        sd_clk,          // AB11 (DDIO, inverted clk)
    output reg         sd_cs_n = 1'b1,
    output reg         sd_ras_n = 1'b1,
    output reg         sd_cas_n = 1'b1,
    output reg         sd_we_n = 1'b1,
    output reg  [11:0] sd_a = 12'd0,
    output reg  [1:0]  sd_ba = 2'd0,
    input  wire [15:0] sd_dq_in,
    output reg  [15:0] sd_dq_out = 16'd0,
    output reg         sd_dq_oe = 1'b0,
    output wire        ab10,            // level for AB10
    output wire [7:0]  od_low,          // drive open-drain pin k low (else release)
    output wire [NTIE-1:0] tie_rel,     // release tie pin i (else spc.cor's level)
    // status
    output reg  [15:0] passes = 16'd0,
    output reg  [3:0]  hyp = 4'd0,      // hypothesis of the pass running now
    input  wire [3:0]  hsel,            // hypothesis shown in err_row/raw_row (1 clock later)
    output reg  [191:0] err_row = 192'd0, // 8 x 24: chip A f3.5 r4 f4.5 r5, chip B the same
    output reg  [159:0] raw_row = 160'd0  // {hyp passes, idle, exp1, exp0, raw r7..r2} x 16
);
    // ---------------------------------------------------------------- pin hypotheses
    function [NTIE-1:0] rel_mask(input [3:0] h);
        integer i;
        begin
            for (i = 0; i < NTIE; i = i + 1)
                rel_mask[i] = h == 4'd1 ? 1'b1 :
                              (h >= 4'd2 && h <= 4'd6)  ? (i >> (h - 2)) & 1 :
                              (h >= 4'd7 && h <= 4'd11) ? !((i >> (h - 7)) & 1) : 1'b0;
        end
    endfunction
    assign tie_rel = rel_mask(hyp);
    assign ab10    = hyp == 4'd13;
    assign od_low  = hyp == 4'd14 ? 8'hFF : hyp == 4'd12 ? 8'h01 : 8'h00;

    altddio_out #(
        .extend_oe_disable("OFF"), .intended_device_family("Cyclone V"),
        .invert_output("OFF"), .lpm_hint("UNUSED"), .lpm_type("altddio_out"),
        .oe_reg("UNREGISTERED"), .power_up_high("OFF"), .width(1)
    ) clk_ddio (
        .datain_h(1'b0), .datain_l(1'b1), .outclock(clk), .dataout(sd_clk),
        .aclr(1'b0), .aset(1'b0), .oe(1'b1), .oe_out(), .outclocken(1'b1), .sclr(1'b0), .sset(1'b0)
    );

    // commands {cs, ras, cas, we}
    localparam C_NOP = 4'b0111, C_ACT = 4'b0011, C_RD = 4'b0101, C_WR = 4'b0100,
               C_BST = 4'b0110, C_PRE = 4'b0010, C_REF = 4'b0001, C_MRS = 4'b0000;
    task cmd(input [3:0] c);
        {sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n} <= c;
    endtask

    // test pattern: never 0000 for the first word (a dead bus often reads 0000 or FFFF)
    function [15:0] pat(input [1:0] b, input [11:0] r, input [8:0] c, input [15:0] p);
        reg [31:0] x;
        begin
            x = {b, r, 1'b0, c, 8'd0} ^ {p, p} ^ 32'h2545F491;
            x = x * 32'h9E3779B1;
            pat = x[31:16] ^ x[15:0];
        end
    endfunction

    // ---------------------------------------------------------------- read capture
    reg [15:0] dq_p = 0, dq_n = 0, dq_n2 = 0;
    always @(posedge clk) dq_p <= sd_dq_in;
    always @(negedge clk) dq_n <= sd_dq_in;
    always @(posedge clk) dq_n2 <= dq_n;   // falling-edge sample, moved to the rising edge

    // ---------------------------------------------------------------- sequencer
    localparam S_INIT = 0, S_IPRE = 1, S_IREF = 2, S_MRS = 3, S_REF = 4, S_ACT = 5,
               S_BURST = 6, S_BST = 7, S_PRE = 8, S_NEXT = 9;
    reg [3:0]  st = S_INIT;
    reg [15:0] wait_c = INIT_NOP;
    reg [3:0]  n = 4'd0;
    reg        writing = 1'b1;
    reg [1:0]  bank = 2'd0;
    reg [11:0] row = 12'd0;
    reg [9:0]  col = 10'd0;
    reg [15:0] pass = 16'd0;
    reg        pass_end = 1'b0;         // one clock after the last read burst of a pass
    reg        raw_go = 1'b0;           // READ of bank 0 row 0 issued this cycle
    reg        idle_go = 1'b0;          // a quiet cycle in the read phase (nobody drives)
    // read-expectation stream: valid/expected word for the column the READ produces, cycle by
    // cycle from the READ command on (e[k] = k cycles later)
    reg        rv0 = 1'b0;
    reg [15:0] re0 = 16'd0;
    reg [6:0]  rv = 7'd0;
    reg [15:0] re [1:7];
    integer k;
    initial for (k = 1; k <= 7; k = k + 1) re[k] = 16'd0;

    always @(posedge clk) begin
        cmd(C_NOP);
        sd_a <= 12'd0;
        rv0 <= 1'b0;
        pass_end <= 1'b0;
        raw_go <= 1'b0;
        idle_go <= 1'b0;
        if (wait_c != 16'd0) begin
            wait_c <= wait_c - 16'd1;
            if (st == S_ACT && !writing && wait_c == 16'd3) idle_go <= 1'b1;
        end else case (st)
            S_INIT: begin                   // precharge each bank (A10 = 0)
                cmd(C_PRE); sd_ba <= n[1:0]; n <= n + 4'd1; wait_c <= 16'd4;
                if (n == 4'd3) begin st <= S_IREF; n <= 4'd0; end
            end
            S_IREF: begin
                cmd(C_REF); wait_c <= 16'd10; n <= n + 4'd1;
                if (n == 4'd7) st <= S_MRS;
            end
            S_MRS: begin
                cmd(C_MRS); sd_ba <= 2'd0; sd_a <= MRS_PINS; wait_c <= 16'd4; st <= S_REF;
            end
            S_REF: begin                    // one refresh before every row (~560 cycles apart)
                cmd(C_REF); wait_c <= 16'd10; st <= S_ACT;
            end
            S_ACT: begin
                cmd(C_ACT); sd_ba <= bank; sd_a <= row; wait_c <= 16'd3; st <= S_BURST; col <= 10'd0;
            end
            S_BURST: begin
                if (col == 10'd0) begin
                    cmd(writing ? C_WR : C_RD); sd_ba <= bank; sd_a <= 12'd0;
                    if (!writing && bank == 2'd0 && row == 12'd0) raw_go <= 1'b1;
                end
                if (writing) begin
                    sd_dq_oe  <= col != 10'd512;
                    sd_dq_out <= pat(bank, row, col[8:0], pass);
                end else if (col != 10'd512) begin
                    rv0 <= 1'b1;
                    re0 <= pat(bank, row, col[8:0], pass);
                end
                if (col == 10'd512) begin   // next cycle: BURST TERMINATE
                    cmd(C_BST);
                    sd_dq_oe <= 1'b0;
                    st <= S_PRE;
                    wait_c <= writing ? 16'd3 : 16'd6;
                end
                col <= col + 10'd1;
            end
            S_PRE: begin
                cmd(C_PRE); sd_ba <= bank; wait_c <= 16'd4; st <= S_NEXT;
            end
            S_NEXT: begin
                st <= S_REF;
                if (bank == 2'd3) begin
                    bank <= 2'd0;
                    if (row == ROWS) begin
                        row <= 12'd0;
                        if (!writing) begin     // pass done: next hypothesis, re-initialise
                            pass <= pass + 16'd1;
                            passes <= passes + 16'd1;
                            pass_end <= 1'b1;
                            st <= S_INIT;
                            n <= 4'd0;
                            wait_c <= 16'd7500; // ~100 us NOP with the new pin levels
                        end
                        writing <= ~writing;
                    end else
                        row <= row + 12'd1;
                end else
                    bank <= bank + 2'd1;
            end
            default: st <= S_INIT;
        endcase
        // expectation pipeline
        rv <= {rv[5:0], rv0};
        re[1] <= re0;
        for (k = 2; k <= 7; k = k + 1) re[k] <= re[k-1];
    end

    // ---------------------------------------------------------------- compare
    // rv[k] is high k+1 cycles after the READ appeared on the pins (cycle T); dq_p then holds the
    // pins at rising edge T+k+1 and dq_n2 those at falling edge T+k+0.5. One more register
    // stage (c_*) before the compare.
    reg [15:0] c_p = 0, c_n = 0;
    reg [6:0]  c_v = 0;
    reg [15:0] c_e4 = 0, c_e5 = 0;
    always @(posedge clk) begin
        c_p <= dq_p;
        c_n <= dq_n2;
        c_v <= rv;
        c_e4 <= re[4];
        c_e5 <= re[5];
    end
    // this pass: [0..3] chip A (low byte) f3.5 r4 f4.5 r5, [4..7] chip B
    reg [23:0] pe [0:7];
    initial for (k = 0; k < 8; k = k + 1) pe[k] = 24'd0;
    wire [7:0] miss = {c_v[4] && c_p[15:8] != c_e5[15:8], c_v[4] && c_n[15:8] != c_e5[15:8],
                       c_v[3] && c_p[15:8] != c_e4[15:8], c_v[3] && c_n[15:8] != c_e4[15:8],
                       c_v[4] && c_p[7:0]  != c_e5[7:0],  c_v[4] && c_n[7:0]  != c_e5[7:0],
                       c_v[3] && c_p[7:0]  != c_e4[7:0],  c_v[3] && c_n[7:0]  != c_e4[7:0]};
    // results of each hypothesis's last pass (written once per pass, read for the display)
    reg [191:0] err_mem [0:15];
    reg [159:0] raw_mem [0:15];
    reg [15:0]  ph [0:15];
    initial for (k = 0; k < 16; k = k + 1) begin
        err_mem[k] = 192'd0;
        raw_mem[k] = 160'd0;
        ph[k] = 16'd0;
    end
    reg [15:0] rs [0:5];                // raw words of this pass (rising edges 2..7 after READ)
    initial for (k = 0; k < 6; k = k + 1) rs[k] = 16'd0;
    reg [15:0] e0 = 0, e1 = 0, idle_now = 0;
    reg [3:0]  rcnt = 4'd0;
    reg        clr = 1'b0;
    always @(posedge clk) begin
        clr <= 1'b0;
        for (k = 0; k < 8; k = k + 1)
            if (clr) pe[k] <= 24'd0;
            else if (miss[k]) pe[k] <= pe[k] + 24'd1;
        // raw words of the first read burst: dq_p at rising edges 2..7 after the READ
        if (raw_go) begin
            rcnt <= 4'd1;
            e0 <= pat(2'd0, 12'd0, 9'd0, pass);
            e1 <= pat(2'd0, 12'd0, 9'd1, pass);
        end else if (rcnt != 4'd0 && rcnt != 4'd8) begin
            if (rcnt >= 4'd2) rs[rcnt - 4'd2] <= dq_p;  // rcnt = 1 -> dq_p = pins at READ edge + 1
            rcnt <= rcnt + 4'd1;
        end
        if (idle_go) idle_now <= dq_p;
        // end of pass: store this hypothesis's results, clear the pass counters, next hypothesis
        if (pass_end) begin
            err_mem[hyp] <= {pe[7], pe[6], pe[5], pe[4], pe[3], pe[2], pe[1], pe[0]};
            raw_mem[hyp] <= {ph[hyp] + 16'd1, idle_now, e1, e0, rs[5], rs[4], rs[3], rs[2], rs[1], rs[0]};
            ph[hyp] <= ph[hyp] + 16'd1;
            hyp <= hyp + 4'd1;
            rcnt <= 4'd0;
            clr <= 1'b1;
        end
    end

    // ---------------------------------------------------------------- display rows
    always @(posedge clk) begin
        err_row <= err_mem[hsel];
        raw_row <= raw_mem[hsel];
    end
endmodule
