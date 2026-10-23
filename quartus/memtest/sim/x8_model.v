// SPDX-License-Identifier: GPL-3.0-or-later
// Behavioural model of one IS42S81600F (x8, 4 banks x 4096 rows x 1024 columns) as
// quartus/common/mem2_test.sv uses it: single READ/WRITE accesses (burst length 1, from the
// mode register's A0-A2 = 0), CAS latency CL with the datasheet read timing (the word of a READ
// at edge e is driven from tAC after edge e+CL-1 until tOH after edge e+CL; memtest v2 saw the
// data one clock earlier than CL3 on the console, so the testbenches use CL 2), DQM masking
// writes and read outputs. Full array (index {bank, row, column}). A10 in a WRITE = auto
// precharge (the write lands, the bank closes). Checks: mode register pins, tRCD/tRP in
// clocks, commands to closed banks; errors counted in `errors`.
`timescale 1ns/1ps
module x8_model #(
    parameter real T_AC = 5.4,
    parameter real T_OH = 2.7,
    parameter [9:0] MRS_PINS = 10'b0000001001,   // the controller's A0-A9 pins high in the MRS
    parameter NAME = "x8",
    parameter integer CL = 3,
    parameter integer STRICT = 1   // 0: accesses to a closed bank are ignored, not errors
) (
    input  wire       clk, cs_n, ras_n, cas_n, we_n, dqm,
    input  wire [9:0] a,          // the controller's pin order (any bijection of A0-A9)
    input  wire       a10, a11,
    input  wire [1:0] ba,
    inout  wire [7:0] dq
);
    reg [7:0] mem [0:(1 << 24) - 1];
    integer errors = 0, n_rd = 0, n_wr = 0, n_ref = 0, edge_n = 0;
    reg [7:0] dq_drv = 8'hzz;
    reg       drive = 1'b0;
    assign dq = drive ? dq_drv : 8'hzz;
    reg       mrs_done = 0;
    reg [3:0] open = 0;
    reg [11:0] row [0:3];
    integer   t_act [0:3], t_pre [0:3];
    // read pipeline: entries due at edge e+2 (drive from tAC) / end at edge e+3 (+tOH)
    reg [7:0] p_data [0:3];
    reg [3:0] p_v = 0;
    integer i;
    initial begin
        for (i = 0; i < (1 << 24); i = i + 1) mem[i] = 8'h00;
        for (i = 0; i < 4; i = i + 1) begin t_act[i] = -100; t_pre[i] = -100; end
    end
    wire [3:0] c = {cs_n, ras_n, cas_n, we_n};
    always @(posedge clk) begin
        edge_n = edge_n + 1;
        // output side: word whose READ was 2 edges ago starts at tAC, the one 3 edges ago ends
        if (p_v[CL-2]) begin
            dq_drv <= #T_OH 8'hxx;
            drive  <= #T_OH 1'b1;
            dq_drv <= #T_AC p_data[CL-2];
        end else if (p_v[CL-1]) begin
            dq_drv <= #T_OH 8'hzz;
            drive  <= #T_OH 1'b0;
        end
        p_v <= {p_v[2:0], 1'b0};
        p_data[1] <= p_data[0]; p_data[2] <= p_data[1]; p_data[3] <= p_data[2];
        if (!cs_n) case (c)
            4'b0011: begin                      // ACT
                if (!mrs_done) begin errors = errors + 1; $display("%t %s: ACT before MRS", $realtime, NAME); end
                if (open[ba]) begin errors = errors + 1; $display("%t %s: ACT to open bank", $realtime, NAME); end
                if (edge_n - t_pre[ba] < 2) begin errors = errors + 1; $display("%t %s: tRP", $realtime, NAME); end
                open[ba] = 1; row[ba] = {a11, a10, a}; t_act[ba] = edge_n;
            end
            4'b0101, 4'b0100: begin             // READ / WRITE
                if (!open[ba] && STRICT) begin errors = errors + 1; $display("%t %s: access to closed bank %0d", $realtime, NAME, ba); end
                if (edge_n - t_act[ba] < 2) begin errors = errors + 1; $display("%t %s: tRCD", $realtime, NAME); end
                if (!open[ba]) ;                // a real SDRAM ignores it
                else if (c == 4'b0100) begin
                    n_wr = n_wr + 1;
                    if (!dqm) mem[{ba, row[ba], a}] = dq;
                end else begin
                    if (a10) begin errors = errors + 1; $display("%t %s: READ with auto-precharge not expected", $realtime, NAME); end
                    n_rd = n_rd + 1;
                    p_v[0] <= !dqm;
                    p_data[0] <= mem[{ba, row[ba], a}];
                end
                if (a10 && open[ba]) begin open[ba] = 0; t_pre[ba] = edge_n; end
            end
            4'b0010: begin                      // PRE
                if (a10) begin open = 0; for (i = 0; i < 4; i = i + 1) t_pre[i] = edge_n; end
                else begin open[ba] = 0; t_pre[ba] = edge_n; end
            end
            4'b0001: begin
                n_ref = n_ref + 1;
                if (open != 0) begin errors = errors + 1; $display("%t %s: REF with a bank open", $realtime, NAME); end
            end
            4'b0000: begin
                if (a != MRS_PINS || a10 || a11 || ba != 0) begin
                    errors = errors + 1; $display("%t %s: MRS value %b", $realtime, NAME, a);
                end
                mrs_done = 1;
            end
            default: ;
        endcase
    end
endmodule
