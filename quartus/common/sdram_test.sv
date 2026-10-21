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
// the clock edge that puts the READ command on the pins: err0/2/4/6 = rising edge 3/4/5/6
// cycles later, err1/3/5/7 = falling edge 2.5/3.5/4.5/5.5 cycles later. The chips see the
// command at 0.5, so with CL3 data is valid from ~3.5 + tAC to ~4.5 + tOH, later by the I/O and
// board delays: err5, err2 or later expected (sim/sdram_model.v without I/O delays: err2 and
// err5 pass). err[k] counts mismatching words, so one run on the console shows which works.
// Each pass writes all 16384 rows (data = hash of bank/row/column/pass), then reads them all
// back (~0.5 s per pass at 74.25 MHz). Passes alternate the DQM-candidate pins between driven
// low (as spc.cor appears to) and released (notes/sdram.md): errors are counted separately
// for the two (err_dqm0 / err_dqmz, best candidate only).
module sdram_test #(
    parameter [11:0] MRS_PINS = 12'h037,  // a[k] high for spc's MRS pattern
    parameter [11:0] ROWS     = 12'd4095  // last row tested (simulation uses fewer)
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
    output reg         dqm_low = 1'b0,  // drive the DQM-candidate pins low (else release them)
    // status
    output reg  [31:0] err0 = 0, err1 = 0, err2 = 0, err3 = 0, err4 = 0, err5 = 0, err6 = 0, err7 = 0,
    output reg  [15:0] passes = 0,
    output reg  [31:0] err_dqm0 = 0, err_dqmz = 0,  // per DQM mode, candidate with fewest errors
    output reg  [31:0] first_bad = 32'hFFFFFFFF,     // {bank, row, col} of the first err5 miss
    output reg  [15:0] first_got = 0, first_exp = 0
);
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

    function [15:0] pat(input [1:0] b, input [11:0] r, input [9:0] c, input [15:0] p);
        reg [31:0] x;
        begin
            x = {b, r, c, 8'd0} ^ {p, p};
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
    reg [15:0] wait_c = 16'd20000;      // ~270 us power-up NOP
    reg [3:0]  n = 4'd0;
    reg        writing = 1'b1;
    reg [1:0]  bank = 2'd0;
    reg [11:0] row = 12'd0;
    reg [10:0] col = 11'd0;
    reg [15:0] pass = 16'd0;
    // read-expectation stream: valid/expected word for the column the READ produces, cycle by
    // cycle from the READ command on (e[k] = k cycles later)
    reg        rv0 = 1'b0;
    reg [15:0] re0;
    reg [21:0] rad0;                    // {bank, row, col} for diagnostics
    reg [6:0]  rv = 0;
    reg [15:0] re [1:7];
    reg [21:0] rad [1:7];
    integer k;

    always @(posedge clk) begin
        cmd(C_NOP);
        sd_a <= 12'd0;
        rv0 <= 1'b0;
        if (wait_c != 16'd0)
            wait_c <= wait_c - 16'd1;
        else case (st)
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
                end
                if (writing) begin
                    sd_dq_oe  <= col != 11'd1024;
                    sd_dq_out <= pat(bank, row, col[9:0], pass);
                end else if (col != 11'd1024) begin
                    rv0 <= 1'b1;
                    re0 <= pat(bank, row, col[9:0], pass);
                    rad0 <= {bank, row, col[9:0]};
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
                        if (!writing) begin
                            pass <= pass + 16'd1;
                            passes <= passes + 16'd1;
                            dqm_low <= ~dqm_low;
                        end
                        writing <= ~writing;
                    end else
                        row <= row + 12'd1;
                end else
                    bank <= bank + 2'd1;
            end
            default: st <= S_INIT;
        endcase
        if (st == S_INIT && wait_c == 16'd20000) dqm_low <= 1'b1;   // first pass: DQM driven low
        // expectation pipeline
        rv <= {rv[5:0], rv0};
        re[1] <= re0; rad[1] <= rad0;
        for (k = 2; k <= 7; k = k + 1) begin
            re[k] <= re[k-1];
            rad[k] <= rad[k-1];
        end
    end

    // ---------------------------------------------------------------- compare
    // rv[k] is high k+1 cycles after the READ appeared on the pins (cycle T); dq_p then holds the
    // pins at rising edge T+k+1 and dq_n2 those at falling edge T+k+0.5.
    reg [31:0] pass_err [0:7];
    reg [31:0] pe_snap [0:7];
    reg [31:0] bestr = 32'd0;
    reg [3:0]  mi = 4'd9;
    reg        mode_snap = 1'b1;
    reg        dqm_this = 1'b1;
    reg        pass_d = 1'b0;
    always @(posedge clk) begin
        // rv[k-1] marks the expectation k cycles after the command left our register
        if (rv[2] && dq_p  !== re[3]) begin err0 <= err0 + 1; pass_err[0] <= pass_err[0] + 1; end  // rise 3
        if (rv[2] && dq_n2 !== re[3]) begin err1 <= err1 + 1; pass_err[1] <= pass_err[1] + 1; end  // fall 2.5
        if (rv[3] && dq_p  !== re[4]) begin err2 <= err2 + 1; pass_err[2] <= pass_err[2] + 1; end  // rise 4
        if (rv[3] && dq_n2 !== re[4]) begin err3 <= err3 + 1; pass_err[3] <= pass_err[3] + 1; end  // fall 3.5
        if (rv[4] && dq_p  !== re[5]) begin err4 <= err4 + 1; pass_err[4] <= pass_err[4] + 1; end  // rise 5
        if (rv[5] && dq_p  !== re[6]) begin err6 <= err6 + 1; pass_err[6] <= pass_err[6] + 1; end  // rise 6
        if (rv[5] && dq_n2 !== re[6]) begin err7 <= err7 + 1; pass_err[7] <= pass_err[7] + 1; end  // fall 5.5
        if (rv[4] && dq_n2 !== re[5]) begin                                                         // fall 4.5
            err5 <= err5 + 1; pass_err[5] <= pass_err[5] + 1;
            if (first_bad == 32'hFFFFFFFF) begin
                first_bad <= {10'd0, rad[5]}; first_got <= dq_n2; first_exp <= re[5];
            end
        end
        // At the end of each pass, add the best candidate's count to the total for the DQM mode
        // the pass ran with: snapshot the counts, then find the minimum one per cycle (the
        // pass is ~0.5 s long, so there is no hurry).
        pass_d <= passes[0];
        if (pass_d != passes[0]) begin
            for (k = 0; k < 8; k = k + 1) begin
                pe_snap[k] <= pass_err[k];
                pass_err[k] <= 0;
            end
            mode_snap <= dqm_this;
            dqm_this  <= dqm_low;
            mi    <= 4'd0;
            bestr <= 32'hFFFFFFFF;
        end else if (mi < 4'd8) begin
            if (pe_snap[mi[2:0]] < bestr) bestr <= pe_snap[mi[2:0]];
            mi <= mi + 4'd1;
        end else if (mi == 4'd8) begin
            if (mode_snap) err_dqm0 <= err_dqm0 + bestr;
            else           err_dqmz <= err_dqmz + bestr;
            mi <= 4'd9;
        end
    end
    initial for (k = 0; k < 8; k = k + 1) pass_err[k] = 0;
endmodule
