// SPDX-License-Identifier: GPL-3.0-or-later
// Cycle-based model of the x8 SDRAM pair (one x16 memory, 4 banks x 4096 rows x 1024 columns)
// for the Verilator simulation of quartus/snes_sdram (Verilator has no delays; the timed model
// for iverilog is sdram_model.v).
//
// The chips' clock is the inverted clk (DDIO on AB11), so they act on the falling edge of clk:
// commands and write data registered by the FPGA on a rising edge are taken at the next falling
// edge. Read data is modelled where the FPGA samples it: counting half cycles of clk from the
// rising edge that put the READ on the pins (h = 0), burst word k is valid at the FPGA's
// input register for samples h = wlo + 2k ... whi + 2k and garbage otherwise. With the delay
// estimates of notes/snes-sdram.md (window ~3.3-4.1 cycles after the READ at 85.77 MHz) that is
// wlo = 7, whi = 8 (fall 3.5 and rise 4). wlo/whi are registers the testbench may change
// (TB_WIN) to move the window against the controller's fixed capture point.
// Full-page bursts run on until PRECHARGE of their bank, BST or another READ/WRITE (ACT doesn't
// end them; a WRITE while read data is due is an error): the burst word
// taken at the command's edge is the last one not produced, as in the datasheet (read: last
// word at PRE + CL - 1; write: no data written at the BST/PRE edge). Writes store whatever is
// on the bus (0xBAD0 when the FPGA isn't driving).
//
// Checks (counted in `errors`, first 20 printed): tRCD, tRAS, tRP, tRC, tRRD, tWR, tMRD, REF/ACT
// spacing, commands to banks in the wrong state, REF/MRS with a bank open, ACT before MRS,
// fewer than 2 REFs before MRS, mode register value, auto precharge, refresh interval
// (> REF_MAX cycles), FPGA driving DQ while the chips drive it.
module sdram_cyc #(
    parameter integer WLO = 7, WHI = 8,
    parameter integer T_RCD = 2, T_RAS = 4, T_RP = 2, T_RC = 6, T_RRD = 2, T_WR = 2, T_MRD = 2,
    parameter integer REF_MAX = 1339,            // 15.6 us at 85.77 MHz
    parameter [11:0]  MRS_EXPECT = 12'h037,
    // 10: the x16 pair as built for (1024 columns); 9: chip B as it is (512 columns per page,
    // quartus/snes_load), memory index {bank, row, column[8:0]}
    parameter integer COL_BITS = 10
) (
    input  wire        clk,
    input  wire        cs_n, ras_n, cas_n, we_n,
    input  wire [11:0] a,
    input  wire [1:0]  ba,
    input  wire [15:0] dq_fpga,
    input  wire        oe_fpga,
    output reg  [15:0] dq_chip = 16'h0000
);
    reg [15:0] mem [0:(1 << 24) - 1] /* verilator public_flat_rw */;
    reg [7:0]  wlo /* verilator public_flat_rw */ = WLO;
    reg [7:0]  whi /* verilator public_flat_rw */ = WHI;
    integer errors /* verilator public_flat_rd */ = 0;
    integer n_act /* verilator public_flat_rd */ = 0, n_rd /* verilator public_flat_rd */ = 0;
    integer n_wr /* verilator public_flat_rd */ = 0, n_ref /* verilator public_flat_rd */ = 0;
    integer max_ref_gap /* verilator public_flat_rd */ = 0;

    integer    hc = 0;                 // half-cycle index of the current edge (rising = even)
    integer    ce = 0;                 // chip clock edges (falling edges of clk)
    reg        mrs_done = 1'b0;
    integer    n_init_ref = 0;
    reg [11:0] row [0:3];
    reg [3:0]  open_b = 4'b0000;
    integer    t_act [0:3], t_pre [0:3], t_wd [0:3];
    integer    t_last_act = -100, t_ref = -100, t_mrs = -100;
    reg        rd_on = 1'b0, wr_on = 1'b0;
    integer    rd_h0 = 0, rd_k = 0;    // READ edge (half cycles) and next burst word
    reg [1:0]  bb = 2'd0;
    reg [9:0]  bc = 10'd0;
    integer    drive_until = -100;     // last half cycle the chips drive DQ
    reg [15:0] rdat [0:63];
    reg        rval [0:63];
    integer    i;
    initial begin
        for (i = 0; i < 64; i = i + 1) rval[i] = 1'b0;
        for (i = 0; i < 4; i = i + 1) begin t_act[i] = -100; t_pre[i] = -100; t_wd[i] = -100; end
    end

    task err(input [8*48-1:0] msg);
        begin
            errors = errors + 1;
            if (errors <= 20) $display("sdram_cyc: chip edge %0d: %0s", ce, msg);
        end
    endtask

    // put burst word k (READ at half cycle h0) into the sample window
    task produce(input integer h0, input integer k, input [15:0] d);
        integer s;
        begin
            for (s = h0 + wlo + 2 * k; s <= h0 + whi + 2 * k; s = s + 1) begin
                rdat[s & 63] = d;
                rval[s & 63] = 1'b1;
            end
            if (h0 + whi + 2 * k + 2 > drive_until) drive_until = h0 + whi + 2 * k + 2;
        end
    endtask

    localparam [9:0] CMASK = (10'd1 << COL_BITS) - 10'd1;
    function [23:0] mi(input [1:0] b_, input [11:0] r_, input [9:0] c_);
        mi = COL_BITS == 10 ? {b_, r_, c_} : {1'b0, b_, r_, c_[8:0]};
    endfunction
    wire [3:0] c = {cs_n, ras_n, cas_n, we_n};
    integer k;
    always @(posedge clk or negedge clk) begin
        hc = hc + 1;
        if (!clk) begin                                     // ---- chip clock edge
            ce = ce + 1;
            // burst ends: READ/WRITE (any bank), BST, PRE of its bank (ACT/REF don't end it)
            if (!cs_n && (c[2:0] == 3'b101 || c[2:0] == 3'b100 || c[2:0] == 3'b110 ||
                          (c[2:0] == 3'b010 && (a[10] || ba == bb)))) begin
                rd_on = 1'b0; wr_on = 1'b0;
            end
            if (wr_on) begin
                mem[mi(bb, row[bb], bc)] = oe_fpga ? dq_fpga : 16'hBAD0;
                t_wd[bb] = ce; bc = (bc + 10'd1) & CMASK; n_wr = n_wr + 1;
            end
            if (rd_on) begin
                produce(rd_h0, rd_k, mem[mi(bb, row[bb], bc)]);
                rd_k = rd_k + 1; bc = (bc + 10'd1) & CMASK;
            end
            if (!cs_n) case (c[2:0])
                3'b011: begin                                // ACT
                    if (!mrs_done) err("ACT before MRS");
                    if (open_b[ba]) err("ACT to an open bank");
                    if (ce - t_pre[ba] < T_RP) err("tRP");
                    if (ce - t_act[ba] < T_RC) err("tRC (ACT-ACT same bank)");
                    if (ce - t_last_act < T_RRD) err("tRRD");
                    if (ce - t_ref < T_RC) err("tRC after REF");
                    if (ce - t_mrs < T_MRD) err("tMRD");
                    row[ba] = a; open_b[ba] = 1'b1; t_act[ba] = ce; t_last_act = ce;
                    n_act = n_act + 1;
                end
                3'b101, 3'b100: begin                        // READ / WRITE
                    if (!open_b[ba]) err("READ/WRITE to an idle bank");
                    if (ce - t_act[ba] < T_RCD) err("tRCD");
                    if (a[10]) err("auto precharge");
                    bb = ba; bc = a[9:0] & CMASK;
                    if (COL_BITS < 10 && a[9]) err("column bit 9 set (512-column page)");
                    if (c[0]) begin
                        rd_on = 1'b1; rd_h0 = hc - 1; rd_k = 1;
                        produce(rd_h0, 0, mem[mi(ba, row[ba], bc)]);
                        bc = (bc + 10'd1) & CMASK; n_rd = n_rd + 1;
                    end else begin
                        for (k = 2; k < 24; k = k + 1)
                            if (rval[(hc + k) & 63]) begin
                                err("WRITE while read data is due");
                                rval[(hc + k) & 63] = 1'b0;
                            end
                        wr_on = 1'b1;
                        mem[mi(ba, row[ba], bc)] = oe_fpga ? dq_fpga : 16'hBAD0;
                        t_wd[ba] = ce; bc = (bc + 10'd1) & CMASK; n_wr = n_wr + 1;
                    end
                end
                3'b110: begin end                            // BST
                3'b010: begin                                // PRE
                    for (k = 0; k < 4; k = k + 1)
                        if (a[10] || ba == k[1:0]) begin
                            if (open_b[k] && ce - t_act[k] < T_RAS) err("tRAS");
                            if (open_b[k] && ce - t_wd[k] < T_WR) err("tWR");
                            if (open_b[k]) t_pre[k] = ce;
                            open_b[k] = 1'b0;
                        end
                end
                3'b001: begin                                // REF
                    if (open_b != 4'b0000) err("REF with a bank open");
                    for (k = 0; k < 4; k = k + 1) if (ce - t_pre[k] < T_RP) err("tRP before REF");
                    if (ce - t_ref < T_RC) err("tRC (REF-REF)");
                    if (mrs_done && ce - t_ref > max_ref_gap) max_ref_gap = ce - t_ref;
                    if (mrs_done && ce - t_ref > REF_MAX) err("refresh interval too long");
                    t_ref = ce; n_ref = n_ref + 1;
                    if (!mrs_done) n_init_ref = n_init_ref + 1;
                end
                3'b000: begin                                // MRS
                    if (open_b != 4'b0000) err("MRS with a bank open");
                    if (n_init_ref < 2) err("MRS before 2 REFs");
                    if (a != MRS_EXPECT || ba != 2'd0) err("mode register value");
                    mrs_done = 1'b1; t_mrs = ce;
                end
                default: begin end
            endcase
        end else begin                                      // ---- FPGA rising edge
            if (oe_fpga && hc <= drive_until && hc >= drive_until - (whi - wlo) - 6) err("bus contention");
        end
        // value the FPGA's input register sees at the next edge (hc + 1)
        dq_chip <= rval[(hc + 1) & 63] ? rdat[(hc + 1) & 63] : (16'hDEAD ^ hc[15:0]);
        rval[(hc + 1) & 63] = 1'b0;
    end
endmodule
