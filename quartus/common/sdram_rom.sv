// SPDX-License-Identifier: GPL-3.0-or-later
// SDRAM controller for the SNES cartridge ROM on the Super Nt's x8 SDRAM pair (notes/sdram.md,
// notes/snes-sdram.md): two IS42S81600F sharing address/command, one 16-bit memory of 4 banks x
// 4096 rows x 1024 columns = 32 MB. Word address w[23:0] -> bank w[23:22], row w[21:10],
// column w[9:0].
//
// Written to work without the uncertain parts of the pin map (as quartus/common/sdram_test.sv):
//   - the mode register gets spc.cor's pin pattern MRS_PINS (0x037 = CL3 + full-page burst if
//     the A0-A6 order is right); CL must be the CAS latency that pattern sets;
//   - every access is a single word from a full-page burst: reads are ACT, READ, PRECHARGE
//     (bank) as soon as tRAS allows, which ends the burst after word 1 (word 0 is the one used);
//     writes are ACT, WRITE + data, BURST TERMINATE in the next cycle (DQM can't mask, so the
//     burst must not go on), PRECHARGE (bank) after tWR;
//   - column address on A0-A9 with A10 = A11 = 0 (no auto precharge); precharges are single-bank
//     (A10 = 0), also in the init sequence; row and bank bit order don't matter.
// Closed-page: every bank is idle between accesses, so every read takes the same time and a
// refresh never waits for a bank.
//
// Clock: clk is the memory clock, 4 x clk_sys from the same PLL VCO, either phase-aligned with
// clk_sys or a little later (logically the same: the clk edge right after a clk_sys edge must
// still see the old clk_sys values, which the SDC checks). The SDRAM gets the inverted clk_sd
// (DDIO on AB11); clk_sd is clk itself (as quartus/hwtest) or an earlier copy from the same PLL.
// The capture register runs on clk_cap: clk itself, or a copy whose edges fall between the
// clk_sd and clk edges (it must stay less than half a cycle off clk; the enable comes from clk).
// What matters for the read window is the offset between clk_cap and clk_sd (0 in hwtest). The
// SDRAM samples commands and write data about half a cycle after they leave the output
// registers. Read data is captured at the clk_cap edge CAPTURE_HALF half-cycles after the one
// that goes with the clk edge putting the READ on the pins, in quartus/hwtest's terms
// (sdram_test.sv): rise n = 2n (posedge capture), fall n.5 = 2n + 1 (negedge capture).
// Default 7 = fall 3.5. See notes/snes-sdram.md for how to pick it from hwtest.
//
// ROM port (MiSTer sdram.sv port 0 semantics): rom_addr/rom_word come from clk_sys logic and are
// sampled every clk cycle. A read starts whenever the word address rom_addr[23:1] differs from
// the last one read (no strobe needed). Timeline, in clk cycles after the clk_sys edge E at
// which the address changed: ACT at E+1, READ at E+3, PRECHARGE at E+5, data in the capture
// register at E+3+CAPTURE_HALF/2 (E+6.5 for fall 3.5), next ACT possible at E+7. rom_q comes
// straight from the capture register. The SA-1 (SA1.vhd, one bus cycle per 2 clk_sys) and the
// SNES CPU in FastROM cycles latch ROM data at E+8 through 13-15 ns of their own logic, so the
// capture must be at E+6.5 or earlier: CAPTURE_HALF <= 7 (rise 4 = 8 works logically but leaves one clk cycle, too
// little at the slow corner). The SDC gives capture register -> clk_sys paths the matching
// multicycle (valid for reads that start at E+1, i.e. every latency-critical one). rom_q: byte
// reads at odd addresses (rom_word = 0) get the high byte in both halves, as sdram.sv.
//
// Refresh: one AUTO REFRESH (all banks idle) every <= 15.4 us, hidden between reads. A REF
// blocks the command bus for T_RC cycles, so it is only issued in a clk_sys cycle in which the
// core promises not to start a latency-critical read at the next clk_sys edge (rfsh_ok, from
// the top level; for SA-1 carts: CLK_CE = ROM_OE_N low and SYSCLKF_CE low), at the 2nd-4th clk
// edge of that cycle: it then ends by E+9 and never delays a read that starts at E+8. If no such
// slot comes for RF_HARD cycles, it is issued in any slot without a pending read (counted in
// n_rf_forced); at RF_LIMIT even ahead of a pending read (n_rf_stall).
//
// Write port: wr_req (level) with wr_addr (word address) and wr_data; wr_ack pulses for one cycle
// when the write starts (the request may be dropped or changed after it). Writes use the same
// slots as hidden refreshes while reads are enabled, and any slot while rom_en = 0.
// Aux read port (for a loader's read-modify-write of partial words): aux_req (level) with
// aux_addr (word address), aux_ack when the read starts, aux_valid (one cycle) when its data is
// on aux_q. Served only while rom_en = 0: the data goes through the ROM port's capture register.
module sdram_rom #(
    parameter integer CAPTURE_HALF = 7,       // read capture point, see above (7 = fall 3.5)
    parameter [11:0]  MRS_PINS     = 12'h037, // a[k] high for spc.cor's MRS pattern
    parameter integer CL           = 3,       // CAS latency programmed by MRS_PINS
    // Timing in clk cycles (IS42S81600F-6 at 85.77 MHz = 11.66 ns: tRCD/tRP 18 ns, tRAS 42 ns,
    // tRC 60 ns (also REF to next command), tWR 2 clocks, tMRD 2 clocks).
    parameter integer T_RCD        = 2,
    parameter integer T_RAS        = 4,
    parameter integer T_RP         = 2,
    parameter integer T_RC         = 6,
    parameter integer T_WR         = 2,
    parameter integer T_MRD        = 2,
    parameter integer INIT_CYCLES  = 17200,   // NOP time after power-up (200 us at 85.77 MHz)
    parameter integer INIT_REFS    = 8,
    parameter integer RF_SOFT      = 640,     // refresh wanted after 7.5 us
    parameter integer RF_HARD      = 1200,    // ... in any idle slot after 14 us
    parameter integer RF_LIMIT     = 1320     // ... unconditionally after 15.4 us
) (
    input  wire        clk,             // memory clock, 4 x clk_sys, phase-aligned
    input  wire        clk_sd,          // SDRAM clock source for the DDIO on AB11: clk, or an
                                        // earlier copy of it (see "Clock" above)
    input  wire        clk_cap,         // read-capture register clock: clk, or a copy of it at
                                        // another phase (see "Clock" above)
    input  wire        reset,           // synchronous; restarts the init sequence
    output reg         ready = 1'b0,    // init done

    // clk_sys phase: any signal that toggles on every clk_sys edge (from a clk_sys register)
    input  wire        sys_tog,

    // ROM read port (signals from clk_sys registers / logic)
    input  wire        rom_en,          // 1: serve reads (0 while loading)
    input  wire [23:0] rom_addr,        // byte address
    input  wire        rom_word,
    output wire [15:0] rom_q,
    input  wire        rfsh_ok,         // no critical read can start at the next clk_sys edge

    // write port (clk domain)
    input  wire        wr_req,
    input  wire [23:0] wr_addr,         // word address
    input  wire [15:0] wr_data,
    output reg         wr_ack = 1'b0,

    // aux read port (clk domain, only while rom_en = 0)
    input  wire        aux_req,
    input  wire [23:0] aux_addr,        // word address
    output reg         aux_ack = 1'b0,
    output reg         aux_valid = 1'b0,
    output wire [15:0] aux_q,

    // SDRAM pins
    output wire        sd_clk,
    output reg         sd_cs_n = 1'b1,
    output reg         sd_ras_n = 1'b1,
    output reg         sd_cas_n = 1'b1,
    output reg         sd_we_n = 1'b1,
    output reg  [11:0] sd_a = 12'd0,
    output reg  [1:0]  sd_ba = 2'd0,
    input  wire [15:0] sd_dq_in,
    output reg  [15:0] sd_dq_out = 16'd0,
    output reg         sd_dq_oe = 1'b0,

    // statistics (saturating 16-bit counters, for simulation and debug screens)
    output reg  [15:0] n_rf_forced = 16'd0, // refreshes issued in a slot without rfsh_ok
    output reg  [15:0] n_rf_stall = 16'd0,  // refreshes that delayed a pending read
    output reg  [15:0] n_late = 16'd0,      // reads whose data came > 6 cycles after the address
                                            // changed (i.e. after the SA-1's deadline)
    output reg  [10:0] rf_max = 11'd0       // longest REF-to-REF interval seen (cycles)
);
    // ------------------------------------------------------------------ SDRAM clock
    altddio_out #(
        .extend_oe_disable("OFF"), .intended_device_family("Cyclone V"),
        .invert_output("OFF"), .lpm_hint("UNUSED"), .lpm_type("altddio_out"),
        .oe_reg("UNREGISTERED"), .power_up_high("OFF"), .width(1)
    ) clk_ddio (
        .datain_h(1'b0), .datain_l(1'b1), .outclock(clk_sd), .dataout(sd_clk),
        .aclr(1'b0), .aset(1'b0), .oe(1'b1), .oe_out(), .outclocken(1'b1), .sclr(1'b0), .sset(1'b0)
    );

    // ------------------------------------------------------------------ constants
    localparam [3:0] C_NOP = 4'b0111, C_ACT = 4'b0011, C_RD = 4'b0101, C_WR = 4'b0100,
                     C_BST = 4'b0110, C_PRE = 4'b0010, C_REF = 4'b0001, C_MRS = 4'b0000;
    function integer imax(input integer x, input integer y);
        imax = x > y ? x : y;
    endfunction
    // command offsets from ACT
    localparam integer RD_PRE = imax(T_RAS, T_RCD + 1);
    localparam integer RD_END = imax(RD_PRE + T_RP, T_RC);           // next ACT/REF allowed
    localparam integer WR_PRE = imax(T_RAS, T_RCD + T_WR);
    localparam integer WR_END = imax(WR_PRE + T_RP, T_RC);
    localparam integer CAP_N  = CAPTURE_HALF / 2;
    localparam integer CAP_F  = CAPTURE_HALF % 2;
    localparam integer READY_AT = T_RCD + CAP_N + CAP_F;            // ACT -> rom_q (rounded up)

    // ------------------------------------------------------------------ clk_sys phase
    // first: this clk edge is the first one after a clk_sys edge (phase 1); ph_now = phase of
    // the current edge (0 = coincides with a clk_sys edge).
    reg       tog_d = 1'b0;
    reg [1:0] ph = 2'd0;
    wire      first  = sys_tog ^ tog_d;
    wire [1:0] ph_now = first ? 2'd1 : ph;
    always @(posedge clk) begin
        tog_d <= sys_tog;
        ph    <= ph_now + 2'd1;
    end

    // ------------------------------------------------------------------ requests
    reg  [22:0] last_w = 23'd0;         // word address of the last read started
    reg         last_ok = 1'b0;
    wire        rd_req = rom_en && ready && (!last_ok || rom_addr[23:1] != last_w);
    wire        quiet  = !rom_en || rfsh_ok;
    wire        slot   = ph_now != 2'd0 && quiet;   // a 6-cycle op here never delays an SA-1 read

    reg  [10:0] rcnt = 11'd0;           // cycles since the last REF (saturating)
    wire        rf_soft  = rcnt >= RF_SOFT;
    wire        rf_hard  = rcnt >= RF_HARD;
    wire        rf_limit = rcnt >= RF_LIMIT;

    // ------------------------------------------------------------------ sequencer
    localparam [2:0] S_POWER = 0, S_INIT = 1, S_IDLE = 2, S_READ = 3, S_WRITE = 4, S_WAIT = 5;
    reg  [2:0]  st = S_POWER;
    reg  [14:0] cnt = 15'd0;            // power-up wait / step counter
    reg  [4:0]  istep = 5'd0;           // init sequence step
    reg  [3:0]  iwait = 4'd0;           // init: cycles to wait before the next command
    reg  [1:0]  bank;
    reg  [9:0]  col;
    reg  [15:0] wdat;
    reg  [6:0]  rdp = 7'd0;             // rdp[k]: the READ left the pins k cycles ago
    reg  [7:0]  rda = 8'd0;             // the same for aux reads
    reg         aux_rd = 1'b0;          // the read in progress is an aux read
    reg  [3:0]  age = 4'd0;             // cycles a read request has been waiting

    task cmd(input [3:0] c);
        {sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n} <= c;
    endtask

    always @(posedge clk) begin
        cmd(C_NOP);
        sd_a     <= 12'd0;
        sd_dq_oe <= 1'b0;
        wr_ack   <= 1'b0;
        aux_ack  <= 1'b0;
        rdp      <= {rdp[5:0], 1'b0};
        rda      <= {rda[6:0], 1'b0};
        cnt      <= cnt + 15'd1;
        if (rcnt != 11'h7ff) rcnt <= rcnt + 11'd1;
        age      <= rd_req ? (age == 4'hf ? age : age + 4'd1) : 4'd0;

        case (st)
            S_POWER: begin                      // NOP for INIT_CYCLES
                ready   <= 1'b0;
                last_ok <= 1'b0;
                istep   <= 5'd0;
                iwait   <= 4'd0;
                if (cnt == INIT_CYCLES[14:0]) begin
                    st  <= S_INIT;
                    cnt <= 15'd0;
                end
            end
            S_INIT: begin
                // PRECHARGE banks 0-3 (one per cycle, A10 = 0), wait tRP; INIT_REFS x REF, T_RC
                // apart; MRS; ready T_MRD later.
                if (iwait != 4'd0)
                    iwait <= iwait - 4'd1;
                else if (istep < 5'd4) begin
                    cmd(C_PRE); sd_ba <= istep[1:0];
                    istep <= istep + 5'd1;
                    if (istep == 5'd3) iwait <= T_RP[3:0] - 4'd1;
                end else if (istep < 5'd4 + INIT_REFS[4:0]) begin
                    cmd(C_REF);
                    rcnt  <= 11'd0;
                    istep <= istep + 5'd1;
                    iwait <= T_RC[3:0] - 4'd1;
                end else if (istep == 5'd4 + INIT_REFS[4:0]) begin
                    cmd(C_MRS); sd_ba <= 2'd0; sd_a <= MRS_PINS;
                    istep <= istep + 5'd1;
                    iwait <= T_MRD[3:0];
                end else begin
                    st    <= S_IDLE;
                    ready <= 1'b1;
                end
            end
            S_IDLE: begin
                cnt <= 15'd1;                   // S_READ/S_WRITE/S_WAIT count from ACT/REF = 0
                if (rf_limit || (!rd_req && ((rf_soft && slot) || (rf_hard && ph_now != 2'd0)))) begin
                    cmd(C_REF);
                    if (rcnt > rf_max) rf_max <= rcnt;
                    rcnt <= 11'd0;
                    st   <= S_WAIT;
                    if (rd_req) begin
                        if (n_rf_stall != 16'hffff) n_rf_stall <= n_rf_stall + 16'd1;
                    end else if (!(rf_soft && slot)) begin
                        if (n_rf_forced != 16'hffff) n_rf_forced <= n_rf_forced + 16'd1;
                    end
                end else if (rd_req) begin
                    cmd(C_ACT); sd_ba <= {1'b0, rom_addr[23]}; sd_a <= rom_addr[22:11];
                    bank    <= {1'b0, rom_addr[23]};
                    col     <= rom_addr[10:1];
                    last_w  <= rom_addr[23:1];
                    last_ok <= 1'b1;
                    // (the first read after enabling reads or a write isn't timed by a CPU)
                    if (last_ok && age + READY_AT > 6 && n_late != 16'hffff) n_late <= n_late + 16'd1;
                    // synthesis translate_off
                    if (last_ok && age + READY_AT > 6) $display("sdram_rom: late read %h (waited %0d cycles) at %0t", rom_addr, age, $time);
                    // synthesis translate_on
                    aux_rd <= 1'b0;
                    st <= S_READ;
                end else if (aux_req && !rom_en) begin
                    cmd(C_ACT); sd_ba <= aux_addr[23:22]; sd_a <= aux_addr[21:10];
                    bank    <= aux_addr[23:22];
                    col     <= aux_addr[9:0];
                    aux_ack <= 1'b1;
                    aux_rd  <= 1'b1;
                    last_ok <= 1'b0;            // rd_word no longer holds the ROM port's word
                    st <= S_READ;
                end else if (wr_req && (!rom_en || slot)) begin
                    cmd(C_ACT); sd_ba <= wr_addr[23:22]; sd_a <= wr_addr[21:10];
                    bank    <= wr_addr[23:22];
                    col     <= wr_addr[9:0];
                    wdat    <= wr_data;
                    wr_ack  <= 1'b1;
                    last_ok <= 1'b0;            // the ROM port re-reads after any write
                    st <= S_WRITE;
                end
            end
            S_READ: begin
                if (cnt == T_RCD[14:0]) begin
                    cmd(C_RD); sd_ba <= bank; sd_a <= {2'b00, col};
                    rdp[0] <= 1'b1;
                    rda[0] <= aux_rd;
                end
                if (cnt == RD_PRE[14:0]) begin cmd(C_PRE); sd_ba <= bank; end
                if (cnt == RD_END[14:0] - 15'd1) st <= S_IDLE;
            end
            S_WRITE: begin
                if (cnt == T_RCD[14:0]) begin
                    cmd(C_WR); sd_ba <= bank; sd_a <= {2'b00, col};
                    sd_dq_out <= wdat;
                    sd_dq_oe  <= 1'b1;
                end
                if (cnt == T_RCD[14:0] + 15'd1) begin cmd(C_BST); sd_ba <= bank; end
                if (cnt == WR_PRE[14:0]) begin cmd(C_PRE); sd_ba <= bank; end
                if (cnt == WR_END[14:0] - 15'd1) st <= S_IDLE;
            end
            S_WAIT: begin                       // after REF
                if (cnt == T_RC[14:0] - 15'd1) st <= S_IDLE;
            end
            default: st <= S_POWER;
        endcase
        if (reset) begin
            st    <= S_POWER;
            cnt   <= 15'd0;
            ready <= 1'b0;
        end
    end

    // ------------------------------------------------------------------ read capture
    // rdp[k] is high during the clk cycle that starts k cycles after the READ edge R.
    reg  [15:0] cap = 16'd0;            // capture register (IOE input register if packed)
    wire [15:0] rd_word;
    generate
        if (CAP_F == 0) begin : g_rise
            // rise n: posedge R+n
            always @(posedge clk_cap) if (rdp[CAP_N - 1]) cap <= sd_dq_in;
            always @(posedge clk) aux_valid <= rda[CAP_N - 1];
            assign rd_word = cap;
        end else begin : g_fall
            // fall n.5: negedge R+n+0.5
            always @(negedge clk_cap) if (rdp[CAP_N]) cap <= sd_dq_in;
            always @(posedge clk) aux_valid <= rda[CAP_N];
            assign rd_word = cap;
        end
    endgenerate
    wire rom_hi = rom_addr[0] & ~rom_word;
    assign rom_q = rom_hi ? {rd_word[15:8], rd_word[15:8]} : rd_word;
    assign aux_q = rd_word;
endmodule
