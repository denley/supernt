// SPDX-License-Identifier: GPL-3.0-or-later
// Timed behavioural model of the Super Nt's x8 SDRAM pair used as one x16 memory (two
// IS42S81600F-6, notes/sdram.md), for iverilog (make sim-sdram-rom). Extends
// quartus/hwtest/sim/sdram_model.v to the full geometry (4 banks x 4096 rows x 1024 columns x
// 16 bits) with protocol and timing checks.
//
// Read timing per the datasheet convention: with CAS latency CL, the word that is "available at
// edge READ+CL" is driven from tAC after edge READ+CL-1 until tOH after edge READ+CL (between
// those, the bus holds the previous word up to tOH and is undefined (X) from tOH to tAC).
// (quartus/hwtest/sim/sdram_model.v puts it one edge later: valid from READ+CL+tAC.)
// Full-page bursts: a READ/WRITE burst runs on through the page on NOP/deselect cycles until
// BURST TERMINATE, PRECHARGE or another READ/WRITE. Truncation by BST/PRE at edge p: the last
// read word is the one available at p+CL-1; for writes, the data at the BST/PRE edge is not
// written. Write bursts store whatever is on DQ (X/Z included) so a missing BST shows up as
// corrupted neighbours.
//
// Checks (errors counted in `errors`, printed): command/address/DQ setup and hold around the
// clock edge, tRCD, tRAS, tRP, tRC, tRRD, tWR, tMRD, tRC after REF, commands to the wrong bank
// state, REF/MRS with a bank open, ACT before MRS, mode register value, interval between REFs
// (max kept in max_ref_gap).
`timescale 1ns/1ps
module is42s_model #(
    parameter real T_AC  = 5.4,     // access time from clock (CL3, -6)
    parameter real T_OH  = 2.7,     // output hold
    parameter real T_HZ  = 5.4,     // output to high-Z after the last word
    parameter real T_LZ  = 1.0,     // output turns on (undefined data) after the clock
    parameter real T_IS  = 1.5,     // command/address/data setup
    parameter real T_IH  = 0.8,     // hold
    parameter real T_RCD = 18.0,
    parameter real T_RAS = 42.0,
    parameter real T_RP  = 18.0,
    parameter real T_RC  = 60.0,
    parameter real T_RRD = 12.0,
    parameter integer T_WR_CLK  = 2,   // last write data to PRECHARGE, clocks
    parameter integer T_MRD_CLK = 2,
    parameter [11:0] MRS_EXPECT = 12'h037,
    parameter real REF_MAX = 15625.0,  // longest allowed REF interval (ns), checked after init
    // 10: the x16 pair as built for (1024 columns); 9: chip B as it is (512 columns per page,
    // notes/sdram.md; quartus/snes_load), memory index {bank, row, column[8:0]}
    parameter integer COL_BITS = 10
) (
    input  wire        clk, cs_n, ras_n, cas_n, we_n,
    input  wire [11:0] a,
    input  wire [1:0]  ba,
    inout  wire [15:0] dq
);
    reg [15:0] mem [0:(1 << 24) - 1];
    integer errors = 0, n_act = 0, n_rd = 0, n_wr = 0, n_ref = 0;
    real    max_ref_gap = 0.0;

    // ---------------------------------------------------------------- output driver
    reg [15:0] dq_drv = 16'hzzzz;
    reg        drive = 1'b0;
    assign dq = drive ? dq_drv : 16'hzzzz;

    // ---------------------------------------------------------------- setup/hold checks
    wire [17:0] cmd_bus = {cs_n, ras_n, cas_n, we_n, a, ba};
    realtime t_cmd = 0, t_dq = 0, t_edge = -100, t_wedge = -100;
    always @(cmd_bus) begin
        t_cmd = $realtime;
        if ($realtime - t_edge < T_IH && $realtime > 1) begin
            errors = errors + 1;
            $display("%t SDRAM: command/address hold violation (%0.2f ns after the edge)", $realtime, $realtime - t_edge);
        end
    end
    always @(dq) t_dq = $realtime;

    // ---------------------------------------------------------------- state
    reg        mrs_done = 0;
    integer    cl = 3, n_init_ref = 0;
    reg [11:0] row [0:3];
    reg [3:0]  open = 4'b0000;
    realtime   t_act [0:3], t_pre [0:3], t_wdata [0:3];
    realtime   t_last_act = -1000, t_ref = -1000, t_ref_prev = -1, t_mrs = -1000;
    integer    edge_n = 0, mrs_edge = -100, wdata_edge [0:3];
    // burst state
    reg        rd_on = 0, wr_on = 0;
    reg [1:0]  bb;
    reg [9:0]  bc;
    // read output queue: q*[i] = word available at edge (current + i)
    reg [15:0] qd [0:7];
    reg        qv [0:7];
    integer    i, k;
    initial begin
        for (i = 0; i < 8; i = i + 1) qv[i] = 0;
        for (i = 0; i < 4; i = i + 1) begin
            t_act[i] = -1000; t_pre[i] = -1000; t_wdata[i] = -1000; wdata_edge[i] = -100;
        end
    end

    task err(input [8*64-1:0] msg);
        begin
            errors = errors + 1;
            $display("%t SDRAM: %0s", $realtime, msg);
        end
    endtask

    localparam [9:0] CMASK = (10'd1 << COL_BITS) - 10'd1;
    function [23:0] mi(input [1:0] b_, input [11:0] r_, input [9:0] c_);
        mi = COL_BITS == 10 ? {b_, r_, c_} : {1'b0, b_, r_, c_[8:0]};
    endfunction
    wire [23:0] rd_index = mi(bb, row[bb], bc);
    always @(posedge clk) begin
        edge_n = edge_n + 1;
        t_edge = $realtime;
        if ($realtime - t_cmd < T_IS && !cs_n) err("command/address setup violation");
        // read queue moves one edge on
        for (i = 0; i < 7; i = i + 1) begin qd[i] = qd[i + 1]; qv[i] = qv[i + 1]; end
        qv[7] = 0;
        // write data at this edge (burst continuing, or a new WRITE below)
        if (wr_on && !cs_n && {ras_n, cas_n, we_n} != 3'b111)
            wr_on = 0;                           // any command ends the write burst
        if (wr_on) begin
            if ($realtime - t_dq < T_IS) err("write data setup violation");
            mem[mi(bb, row[bb], bc)] = dq;
            n_wr = n_wr + 1;
            t_wdata[bb] = $realtime; wdata_edge[bb] = edge_n; t_wedge = $realtime;
            bc = (bc + 1) & CMASK;
        end
        if (rd_on && !cs_n && {ras_n, cas_n, we_n} != 3'b111) rd_on = 0;   // truncated (BST/PRE/...)
        if (rd_on) begin
            qd[cl] = mem[rd_index]; qv[cl] = 1; bc = (bc + 1) & CMASK;
        end
        if (!cs_n) case ({ras_n, cas_n, we_n})
            3'b011: begin                                            // ACT
                if (!mrs_done) err("ACT before MRS");
                if (open[ba]) err("ACT to an open bank");
                if ($realtime - t_pre[ba] < T_RP - 0.01) err("tRP (ACT after PRE)");
                if ($realtime - t_act[ba] < T_RC - 0.01) err("tRC (ACT to ACT, same bank)");
                if ($realtime - t_last_act < T_RRD - 0.01) err("tRRD (ACT to ACT)");
                if ($realtime - t_ref < T_RC - 0.01) err("tRC after REF");
                if (edge_n - mrs_edge < T_MRD_CLK) err("tMRD");
                row[ba] = a; open[ba] = 1; t_act[ba] = $realtime; t_last_act = $realtime;
                n_act = n_act + 1;
            end
            3'b101, 3'b100: begin                                    // READ / WRITE
                if (!open[ba]) err("READ/WRITE to an idle bank");
                if ($realtime - t_act[ba] < T_RCD - 0.01) err("tRCD");
                if (a[10]) err("auto precharge (A10 = 1) not expected");
                bb = ba; bc = a[9:0] & CMASK;
                if (COL_BITS < 10 && a[9]) err("column bit 9 set (512-column page)");
                if (we_n) begin
                    rd_on = 1; wr_on = 0;
                    qd[cl] = mem[mi(ba, row[ba], bc)]; qv[cl] = 1; bc = (bc + 1) & CMASK;
                    n_rd = n_rd + 1;
                end else begin
                    rd_on = 0; wr_on = 1;
                    if ($realtime - t_dq < T_IS) err("write data setup violation");
                    mem[mi(ba, row[ba], bc)] = dq;
                    n_wr = n_wr + 1;
                    t_wdata[ba] = $realtime; wdata_edge[ba] = edge_n; t_wedge = $realtime;
                    bc = (bc + 1) & CMASK;
                end
            end
            3'b110: begin end                                        // BURST TERMINATE
            3'b010: begin                                            // PRECHARGE
                for (k = 0; k < 4; k = k + 1)
                    if (a[10] || ba == k) begin
                        if (open[k] && $realtime - t_act[k] < T_RAS - 0.01) err("tRAS");
                        if (open[k] && edge_n - wdata_edge[k] < T_WR_CLK) err("tWR");
                        if (open[k]) t_pre[k] = $realtime;
                        open[k] = 0;
                    end
            end
            3'b001: begin                                            // AUTO REFRESH
                if (open != 4'b0000) err("REF with a bank open");
                for (k = 0; k < 4; k = k + 1)
                    if ($realtime - t_pre[k] < T_RP - 0.01) err("tRP (REF after PRE)");
                if ($realtime - t_ref < T_RC - 0.01) err("tRC (REF to REF)");
                if (mrs_done && t_ref > 0 && $realtime - t_ref > max_ref_gap)
                    max_ref_gap = $realtime - t_ref;
                if (mrs_done && t_ref > 0 && $realtime - t_ref > REF_MAX) err("refresh interval too long");
                t_ref = $realtime;
                n_ref = n_ref + 1;
                if (!mrs_done) n_init_ref = n_init_ref + 1;
            end
            3'b000: begin                                            // MODE REGISTER SET
                if (open != 4'b0000) err("MRS with a bank open");
                if (n_init_ref < 2) err("MRS before 2 REFs");
                if (a !== MRS_EXPECT) err("unexpected mode register value");
                if (ba != 2'b00) err("MRS with BA != 0");
                cl = a[6:4];
                if (cl != 2 && cl != 3) err("CAS latency not 2 or 3");
                if (a[2:0] != 3'b111) err("burst length not full page");
                mrs_done = 1; mrs_edge = edge_n;
            end
            default: begin end                                       // NOP
        endcase
        // drive the bus: the word available at the next edge becomes valid tAC from now, the
        // current word stays until tOH, then X (or high-Z after tHZ if nothing follows)
        if (qv[1]) begin
            if (qv[0]) dq_drv <= #(T_OH) 16'hxxxx;
            else begin drive <= #(T_LZ) 1'b1; dq_drv <= #(T_LZ) 16'hxxxx; end
            dq_drv <= #(T_AC) qd[1];
        end else if (qv[0]) begin
            dq_drv <= #(T_OH) 16'hxxxx;
            drive  <= #(T_HZ) 1'b0;
        end
    end

    // write data hold check: DQ must not change within tIH after an edge that stored a word
    always @(dq)
        if ($realtime - t_wedge < T_IH) begin
            errors = errors + 1;
            $display("%t SDRAM: write data hold violation", $realtime);
        end
endmodule
