// SPDX-License-Identifier: GPL-3.0-or-later
// Memory test for the x8 SDRAM pair (notes/sdram.md): two IS42S81600F sharing address and
// command lines, data on 2A (chip A) and 3B (chip B), used as one 16-bit memory, 4 banks x
// 4096 rows x 1024 columns x 16 bits = 32 MB.
//
// Written to work without the uncertain parts of the pin map:
//   - mode register: spc.cor's exact pin pattern (MRS_PINS; 0x037 = CL3, full-page burst if
//     the A0-A6 order in notes/sdram.md is right);
//   - every row is written and read as one full-page burst from column 0 (all address pins 0,
//     so A10 = 0 whichever pin it is), ended by BURST TERMINATE; banks are precharged one at
//     a time (A10 = 0), so nothing depends on A10;
//   - row addresses are any 12-bit pattern on the 12 address pins (any bit order works).
// Clock: the controller runs on clk (74.25 MHz); the SDRAM clock is the inverted clk (DDIO),
// so the chips sample commands and write data half a cycle after we change them. Read data is
// captured on both clock edges and compared at eight candidate capture points, counted from
// the clock edge that puts the READ command on the pins: point 0/2/4/6 = rising edge 3/4/5/6
// cycles later, 1/3/5/7 = falling edge 2.5/3.5/4.5/5.5 cycles later (sim/sdram_model.v without
// I/O delays: points 2 and 5 pass).
//
// Pin hypotheses (v2, notes/sdram.md "Constant pins"): hwtest v1 drove AB10 high and saw no
// SDRAM response at all, with the DQM-candidate open-drain pins low or released. In spc.cor
// AB10 is a constant output whose unrouted DATAOUT has the inverter set, which under the
// fabric convention (unrouted = 1) is a constant 0, and the open-drain pins have DATAOUT
// unrouted without inverter, i.e. released. Each pass (re-initialise, write all 16384 rows,
// read them back, ~1 s) runs one hypothesis, in turn:
//   hyp 0: AB10 low,  open-drain pins released   (spc.cor as decoded)
//   hyp 1: AB10 low,  open-drain pins low
//   hyp 2: AB10 high, open-drain pins released   (v1, "off")
//   hyp 3: AB10 high, open-drain pins low        (v1, "low")
// Per hypothesis the last pass's error count at each capture point is kept (err_row), plus the
// raw bus words after the READ of bank 0 row 0 (raw_row: rising edges 2-7 after the READ, the
// two words expected first, and the bus while nobody drives it).
module sdram_test #(
    parameter [11:0] MRS_PINS = 12'h037,  // a[k] high for spc's MRS pattern
    parameter [11:0] ROWS     = 12'd4095, // last row tested (simulation uses fewer)
    parameter [15:0] INIT_NOP = 16'd20000 // NOP cycles before the init sequence (~270 us)
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
    output wire        dqm_low,         // drive the open-drain candidate pins low (else release)
    // status
    output reg  [15:0] passes = 0,
    output reg  [1:0]  hyp = 2'd0,      // hypothesis of the pass running now
    input  wire [1:0]  hsel,            // hypothesis shown in err_row/raw_row
    output wire [255:0] err_row,        // 8 x 32: errors at capture point 0-7, last pass of hsel
    output wire [143:0] raw_row,        // {idle, exp1, exp0, raw r7..r2} (16 bits each)
    output wire [15:0] hyp_passes       // passes run with hsel
);
    assign ab10    = hyp[1];
    assign dqm_low = hyp[0];

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
    function [15:0] pat(input [1:0] b, input [11:0] r, input [9:0] c, input [15:0] p);
        reg [31:0] x;
        begin
            x = {b, r, c, 8'd0} ^ {p, p} ^ 32'h2545F491;
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
    reg [10:0] col = 11'd0;
    reg [15:0] pass = 16'd0;
    reg        pass_end = 1'b0;         // one clock after the last read burst of a pass
    reg        raw_go = 1'b0;           // READ of bank 0 row 0 issued this cycle
    reg        idle_go = 1'b0;          // a quiet cycle in the read phase (nobody drives)
    // read-expectation stream: valid/expected word for the column the READ produces, cycle by
    // cycle from the READ command on (e[k] = k cycles later)
    reg        rv0 = 1'b0;
    reg [15:0] re0;
    reg [6:0]  rv = 0;
    reg [15:0] re [1:7];
    integer k;

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
            S_REF: begin                    // one refresh before every row (~1100 cycles apart)
                cmd(C_REF); wait_c <= 16'd10; st <= S_ACT;
            end
            S_ACT: begin
                cmd(C_ACT); sd_ba <= bank; sd_a <= row; wait_c <= 16'd3; st <= S_BURST; col <= 11'd0;
            end
            S_BURST: begin
                if (col == 11'd0) begin
                    cmd(writing ? C_WR : C_RD); sd_ba <= bank; sd_a <= 12'd0;
                    if (!writing && bank == 2'd0 && row == 12'd0) raw_go <= 1'b1;
                end
                if (writing) begin
                    sd_dq_oe  <= col != 11'd1024;
                    sd_dq_out <= pat(bank, row, col[9:0], pass);
                end else if (col != 11'd1024) begin
                    rv0 <= 1'b1;
                    re0 <= pat(bank, row, col[9:0], pass);
                end
                if (col == 11'd1024) begin  // next cycle: BURST TERMINATE
                    cmd(C_BST);
                    sd_dq_oe <= 1'b0;
                    st <= S_PRE;
                    wait_c <= writing ? 16'd3 : 16'd6;
                end
                col <= col + 11'd1;
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
    reg [15:0] c_e [3:6];
    always @(posedge clk) begin
        c_p <= dq_p;
        c_n <= dq_n2;
        c_v <= rv;
        for (k = 3; k <= 6; k = k + 1) c_e[k] <= re[k];
    end
    reg [31:0] pe [0:7];                // this pass
    reg [31:0] eh [0:31];               // [hyp*8 + point], last pass of each hypothesis
    reg [15:0] ph [0:3];
    reg [15:0] rawh [0:31];             // [hyp*8 + j]: j 0-5 raw r2..r7, 6 exp0, 7 exp1
    reg [15:0] idleh [0:3];
    reg [15:0] rs [0:7];                // raw shift for this pass
    reg [15:0] e0 = 0, e1 = 0, idle_now = 0;
    reg [3:0]  rcnt = 4'd0;
    reg [3:0]  ci = 4'd8;               // copy-out counter after a pass
    reg [1:0]  hdone = 2'd0;
    always @(posedge clk) begin
        if (c_v[2] && c_p != c_e[3]) pe[0] <= pe[0] + 1;   // rise 3
        if (c_v[2] && c_n != c_e[3]) pe[1] <= pe[1] + 1;   // fall 2.5
        if (c_v[3] && c_p != c_e[4]) pe[2] <= pe[2] + 1;   // rise 4
        if (c_v[3] && c_n != c_e[4]) pe[3] <= pe[3] + 1;   // fall 3.5
        if (c_v[4] && c_p != c_e[5]) pe[4] <= pe[4] + 1;   // rise 5
        if (c_v[4] && c_n != c_e[5]) pe[5] <= pe[5] + 1;   // fall 4.5
        if (c_v[5] && c_p != c_e[6]) pe[6] <= pe[6] + 1;   // rise 6
        if (c_v[5] && c_n != c_e[6]) pe[7] <= pe[7] + 1;   // fall 5.5
        // raw words of the first read burst: dq_p at rising edges 1..8 after the READ
        if (raw_go) begin
            rcnt <= 4'd1;
            e0 <= pat(2'd0, 12'd0, 10'd0, pass);
            e1 <= pat(2'd0, 12'd0, 10'd1, pass);
        end else if (rcnt != 4'd0 && rcnt != 4'd9) begin
            rs[rcnt[2:0] - 3'd1] <= dq_p;   // rcnt = 1 -> dq_p = pins at the READ edge + 1
            rcnt <= rcnt + 4'd1;
        end
        if (idle_go) idle_now <= dq_p;
        // end of pass: store this hypothesis's results, clear the pass counters
        if (pass_end) begin
            ci <= 4'd0;
            hdone <= hyp;
            hyp <= hyp + 2'd1;
            ph[hyp] <= ph[hyp] + 16'd1;
            idleh[hyp] <= idle_now;
            rcnt <= 4'd0;
        end else if (ci != 4'd8) begin
            eh[{hdone, ci[2:0]}] <= pe[ci[2:0]];
            pe[ci[2:0]] <= 32'd0;
            rawh[{hdone, ci[2:0]}] <= ci[2:0] == 3'd6 ? e0 : ci[2:0] == 3'd7 ? e1 : rs[ci[2:0] + 3'd1];
            ci <= ci + 4'd1;
        end
    end
    integer i;
    initial begin
        for (i = 0; i < 8; i = i + 1) begin pe[i] = 0; rs[i] = 0; end
        for (i = 0; i < 32; i = i + 1) begin eh[i] = 0; rawh[i] = 0; end
        for (i = 0; i < 4; i = i + 1) begin ph[i] = 0; idleh[i] = 0; end
    end

    // ---------------------------------------------------------------- display rows
    genvar g;
    generate for (g = 0; g < 8; g = g + 1) begin : g_rows
        assign err_row[32*g +: 32] = eh[{hsel, g[2:0]}];
    end endgenerate
    assign raw_row = {idleh[hsel], rawh[{hsel, 3'd7}], rawh[{hsel, 3'd6}], rawh[{hsel, 3'd5}],
                      rawh[{hsel, 3'd4}], rawh[{hsel, 3'd3}], rawh[{hsel, 3'd2}], rawh[{hsel, 3'd1}],
                      rawh[{hsel, 3'd0}]};
    assign hyp_passes = ph[hsel];
endmodule
