// SPDX-License-Identifier: GPL-3.0-or-later
// SDRAM controller for the SNES cartridge ROM on chip B alone (notes/snes-load.md): the Super
// Nt's x8 pair answers only on its high byte (chip B, bank 3B; chip A never drives,
// notes/sdram.md), so the ROM lives in one 8-bit memory of 4 banks x 4096 rows x 512 columns =
// 8 MB. Byte address b[22:0] -> bank b[22:21], row b[20:9], column b[8:0]. Derived from
// sdram_rom.sv (same command set, MRS pattern, closed-page single accesses, refresh hidden in
// slots the core announces), but run at **5 x clk_sys** (107.21 MHz), not 4 x:
//
//   - edges of clk after a clk_sys edge E: k = 0 (coincides with E: the core's signals are still
//     the old ones), 1, 2, 3, 4. The core's ROM address may still be settling at k = 0 and 1, so
//     no ROM read starts there and the address registers don't load from it; a read for an
//     address that changed at E starts with ACT at k = 2 (the address path has two cycles), READ
//     at k = 4, and the byte is captured at rise 4 after the READ (CAPTURE_HALF 8: E + 8, plus
//     the capture clock's offset); the SA-1 / SNES CPU take it at E + 10 (one SA-1 bus cycle = 2
//     clk_sys = 10 clk). At 4 x the same path had one cycle for the address and 1.5 for the data,
//     which the full 22-bit address compare didn't fit (notes/snes-load.md);
//   - every access is a byte; the command/address pins and both DQ bytes are driven as in
//     sdram_rom.sv (chip A's DQ pins get the same byte on writes, as spc.cor's controller drives
//     them too), reads use DQ[15:8] only;
//   - byte A lands in `cap`, the I/O-cell input register, and stays there until after the core
//     took it (k = 10). When A is even, a second READ of A + 1 follows two cycles later (same row
//     and page): its byte lands in the same `cap` two cycles after the first, just after byte A
//     has been copied to `cap_lo` at k = 10. So both bytes of a word go through one register and
//     one capture point;
//   - rom_q = {cap, lo_sel ? cap_lo : cap}: until the copy both lanes carry byte A (every consumer
//     in main.v picks its lane by address bit 0, or uses lane 0 with rom_word = 0); after an even
//     start the word is complete: {A + 1, A}. Only the SA-1's variable-length bit processing (VBP)
//     takes a whole word in the cycle it addressed it: quartus/snes_load builds SA1.vhd with
//     sa1_vbp.patch, which takes it one SA-1 cycle later while the address stays;
//   - a new read starts when rom_q doesn't hold the byte asked for: another word, or the same word
//     after an odd start (only A valid), or any other byte with rom_word = 0;
//   - refresh: a REF (T_RC cycles) only at k = 2-4 of a clk_sys cycle with rfsh_ok (no critical
//     read can start at the next clk_sys edge) and no read pending; it then ends before any read
//     that starts at k = 2 after the next edge but one. Forced after RF_HARD, unconditional at
//     RF_LIMIT, as in sdram_rom.sv.
//
// Ports as sdram_rom.sv (see there), except: rom_addr is a byte address and rom_q as above; the
// write port and the aux read port take byte addresses and 8-bit data, and both are served only
// while rom_en = 0 (the loader's case). Timing constraints that go with it: snes_load.sdc.
//
// ARAM port (the SPC700's 64 KB, quartus/snes_load v2: bank 3 at byte 0x600000 + address, so the
// ROM may use banks 0-2 = 6 MB). The S-DSP/SPC700 make one RAM access per DSP substep (~5.2
// clk_sys, address set at a clk_sys edge, data taken at the next DSP CE edge >= 5 clk_sys = 25
// clk later, writes at every clk_sys edge of the substep). The controller samples the port at
// k = 2 (settled; ar_q changes only at k = 3), posts writes in a 4-entry queue (consecutive duplicates dropped, a write to
// the address in ar_q updates ar_q, reads of a queued address are answered from the queue) and
// runs one bank-3 operation at a time, started only at k = 0 in command slots the ROM schedule
// never uses (slot s = clk edges after the start, ROM read with ACT at slot a: a+2 READ, a+4
// second READ, a+5 PRECHARGE, ACTs only at k = 2-4):
//   - start allowed when the ROM sequencer is idle (case I) or 3 cycles into a read (case II,
//     ACT at the previous k = 2); never while a REF runs; REF waits for the bank;
//   - read:     ACT 0, READ 3, PRECHARGE 5; the byte is captured in `cap` at slot 7 (READ + 4,
//               as every read) and copied to ar_q at slot 8 (k = 3, two cycles before the next
//               clk_sys edge); a ROM read at slot 2 puts its READ at 4 (its word follows ours);
//   - write I:  ACT 0, WRITE 3, BST 4 (unless the ROM's READ is there: it ends the burst
//               too), PRECHARGE 5 (case I: the bus is free at 3, a ROM read at slot 2 returns
//               data from 7 on, after the write);
//   - write II: ACT 0, WRITE 8, BST 9 (unless the ROM's READ is there), PRECHARGE 10 (case II:
//               the ROM's last word is due at 4 and may stay on the bus until ~5 + 1 ns; its
//               next read (ACT 7) puts its READ at 9 and its data at 12);
//   - a ROM ACT is held off at A's command slots (it then counts as late; only reads that were
//     already late can land there). The next start is >= 10 cycles on (tRC, tRP of bank 3;
//     15 after a write II).
// Reading through `cap` would overwrite the ROM byte a covered read still uses, so the byte in
// cap is kept in cap_hold just before (slot 7) and rom_q takes it from there until the next
// ROM capture. Read latency: request seen at k = 2 of the cycle that set the address, start at
// the next k = 0 (or one later if blocked), byte in ar_q 13-18 clk after the address change;
// ar_q changes only at k = 3 (completions, and answers from the queue / writes to its address).
module sdram_rom8 #(
    parameter integer CAPTURE_HALF = 8,       // read capture point (8 = rise 4)
    parameter [11:0]  MRS_PINS     = 12'h037,
    parameter integer CL           = 3,
    // IS42S81600F-6 at 107.21 MHz (9.33 ns): tRCD/tRP 18 ns, tRAS 42 ns, tRC 60 ns (also REF to
    // the next command), tWR 2 clocks, tMRD 2 clocks
    parameter integer T_RCD        = 2,
    parameter integer T_RAS        = 5,
    parameter integer T_RP         = 2,
    parameter integer T_RC         = 7,
    parameter integer T_WR         = 2,
    parameter integer T_MRD        = 2,
    parameter integer INIT_CYCLES  = 21450,   // NOP time after power-up (200 us)
    parameter integer INIT_REFS    = 8,
    parameter integer RF_SOFT      = 800,     // refresh wanted after 7.5 us
    parameter integer RF_HARD      = 1500,    // ... in any slot after 14 us
    parameter integer RF_LIMIT     = 1650     // ... unconditionally after 15.4 us
) (
    input  wire        clk,
    input  wire        clk_sd,
    input  wire        clk_cap,
    input  wire        reset,
    output reg         ready = 1'b0,
    input  wire        sys_tog,         // toggles with every clk_sys edge

    // ROM read port (clk_sys registers / logic)
    input  wire        rom_en,
    input  wire [23:0] rom_addr,        // byte address (bit 23 ignored: 8 MB)
    input  wire        rom_word,
    output wire [15:0] rom_q,
    input  wire        rfsh_ok,

    // write port (clk domain, rom_en = 0 only): one byte
    input  wire        wr_req,
    input  wire [22:0] wr_addr,
    input  wire [7:0]  wr_data,
    output reg         wr_ack = 1'b0,

    // aux read port (clk domain, rom_en = 0 only): one byte
    input  wire        aux_req,
    input  wire [22:0] aux_addr,
    output reg         aux_ack = 1'b0,
    output reg         aux_valid = 1'b0,
    output wire [7:0]  aux_q,

    // SDRAM pins
    output wire        sd_clk,
    output wire        sd_cs_n,
    output wire        sd_ras_n,
    output wire        sd_cas_n,
    output wire        sd_we_n,
    output reg  [11:0] sd_a = 12'd0,
    output reg  [1:0]  sd_ba = 2'd0,
    input  wire [15:0] sd_dq_in,
    output reg  [15:0] sd_dq_out = 16'd0,
    output reg         sd_dq_oe = 1'b0,

    output reg  [15:0] n_rf_forced = 16'd0,
    output reg  [15:0] n_rf_stall = 16'd0,
    output reg  [15:0] n_late = 16'd0,
    output reg  [10:0] rf_max = 11'd0,
    output reg  [31:0] n_reads = 32'd0,     // ROM-port reads started

    // ARAM port (clk_sys signals, sampled at k = 4; see above)
    input  wire        ar_en,           // the port is live (the SNES runs; rom_en = 1)
    input  wire [15:0] ar_addr,
    input  wire        ar_rd,           // the core reads ar_addr this clk_sys cycle
    input  wire        ar_wr,           // the core writes ar_d to ar_addr at the next clk_sys edge
    input  wire [7:0]  ar_d,
    output reg  [7:0]  ar_q = 8'd0,
    output reg  [31:0] n_ar_rd = 32'd0,     // SDRAM reads
    output reg  [31:0] n_ar_wr = 32'd0,     // SDRAM writes
    output reg  [15:0] n_ar_fwd = 16'd0,    // reads answered from the write queue
    output reg  [15:0] n_ar_late = 16'd0,   // reads that may miss a 5-clk_sys deadline
    output reg  [15:0] n_ar_drop = 16'd0,   // writes lost to a full queue
    output reg  [15:0] n_clash = 16'd0      // (simulation check) two command sources at once
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

    localparam [3:0] C_NOP = 4'b0111, C_ACT = 4'b0011, C_RD = 4'b0101, C_WR = 4'b0100,
                     C_BST = 4'b0110, C_PRE = 4'b0010, C_REF = 4'b0001, C_MRS = 4'b0000;
    function integer imax(input integer x, input integer y);
        imax = x > y ? x : y;
    endfunction
    localparam integer RD2     = T_RCD + 2;                 // second READ (even start)
    localparam integer RD_PRE  = imax(T_RAS, RD2 + 1);      // PRECHARGE (both kinds of read)
    localparam integer RD_END  = imax(RD_PRE + T_RP, T_RC); // next ACT/REF allowed
    localparam integer WR_PRE  = imax(T_RAS, T_RCD + T_WR);
    localparam integer WR_END  = imax(WR_PRE + T_RP, T_RC);
    localparam integer CAP_N   = CAPTURE_HALF / 2;
    localparam integer CAP_F   = CAPTURE_HALF % 2;
    // cap holds byte A from the capture point after the first READ until the same point after the
    // second (two cycles later). It is copied to cap_lo, and lo_sel set, at the clk edge just
    // before the second capture (the capture clock is later than clk): the edge ending the cycle
    // in which rd2[CPY] is high. For the first read after a clk_sys edge that is the next clk_sys
    // edge (k = 10), where the core takes byte A: the low lane switches between two copies of A
    // right after that edge, so no consumer sees it change (snes_load.sdc).
    localparam integer CPY     = CAP_N - 1;

    // ------------------------------------------------------------------ clk_sys phase
    // tog_d is the only register that takes a clk_sys signal at the next clk edge (k = 1); the
    // phase k of each edge comes from registers only.
    reg       tog_d = 1'b0, tog_dd = 1'b0;
    reg [2:0] ph = 3'd0;                // k of the next edge
    wire      seen = tog_d ^ tog_dd;    // tog_d took a new value at the edge before: this is k = 2
    wire [2:0] k_now = seen ? 3'd2 : ph;
    wire      k_ok = k_now >= 3'd2;     // the core's address and rfsh_ok are settled
    always @(posedge clk) begin
        tog_d  <= sys_tog;
        tog_dd <= tog_d;
        ph     <= k_now == 3'd4 ? 3'd0 : k_now + 3'd1;
    end

    // ------------------------------------------------------------------ requests
    reg  [22:0] last_b = 23'd0;         // byte address of the last ROM read started
    reg         last_ok = 1'b0;
    reg         both = 1'b0;            // that read started at an even address (word complete)
    wire        covered = last_ok && rom_addr[22:1] == last_b[22:1] &&
                          (rom_addr[0] == last_b[0] || (rom_word && both));
    reg         rd_ok = 1'b0;           // registered: rom_en && ready (reads may start)
    wire        rd_req = rd_ok && k_ok && !covered;
    wire        quiet  = !rom_en || rfsh_ok;
    wire        slot   = k_ok && quiet;

    reg         rq_need = 1'b0;         // a read is wanted (latest k = 2 sample)
    reg  [10:0] rcnt = 11'd0;
    reg         rf_soft = 1'b0, rf_hard = 1'b0, rf_limit = 1'b0;   // rcnt >= RF_*, registered
    wire        rf_cond  = (rf_soft && slot) || (rf_hard && k_ok);
    // (v7) nor while an ARAM request waits for its start: a REF then held it off for T_RC, and
    // with a GSU cart's ROM traffic that made a few ARAM reads per minute miss the DSP's deadline
    wire        rf_now   = rf_limit || (!rd_req && !rq_need && rf_cond);

    // ------------------------------------------------------------------ sequencer
    localparam [2:0] S_POWER = 0, S_INIT = 1, S_IDLE = 2, S_READ = 3, S_WRITE = 4, S_WAIT = 5;
    reg  [2:0]  st = S_POWER;
    reg  [14:0] cnt = 15'd0;
    reg  [4:0]  istep = 5'd0;
    reg  [3:0]  iwait = 4'd0;
    reg  [1:0]  bank;
    reg  [8:0]  col;
    reg  [7:0]  wdat;
    reg  [22:0] a_q = 23'd0;            // the ROM address at the last idle cycle (k >= 2)
    reg  [6:0]  rdp = 7'd0;             // rdp[k]: a READ left the pins k cycles ago
    reg  [7:0]  rda = 8'd0;             // the same for aux reads
    reg  [7:0]  rd2 = 8'd0;             // the same for the second READ (byte A + 1)
    reg         aux_rd = 1'b0;
    reg         even_rd = 1'b0;         // the read in progress has a second READ
    reg  [3:0]  age = 4'd0, age_q = 4'd0;
    reg         rd_req_q = 1'b0, soft_q = 1'b0;
    reg         lo_sel = 1'b0;          // rom_q's low lane from cap_lo (word complete)
    reg  [7:0]  cap_lo = 8'd0;          // byte A of an even-start read, kept for the low lane
    reg  [7:0]  cap = 8'd0;             // the capture register (I/O-cell input register)

    // ------------------------------------------------------------------ ARAM port state
    localparam [1:0] A_RD = 2'd0, A_WI = 2'd1, A_WII = 2'd2;
    reg         a_on = 1'b0;            // a bank-3 operation is running (slots 1-9)
    reg  [3:0]  a_slot = 4'd0;          // slot of the current edge while a_on
    reg  [1:0]  a_op = A_RD;
    reg  [15:0] a_addr = 16'd0;
    reg  [7:0]  a_data = 8'd0;
    reg         a_stale = 1'b0;         // a write to a_addr was posted during this read
    reg  [15:0] wq_a [0:3];             // write queue, head = 0
    reg  [7:0]  wq_d [0:3];
    reg  [2:0]  wq_n = 3'd0;
    reg  [15:0] rq_addr = 16'd0;
    reg  [2:0]  rq_age = 3'd0;          // k = 0 edges the request has waited
    reg  [15:0] tag = 16'd0;            // ar_q holds the byte at tag
    reg         tag_ok = 1'b0;
    reg  [15:0] cur_rd = 16'd0;         // the address the core reads now (latest sample)
    reg         upd = 1'b0;             // ar_q <= upd_d (tag <= upd_tag) at the next k = 3
    reg  [7:0]  upd_d = 8'd0;
    reg  [15:0] upd_tag = 16'd0;
    reg         fwd_evt = 1'b0;
    reg         last_wv = 1'b0;         // the newest write taken (to drop repeats)
    reg  [15:0] last_wa = 16'd0;
    reg  [7:0]  last_wd = 8'd0;
    reg         hold_sel = 1'b0;        // rom_q's high lane from cap_hold (cap has an ARAM byte)
    reg  [7:0]  cap_hold = 8'd0;
    reg  [7:0]  rdar = 8'd0;            // rdar[k]: an ARAM READ left the pins k cycles ago
    reg  [7:0]  rdrom = 8'd0;           // the same for ROM-port READs
    integer     qi;
    initial for (qi = 0; qi < 4; qi = qi + 1) begin wq_a[qi] = 16'd0; wq_d[qi] = 8'd0; end

    wire        case1 = st == S_IDLE && !rf_limit;
    wire        case2 = st == S_READ && cnt == 15'd3;
    wire        a_start = ar_en && ready && k_now == 3'd0 && !a_on && (case1 || case2) &&
                          (rq_need || wq_n != 3'd0);
    wire        a_rdop = rq_need;                   // the operation a_start begins
    wire [15:0] a_saddr = rq_need ? rq_addr : wq_a[0];
    wire        rom_rd_now = st == S_READ && (cnt == T_RCD[14:0] || (even_rd && cnt == RD2[14:0]));
    // A's commands at this edge (hard: nothing else may use the edge) and in the next ones
    reg  [3:0]  a_cmd;
    reg         a_hard;
    reg  [11:0] a_pa;
    reg  [15:0] a_res;                  // a_res[i]: A has a hard command at edge now + i
    integer     ri;
    always @(*) begin
        a_cmd = C_NOP; a_hard = 1'b0; a_pa = 12'd0; a_res = 16'd0;
        if (a_start) begin
            a_cmd = C_ACT; a_hard = 1'b1; a_pa = {5'd0, a_saddr[15:9]};
            if (a_rdop || case1) begin a_res[3] = 1'b1; a_res[5] = 1'b1; end
            else begin a_res[8] = 1'b1; a_res[10] = 1'b1; end
        end else if (a_on) begin
            case (a_op)
                A_RD: begin
                    if (a_slot == 4'd3) begin a_cmd = C_RD; a_hard = 1'b1; a_pa = {3'd0, a_addr[8:0]}; end
                    if (a_slot == 4'd5) begin a_cmd = C_PRE; a_hard = 1'b1; end
                end
                A_WI: begin
                    if (a_slot == 4'd3) begin a_cmd = C_WR; a_hard = 1'b1; a_pa = {3'd0, a_addr[8:0]}; end
                    if (a_slot == 4'd4 && !rom_rd_now) begin a_cmd = C_BST; a_hard = 1'b1; end
                    if (a_slot == 4'd5) begin a_cmd = C_PRE; a_hard = 1'b1; end
                end
                default: begin
                    if (a_slot == 4'd8) begin a_cmd = C_WR; a_hard = 1'b1; a_pa = {3'd0, a_addr[8:0]}; end
                    if (a_slot == 4'd9 && !rom_rd_now) begin a_cmd = C_BST; a_hard = 1'b1; end
                    if (a_slot == 4'd10) begin a_cmd = C_PRE; a_hard = 1'b1; end
                end
            endcase
            for (ri = 0; ri < 16; ri = ri + 1) begin
                if (a_op == A_RD && (a_slot + ri == 3 || a_slot + ri == 5)) a_res[ri] = 1'b1;
                // (write I's BST at 4 gives way to a ROM READ there; a ROM ACT there is held off)
                if (a_op == A_WI && (a_slot + ri == 3 || a_slot + ri == 5 || (ri == 0 && a_slot == 4'd4)))
                    a_res[ri] = 1'b1;
                if (a_op == A_WII && (a_slot + ri == 8 || a_slot + ri == 10 || (ri == 0 && a_slot == 4'd9)))
                    a_res[ri] = 1'b1;
            end
        end
    end
    // a ROM ACT now needs this edge and its READ/second READ/PRECHARGE edges (+2, +4, +5) free
    wire        a_block = a_res[0] || a_res[2] || a_res[4] || a_res[5];
    // synthesis translate_off
    wire        rom_cmd_now = (st == S_READ && (cnt == T_RCD[14:0] || (even_rd && cnt == RD2[14:0]) ||
                                                cnt == RD_PRE[14:0])) ||
                              (st == S_IDLE && ((rf_now && !a_on && !a_start) || (rom_en && rd_req && !a_block)));
    // synthesis translate_on

    reg [3:0] sd_cmd = 4'b1111;         // internal: must power up deselected (notes/quartus.md)
    assign {sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n} = sd_cmd;
    task cmd(input [3:0] c);
        sd_cmd <= c;
    endtask

    always @(posedge clk) begin
        cmd(C_NOP);
        sd_a     <= 12'd0;
        sd_dq_oe <= 1'b0;
        wr_ack   <= 1'b0;
        aux_ack  <= 1'b0;
        rdp      <= {rdp[5:0], 1'b0};
        rda      <= {rda[6:0], 1'b0};
        rd2      <= {rd2[6:0], 1'b0};
        rdar     <= {rdar[6:0], 1'b0};
        rdrom    <= {rdrom[6:0], 1'b0};
        cnt      <= cnt + 15'd1;
        if (rcnt != 11'h7ff) rcnt <= rcnt + 11'd1;
        rf_soft  <= rcnt >= RF_SOFT - 1;        // (true in the cycle rcnt reaches RF_SOFT)
        rf_hard  <= rcnt >= RF_HARD - 1;
        rf_limit <= rcnt >= RF_LIMIT - 1;
        rd_ok    <= rom_en && ready;
        rd_req_q <= rd_req;
        soft_q   <= rf_soft && slot;
        age      <= rd_req_q ? (age == 4'hf ? age : age + 4'd1) : 4'd0;
        age_q    <= age;

        case (st)
            S_POWER: begin
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
                cnt <= 15'd1;
                // Row, bank and column follow the active port with every idle cycle (NOP and REF
                // ignore the address pins), so an ACT finds them set; from the ROM port only at
                // k >= 2 (the SDC relaxes the hold check of these registers accordingly).
                if (rom_en) begin
                    if (k_ok) begin
                        sd_ba <= rom_addr[22:21]; sd_a <= rom_addr[20:9];
                        bank <= rom_addr[22:21]; col <= rom_addr[8:0];
                        a_q <= rom_addr[22:0];
                    end else begin
                        sd_ba <= sd_ba; sd_a <= sd_a;
                    end
                end else if (aux_req) begin
                    sd_ba <= aux_addr[22:21]; sd_a <= aux_addr[20:9];
                    bank <= aux_addr[22:21]; col <= aux_addr[8:0];
                end else begin
                    sd_ba <= wr_addr[22:21]; sd_a <= wr_addr[20:9];
                    bank <= wr_addr[22:21]; col <= wr_addr[8:0];
                end
                wdat   <= wr_data;
                aux_rd <= !rom_en;
                if (rf_now && !a_on && !a_start) begin
                    cmd(C_REF);
                    st <= S_WAIT;
                end else if (rom_en) begin
                    if (rd_req && !a_block) begin
                        cmd(C_ACT);
                        st <= S_READ;
                    end
                end else if (aux_req) begin
                    cmd(C_ACT);
                    aux_ack <= 1'b1;
                    last_ok <= 1'b0;            // cap no longer holds the ROM port's byte
                    st <= S_READ;
                end else if (wr_req) begin
                    cmd(C_ACT);
                    wr_ack  <= 1'b1;
                    last_ok <= 1'b0;
                    st <= S_WRITE;
                end
            end
            S_READ: begin
                if (cnt == 15'd1) begin
                    // what the read records, from the registered copies of the ACT cycle
                    even_rd <= !aux_rd && !a_q[0];
                    if (!aux_rd) begin
                        last_b  <= a_q;
                        last_ok <= 1'b1;
                        both    <= !a_q[0];
                        lo_sel  <= 1'b0;
                        n_reads <= n_reads + 32'd1;
                        // late: the request waited (data after the core's deadline)
                        if (last_ok && age_q != 4'd0 && n_late != 16'hffff) n_late <= n_late + 16'd1;
                        // synthesis translate_off
                        if (last_ok && age_q != 4'd0) $display("sdram_rom8: late read %h (waited %0d cycles) at %0t", a_q, age_q, $time);
                        // synthesis translate_on
                    end
                end
                if (cnt == T_RCD[14:0]) begin
                    cmd(C_RD); sd_ba <= bank; sd_a <= {3'b000, col};
                    rdp[0] <= 1'b1;
                    rda[0] <= aux_rd;
                    rdrom[0] <= !aux_rd;
                end
                if (even_rd && cnt == RD2[14:0]) begin
                    cmd(C_RD); sd_ba <= bank; sd_a <= {3'b000, col | 9'd1};
                    rdp[0] <= 1'b1;
                    rd2[0] <= 1'b1;
                    rdrom[0] <= 1'b1;
                end
                if (cnt == RD_PRE[14:0]) begin cmd(C_PRE); sd_ba <= bank; end
                if (cnt == RD_END[14:0] - 15'd1) st <= S_IDLE;
            end
            S_WRITE: begin
                if (cnt == T_RCD[14:0]) begin
                    cmd(C_WR); sd_ba <= bank; sd_a <= {3'b000, col};
                    sd_dq_out <= {wdat, wdat};
                    sd_dq_oe  <= 1'b1;
                end
                if (cnt == T_RCD[14:0] + 15'd1) begin cmd(C_BST); sd_ba <= bank; end
                if (cnt == WR_PRE[14:0]) begin cmd(C_PRE); sd_ba <= bank; end
                if (cnt == WR_END[14:0] - 15'd1) st <= S_IDLE;
            end
            S_WAIT: begin                       // after REF
                if (cnt == 15'd1) begin
                    // bookkeeping of the REF issued in the cycle before (registered copies)
                    if (rcnt > rf_max) rf_max <= rcnt;
                    rcnt <= 11'd1;
                    if (rd_req_q) begin
                        if (n_rf_stall != 16'hffff) n_rf_stall <= n_rf_stall + 16'd1;
                    end else if (!soft_q) begin
                        if (n_rf_forced != 16'hffff) n_rf_forced <= n_rf_forced + 16'd1;
                    end
                end
                if (cnt == T_RC[14:0] - 15'd1) st <= S_IDLE;
            end
            default: st <= S_POWER;
        endcase
        if (rd2[CPY]) begin
            cap_lo <= cap;
            lo_sel <= 1'b1;
        end

        // ---------------------------------------------------------- ARAM port
        // requests: sampled at k = 2 (the core's signals settled, as the ROM address); ar_q
        // changes only at k = 3, so what the core derives from it has until the next k = 2
        if (k_now == 3'd2 && ar_en) begin : sample
            reg        hit;
            reg [7:0]  hd;
            reg [2:0]  n;
            hit = 1'b0; hd = 8'd0;
            if (a_on && a_op != A_RD && a_addr == ar_addr) begin hit = 1'b1; hd = a_data; end
            for (qi = 0; qi < 4; qi = qi + 1)
                if (qi < wq_n && wq_a[qi] == ar_addr) begin hit = 1'b1; hd = wq_d[qi]; end
            if (ar_rd) cur_rd <= ar_addr;
            if (ar_rd) begin
                if (hit) begin
                    upd <= 1'b1; upd_d <= hd; upd_tag <= ar_addr;
                    rq_need <= 1'b0;
                    fwd_evt <= !(tag_ok && tag == ar_addr);     // (counted next cycle)
                end else if ((tag_ok && tag == ar_addr) ||
                             (a_on && a_op == A_RD && a_addr == ar_addr && !a_stale))
                    rq_need <= 1'b0;
                else begin
                    if (!rq_need || rq_addr != ar_addr) rq_age <= 3'd0;
                    rq_need <= 1'b1;
                    rq_addr <= ar_addr;
                end
            end else
                rq_need <= 1'b0;
            if (ar_wr && !(last_wv && last_wa == ar_addr && last_wd == ar_d)) begin
                last_wv <= 1'b1; last_wa <= ar_addr; last_wd <= ar_d;
                if (tag_ok && tag == ar_addr) begin
                    upd <= 1'b1; upd_d <= ar_d; upd_tag <= ar_addr;
                end
                if (a_on && a_op == A_RD && a_addr == ar_addr) a_stale <= 1'b1;
                // queue: coalesce with the newest entry of the same address, else append
                n = wq_n;
                if (n != 3'd0 && wq_a[n - 3'd1] == ar_addr) wq_d[n - 3'd1] <= ar_d;
                else if (n != 3'd4) begin
                    wq_a[n[1:0]] <= ar_addr; wq_d[n[1:0]] <= ar_d; wq_n <= n + 3'd1;
                end else if (n_ar_drop != 16'hffff) n_ar_drop <= n_ar_drop + 16'd1;
            end
        end
        if (rdar[CAP_N] && a_op == A_RD) begin   // slot 8: the ARAM byte is in cap
            if (!a_stale && cur_rd == a_addr) begin
                ar_q <= cap; tag <= a_addr; tag_ok <= 1'b1;
            end
        end
        if (fwd_evt) begin
            fwd_evt <= 1'b0;
            if (n_ar_fwd != 16'hffff) n_ar_fwd <= n_ar_fwd + 16'd1;
        end
        if (k_now == 3'd3 && upd) begin           // (after a read completion at the same edge)
            upd <= 1'b0;
            ar_q <= upd_d; tag <= upd_tag; tag_ok <= 1'b1;
        end
        if (k_now == 3'd0 && rq_need && rq_age != 3'd7) rq_age <= rq_age + 3'd1;
        // synthesis translate_off
        if (k_now == 3'd0 && rq_need && rq_age >= 3'd2 && !a_start)
            $display("sdram_rom8: ARAM read %h waiting (age %0d): st %0d cnt %0d a_on %0d a_op %0d a_slot %0d rf_limit %0d wq_n %0d at %0t",
                     rq_addr, rq_age, st, cnt, a_on, a_op, a_slot, rf_limit, wq_n, $time);
        // synthesis translate_on
        // operations
        if (a_start) begin
            a_on <= 1'b1;
            a_slot <= 4'd1;
            a_stale <= 1'b0;
            if (a_rdop) begin
                a_op <= A_RD; a_addr <= rq_addr;
                rq_need <= 1'b0;
                n_ar_rd <= n_ar_rd + 32'd1;
                // late: the byte lands after E + 23 (start after the third k = 0 since the
                // address change at E), too late for a DSP CE edge 5 clk_sys after E
                if (rq_age > 3'd2 && n_ar_late != 16'hffff) n_ar_late <= n_ar_late + 16'd1;
            end else begin
                a_op <= case1 ? A_WI : A_WII; a_addr <= wq_a[0]; a_data <= wq_d[0];
                for (qi = 0; qi < 3; qi = qi + 1) begin
                    wq_a[qi] <= wq_a[qi + 1]; wq_d[qi] <= wq_d[qi + 1];
                end
                wq_n <= wq_n - 3'd1;
                n_ar_wr <= n_ar_wr + 32'd1;
                // (a write sampled at this same edge can't be: samples are at k = 4)
            end
        end else if (a_on) begin
            a_slot <= a_slot + 4'd1;
            if (a_slot == (a_op == A_WII ? 4'd10 : 4'd9)) a_on <= 1'b0;
        end
        if (a_hard) begin
            // synthesis translate_off
            if (rom_cmd_now) begin
                $display("sdram_rom8: command clash at %0t (A slot %0d op %0d)", $time, a_slot, a_op);
                n_clash <= n_clash + 16'd1;
            end
            // synthesis translate_on
            cmd(a_cmd); sd_ba <= 2'd3; sd_a <= a_pa;
            if (a_on && a_cmd == C_RD) begin rdp[0] <= 1'b1; rdar[0] <= 1'b1; end
            if (a_on && a_cmd == C_WR) begin sd_dq_out <= {a_data, a_data}; sd_dq_oe <= 1'b1; end
        end
        // the byte in cap goes to cap_hold just before an ARAM byte replaces it, and rom_q takes
        // it from there until the next ROM-port capture
        if (rdar[CAP_N - 1]) begin
            if (!hold_sel) cap_hold <= cap;
            hold_sel <= 1'b1;
        end
        if (rdrom[CAP_N - 1]) hold_sel <= 1'b0;
        if (!ar_en && !a_on) begin
            tag_ok <= 1'b0; rq_need <= 1'b0; wq_n <= 3'd0; last_wv <= 1'b0; upd <= 1'b0;
        end
        if (reset) begin
            st    <= S_POWER;
            cnt   <= 15'd0;
            ready <= 1'b0;
        end
    end

    // ------------------------------------------------------------------ read capture
    // rdp[k] is high during the clk cycle that starts k cycles after a READ edge R.
    generate
        if (CAP_F == 0) begin : g_rise
            // clk_cap's rising edges come a little after clk's, so the enable is taken over on
            // clk_cap's falling edge in between (half a cycle each way) instead of straight from
            // rdp, which changes just before the capture edge
            reg en_c = 1'b0;
            always @(negedge clk_cap) en_c <= rdp[CAP_N - 1];
            always @(posedge clk_cap) if (en_c) cap <= sd_dq_in[15:8];
            always @(posedge clk) aux_valid <= rda[CAP_N - 1];
        end else begin : g_fall
            always @(negedge clk_cap) if (rdp[CAP_N]) cap <= sd_dq_in[15:8];
            always @(posedge clk) aux_valid <= rda[CAP_N];
        end
    endgenerate
    wire [7:0] cap_r = hold_sel ? cap_hold : cap;
    assign rom_q = {cap_r, lo_sel ? cap_lo : cap_r};
    assign aux_q = cap;
endmodule
