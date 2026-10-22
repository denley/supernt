// SPDX-License-Identifier: GPL-3.0-or-later
// Super Nt top level: SNES + SA-1 core that loads its ROM from the SD card through the SPC
// player (notes/snes-load.md). The console loads this as SYSTEM/CORES/spc.cor; Tools -> "Play
// SPC Files" starts it and the PIC32 runs the player's file browser on it:
//   - link_ui.sv answers the PIC (status 02, pad registers, 0x2008 = 01) and keeps the
//     browser's screen (0x1018_0000), which the overlay draws until a game runs;
//   - picking a file made by tools/rom2spc.py (a silent .spc with the ROM appended) makes the
//     PIC send the whole file to link address 0xFF00 + offset; rom_loader.sv stores the ROM in
//     SDRAM chip B (sdram_rom8.sv, 8-bit), detects the mapper from the header, reads the ROM
//     back and checks its CRC-32 against the file's info block, shows the result for 4 s on the
//     diagnostics page and then releases the SNES (reset, ROM reads on);
//   - the SNES core (quartus/snes_sdram/snes_sdram_core.sv: srg320's MiSTer core with SA-1 and
//     the Lo/HiROM mapper; SA1.vhd with sa1_vbp.patch) reads the ROM through the 8-bit
//     controller at 5 x clk_sys; video/audio as quartus/snes.
// Controller port 1 is polled by pad_poll.sv only; the SNES gets the bits through a virtual 4021
// (as MiSTer's ioport.sv), the PIC through 0x2000/0x2001, each only while its view is shown:
//   before a game: file browser (PIC gets the pad);  while a game runs: the game (SNES gets it);
//   hold L+R+SELECT 0.5 s: diagnostics page on/off;  L+R+START: browser on/off (to pick another
//   file: a new transfer stops the game and loads it);  L+R+A: boot after a failed verify.
// The diagnostics page is shown by itself from the first file byte until the game starts.
//
// Pins: board clock W16; HDMI transmitter video/audio and controller port 1 as quartus/snes;
// the PIC32 link as quartus/hwtest; SDRAM command/address/DQ/clock as quartus/hwtest with AB10
// (chip B's DQM, notes/sdram.md) driven low as spc.cor does. The DQM candidates / open-drain
// group and every other pin are left unused (weak pull-up inputs, as v1-v6 showed harmless).
module top #(
    // SDRAM read-capture point and PLL phases (sdram_cfg.tcl via sdram_params.tcl)
    parameter CAPTURE_HALF = 8,
    parameter MEM_PHASE  = "0 ps",
    parameter SD_PHASE   = "9160 ps",
    parameter CAP_PHASE  = "666 ps",
    parameter CH_ORDER   = 0,       // colour pins as confirmed (quartus/snes)
    parameter SYNC_ORDER = 3,       // {VS, DE, HS} on P16/M16/M18, confirmed
    parameter OUT_W      = 768,
    parameter LOCK       = 1,
    parameter [15:0] RESET_CYCLES = 16'hffff, // core reset after the load (clk_sys cycles, ~3 ms)
    parameter AUD_FRAMING = 0,      // I2S, confirmed
    parameter BSRAM_AW   = 13,      // BW-RAM / SRAM in block RAM: 8 KB
    parameter TMPL_HEX   = "../../build/snes_load/diag.hex",
    parameter FONT_HEX   = "../../build/hwtest/font.hex",
    // simulation shortcuts (the real values are the defaults)
    parameter integer PAD_START_US = 200000,
    parameter integer DONE_MS = 250,
    parameter integer SHOW_MS = 4000,
    parameter integer COMBO_MS = 500,
    parameter integer INIT_CYCLES = 21450
) (
    input  wire       clk,      // W16, 74.25 MHz
    output wire       pclk,     // M22
    output wire       s0, s1, s2,
    output reg  [7:0] ch1, ch2, ch3,
    output wire       aud_mclk, aud_bclk, aud_lrclk, aud_sdata,
    // controller port 1
    output wire       pad_p14,
    output wire       pad_j13,
    output wire       pad_k16,
    input  wire       pad_t12,
    // PIC32 link
    input  wire [2:0] link_a,   // AB20 AA20 AA19
    input  wire       link_nrd, // U21
    input  wire       link_nwr, // U22
    inout  wire [7:0] link_d,   // AB21 AB22 AA22 Y21 Y22 W21 W22 V21 (bit 7..0)
    // SDRAM (x8 pair; only chip B answers)
    output wire        sd_clk,
    output wire        sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n,
    output wire [11:0] sd_a,
    output wire [1:0]  sd_ba,
    inout  wire [15:0] sd_dq,
    output wire        sd_dqm_b  // AB10: chip B's DQM, low
);
    // ================================================================ clocks
    wire clk_vid = clk;
    wire clk_sys, clk_mem, clk_sd, clk_cap, pll_locked;
    snes_load_pll #(.MEM_PHASE(MEM_PHASE), .SD_PHASE(SD_PHASE), .CAP_PHASE(CAP_PHASE)) pll (
        .refclk(clk), .rst(1'b0), .outclk_0(clk_sys), .outclk_1(clk_mem), .outclk_2(clk_sd),
        .outclk_3(clk_cap), .locked(pll_locked));
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg [1:0] lock_mem = 2'b00;
    always @(posedge clk_mem) lock_mem <= {lock_mem[0], pll_locked};
    wire mem_reset = ~lock_mem[1];

    // ================================================================ controller port 1
    wire [31:0] pad_raw, pad_polls;
    wire        pad_std, pad_clk;
    pad_poll #(.START_US(PAD_START_US)) padp (
        .clk(clk_vid), .p14(pad_p14), .j13k16(pad_clk), .t12(pad_t12), .raw(pad_raw),
        .is_std(pad_std), .polls(pad_polls));
    assign pad_j13 = pad_clk;
    assign pad_k16 = pad_clk;
    wire [11:0] btn = pad_std ? pad_raw[11:0] : 12'd0;

    // ================================================================ PIC32 link
    wire [7:0]  link_dout;
    wire        link_oe /* verilator public_flat_rd */;
    assign link_d = link_oe ? link_dout : 8'hzz;
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg [12:0] pad_m1 = 13'd0, pad_m2 = 13'd0;      // {pad_std, buttons} on clk_mem
    reg        pic_pad_v = 1'b1;                     // clk_vid: PIC gets the pad
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg [1:0]  pic_pad_m = 2'b00;
    always @(posedge clk_mem) begin
        pad_m1 <= {pad_std, pad_raw[11:0]};
        pad_m2 <= pad_m1;
        pic_pad_m <= {pic_pad_m[0], pic_pad_v};
    end
    wire        f_go;
    wire [31:0] f_addr;
    wire [7:0]  f_data;
    wire [10:0] scr_addr;
    wire [15:0] scr_q;
    wire [3:0]  log_idx;
    wire [103:0] log_q;
    wire [31:0] ms /* verilator public_flat_rd */, n_stat /* verilator public_flat_rd */;
    wire [31:0] n_ui /* verilator public_flat_rd */, n_padrd /* verilator public_flat_rd */;
    wire [31:0] n_wr, n_scr, last_ui_ms, link_addr, n_log /* verilator public_flat_rd */;
    link_ui #(.CLK_KHZ(107210)) lnk (
        .clk(clk_mem), .a(link_a), .n_rd(link_nrd), .n_wr(link_nwr), .d_in(link_d),
        .d_out(link_dout), .d_oe(link_oe),
        .pad(pad_m2[11:0]), .pad_std(pad_m2[12]), .pad_en(pic_pad_m[1]),
        .f_go(f_go), .f_addr(f_addr), .f_data(f_data),
        .clk_vid(clk_vid), .scr_addr(scr_addr), .scr_q(scr_q),
        .log_idx(log_idx), .log_q(log_q), .n_log(n_log),
        .ms(ms), .n_stat(n_stat), .n_ui(n_ui), .n_padrd(n_padrd), .n_data(n_wr), .n_scr(n_scr),
        .last_ui_ms(last_ui_ms), .addr(link_addr));

    // ================================================================ SDRAM
    wire [23:0] rom_addr;
    wire        rom_word, rom_oe_n, sysclkf_ce, sysclkr_ce;
    wire [15:0] rom_q;
    wire        sd_ready /* verilator public_flat_rd */, wr_ack, aux_ack, aux_valid;
    wire        wr_req, aux_req;
    wire [22:0] wr_addr, aux_addr;
    wire [7:0]  wr_data, aux_q;
    wire [15:0] sd_dq_out;
    wire        sd_dq_oe;
    wire [15:0] sd_forced /* verilator public_flat_rd */, sd_stall /* verilator public_flat_rd */;
    wire [15:0] sd_late /* verilator public_flat_rd */;
    wire [10:0] sd_rfmax /* verilator public_flat_rd */;
    wire [31:0] sd_reads /* verilator public_flat_rd */;
    wire        rom_en, ld_sa1;
    reg         sys_tog = 1'b0;
    always @(posedge clk_sys) sys_tog <= ~sys_tog;
    assign sd_dq = sd_dq_oe ? sd_dq_out : 16'hzzzz;
    assign sd_dqm_b = 1'b0;
    // Refresh slots (sdram_rom8.sv: no critical read can start at the next clk_sys edge): SA-1
    // carts as quartus/snes_sdram (the SA-1's address changes after a CLK_CE = ROM_OE_N cycle, the
    // SNES CPU's window ends with SYSCLKF_CE); the Lo/HiROM mapper (DSP_LHRomMap.vhd) registers
    // the ROM address on SYSCLKR_CE only, and its CPU takes the data >= 3 clk_sys later.
    wire rfsh_ok = ld_sa1 ? (~rom_oe_n & ~sysclkf_ce) : ~sysclkr_ce;
    sdram_rom8 #(.CAPTURE_HALF(CAPTURE_HALF), .INIT_CYCLES(INIT_CYCLES)) sdram (
        .clk(clk_mem), .clk_sd(clk_sd), .clk_cap(clk_cap), .reset(mem_reset), .ready(sd_ready),
        .sys_tog(sys_tog),
        .rom_en(rom_en), .rom_addr(rom_addr), .rom_word(rom_word), .rom_q(rom_q),
        .rfsh_ok(rfsh_ok),
        .wr_req(wr_req), .wr_addr(wr_addr), .wr_data(wr_data), .wr_ack(wr_ack),
        .aux_req(aux_req), .aux_addr(aux_addr), .aux_ack(aux_ack), .aux_valid(aux_valid),
        .aux_q(aux_q),
        .sd_clk(sd_clk), .sd_cs_n(sd_cs_n), .sd_ras_n(sd_ras_n), .sd_cas_n(sd_cas_n),
        .sd_we_n(sd_we_n), .sd_a(sd_a), .sd_ba(sd_ba), .sd_dq_in(sd_dq), .sd_dq_out(sd_dq_out),
        .sd_dq_oe(sd_dq_oe),
        .n_rf_forced(sd_forced), .n_rf_stall(sd_stall), .n_late(sd_late), .rf_max(sd_rfmax),
        .n_reads(sd_reads));

    // ================================================================ loader
    wire [2:0]  ld_state /* verilator public_flat_rd */;
    wire [7:0]  rom_type /* verilator public_flat_rd */;
    wire [23:0] rom_mask /* verilator public_flat_rd */, ram_mask /* verilator public_flat_rd */;
    wire [6:0]  txt_addr;
    wire [7:0]  txt_q;
    wire [31:0] n_file /* verilator public_flat_rd */, file_end, crc_file /* verilator public_flat_rd */;
    wire [31:0] rom_size /* verilator public_flat_rd */, crc_rom /* verilator public_flat_rd */;
    wire [31:0] crc_sd /* verilator public_flat_rd */, n_order /* verilator public_flat_rd */;
    wire [31:0] n_drop /* verilator public_flat_rd */, n_big, n_ign /* verilator public_flat_rd */;
    wire [31:0] t_start /* verilator public_flat_rd */, t_end /* verilator public_flat_rd */;
    wire [31:0] t_boot /* verilator public_flat_rd */, info_size, info_crc /* verilator public_flat_rd */;
    wire [31:0] hdr_w0 /* verilator public_flat_rd */, hdr_w1;
    wire [7:0]  n_loads, info_type;
    wire        info_ok /* verilator public_flat_rd */, ld_unsup, ok_info /* verilator public_flat_rd */;
    wire        ok_fly /* verilator public_flat_rd */;
    wire [1:0]  ld_kind /* verilator public_flat_rd */;
    wire [11:0] scores /* verilator public_flat_rd */;
    wire [15:0] hdr_compl;
    reg         force_v = 1'b0;                      // clk_vid: L+R+A held
    reg         accept_v = 1'b0;                     // clk_vid: the file browser is shown
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg [1:0]   force_m = 2'b00, accept_m = 2'b00;
    always @(posedge clk_mem) begin
        force_m <= {force_m[0], force_v};
        accept_m <= {accept_m[0], accept_v};
    end
    rom_loader #(.CLK_KHZ(107210), .DONE_MS(DONE_MS), .SHOW_MS(SHOW_MS)) ld (
        .clk(clk_mem), .ms(ms), .f_go(f_go), .f_addr(f_addr), .f_data(f_data),
        .force_boot(force_m[1]), .accept(accept_m[1]),
        .sd_ready(sd_ready), .wr_req(wr_req), .wr_addr(wr_addr), .wr_data(wr_data),
        .wr_ack(wr_ack), .aux_req(aux_req), .aux_addr(aux_addr), .aux_ack(aux_ack),
        .aux_valid(aux_valid), .aux_q(aux_q),
        .rom_en(rom_en), .rom_type(rom_type), .rom_mask(rom_mask), .ram_mask(ram_mask),
        .clk_vid(clk_vid), .txt_addr(txt_addr), .txt_q(txt_q),
        .state(ld_state), .n_file(n_file), .file_end(file_end), .crc_file(crc_file),
        .rom_size(rom_size), .crc_rom(crc_rom), .crc_sd(crc_sd), .n_order(n_order),
        .n_drop(n_drop), .n_big(n_big), .n_ign(n_ign), .t_start(t_start), .t_end(t_end), .t_boot(t_boot),
        .n_loads(n_loads), .info_ok(info_ok), .info_size(info_size), .info_crc(info_crc),
        .info_type(info_type), .kind(ld_kind), .sa1(ld_sa1), .chip_unsup(ld_unsup),
        .scores(scores), .hdr_w0(hdr_w0), .hdr_w1(hdr_w1), .hdr_compl(hdr_compl),
        .ok_info(ok_info), .ok_fly(ok_fly));

    // ================================================================ SNES
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg [1:0]  run_sync = 2'b00;
    reg [15:0] rst_cnt = 16'd0;
    reg        core_reset /* verilator public_flat_rd */ = 1'b1;
    always @(posedge clk_sys) begin
        run_sync <= {run_sync[0], rom_en};
        if (!run_sync[1]) begin
            rst_cnt    <= 16'd0;
            core_reset <= 1'b1;
        end else if (rst_cnt != RESET_CYCLES)
            rst_cnt <= rst_cnt + 16'd1;
        else
            core_reset <= 1'b0;
    end
    wire [7:0]  r, g, b;
    wire        dotclk, hde, vde, high_res, v224;
    wire [15:0] audio_l /* verilator public_flat_rd */, audio_r;
    wire        joy_strb, joy_clk, joy_d0;
    snes_sdram_core #(.BSRAM_AW(BSRAM_AW)) snes (
        .clk_sys(clk_sys), .reset(core_reset), .rom_type(rom_type), .rom_mask(rom_mask),
        .ram_mask(ram_mask),
        .rom_addr(rom_addr), .rom_word(rom_word), .rom_q(rom_q), .rom_oe_n(rom_oe_n),
        .sysclkf_ce(sysclkf_ce), .sysclkr_ce(sysclkr_ce),
        .r(r), .g(g), .b(b), .dotclk(dotclk), .hde(hde), .vde(vde), .high_res(high_res),
        .v224(v224), .audio_l(audio_l), .audio_r(audio_r),
        .joy_strb(joy_strb), .joy_clk(joy_clk), .joy1_d0(joy_d0));

    // virtual controller (MiSTer ioport.sv): {B Y SELECT START UP DOWN LEFT RIGHT A X L R 0000},
    // latched on the strobe, shifted at the start of each clock pulse, 0 on the line = pressed
    reg        snes_pad_v = 1'b0;                    // clk_vid: the SNES gets the pad
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg [11:0] pad_s1 = 12'd0, pad_s2 = 12'd0;
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg [1:0]  pad_en_s = 2'b00;
    reg [15:0] joy_lat = 16'hffff;
    reg        joy_clk_d = 1'b0;
    wire [11:0] pb = pad_en_s[1] ? pad_s2 : 12'd0;
    always @(posedge clk_sys) begin
        pad_s1 <= btn;
        pad_s2 <= pad_s1;
        pad_en_s <= {pad_en_s[0], snes_pad_v};
        joy_clk_d <= joy_clk;
        if (joy_strb)
            joy_lat <= ~{pb[0], pb[1], pb[2], pb[3], pb[4], pb[5], pb[6], pb[7], pb[8], pb[9],
                         pb[10], pb[11], 4'b0000};
        else if (!joy_clk_d && joy_clk)
            joy_lat <= {joy_lat[14:0], 1'b0};
    end
    assign joy_d0 = joy_lat[15];

    // SNES frames (for the diagnostics page)
    reg [31:0] snes_frames = 32'd0;
    reg        vde_d = 1'b0;
    always @(posedge clk_sys) begin
        vde_d <= vde;
        if (vde && !vde_d) snes_frames <= snes_frames + 32'd1;
    end

    // ================================================================ views (clk_vid)
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg [2:0] st_v1 = 3'd0, st_v2 = 3'd0;
    reg [2:0] st_v = 3'd0, st_prev = 3'd0;
    always @(posedge clk_vid) begin
        st_v1 <= ld_state;
        st_v2 <= st_v1;
        if (st_v2 == st_v1) st_v <= st_v2;          // a stable value (multi-bit crossing)
    end
    localparam [2:0] S_IDLE = 0, S_LOAD = 1, S_PARSE = 2, S_VERIFY = 3, S_SHOW = 4, S_RUN = 5,
                     S_FAIL = 6, S_NOTROM = 7;
    // combinations held for COMBO_MS (ms ticks at 74.25 MHz)
    reg [16:0] mdiv = 17'd0;
    wire       ms_tick = mdiv == 17'd74249;
    always @(posedge clk_vid) mdiv <= ms_tick ? 17'd0 : mdiv + 17'd1;
    wire c_diag = btn[10] && btn[11] && btn[2];    // L+R+SELECT
    wire c_brow = btn[10] && btn[11] && btn[3];    // L+R+START
    wire c_boot = btn[10] && btn[11] && btn[8];    // L+R+A
    reg [9:0] hold = 10'd0;
    reg [1:0] held = 2'd0;                          // 1 diag, 2 browser, 3 boot (acted on)
    reg       diag_t = 1'b0, brow_t = 1'b0;
    wire [1:0] combo = c_diag ? 2'd1 : c_brow ? 2'd2 : c_boot ? 2'd3 : 2'd0;
    reg [1:0] combo_d = 2'd0;
    always @(posedge clk_vid) begin
        combo_d <= combo;
        force_v <= 1'b0;
        if (combo == 2'd0 || combo != combo_d) begin
            hold <= 10'd0;
            if (combo == 2'd0) held <= 2'd0;
        end else if (ms_tick && hold != COMBO_MS) begin
            hold <= hold + 10'd1;
        end else if (hold == COMBO_MS && held == 2'd0) begin
            held <= combo;
            case (combo)
                2'd1: diag_t <= ~diag_t;
                2'd2: brow_t <= ~brow_t;
                default: ;
            endcase
        end
        if (held == 2'd3) force_v <= 1'b1;
        st_prev <= st_v;
        if (st_v != st_prev && (st_v == S_RUN || st_v == S_LOAD)) begin
            diag_t <= 1'b0;
            brow_t <= 1'b0;
        end
    end
    wire forced = st_v == S_LOAD || st_v == S_PARSE || st_v == S_VERIFY || st_v == S_SHOW;
    wire [1:0] mode /* verilator public_flat_rd */ = forced || diag_t ? 2'd2 :
                      st_v == S_RUN ? (brow_t ? 2'd1 : 2'd0) :
                      st_v == S_FAIL ? (brow_t ? 2'd1 : 2'd2) : 2'd1;
    always @(posedge clk_vid) begin
        pic_pad_v  <= mode == 2'd1 || ((st_v == S_IDLE || st_v == S_NOTROM) && !forced);
        snes_pad_v <= st_v == S_RUN && mode != 2'd1;
        accept_v   <= mode == 2'd1;
    end

    // ================================================================ video
    wire [7:0]  vr, vg, vb;
    wire        vs0, vs1, vs2;
    wire [10:0] cx;
    wire [9:0]  cy;
    snes_video #(.OUT_W(OUT_W), .LOCK(LOCK), .SYNC_ORDER(SYNC_ORDER)) video (
        .clk_sys(clk_sys), .r(r), .g(g), .b(b), .dotclk(dotclk), .hde(hde), .vde(vde),
        .high_res(high_res), .v224(v224),
        .clk_vid(clk_vid), .vr(vr), .vg(vg), .vb(vb), .s0(vs0), .s1(vs1), .s2(vs2), .perm(),
        .cx(cx), .cy(cy));

    // status words for the diagnostics page (diag.txt); clock crossings are display-only
    wire [31:0] st [0:55];
    wire [31:0] flags = {13'd0, pad_std, 10'd0, 8'd1 << ld_state};
    assign st[0]  = ms;
    assign st[1]  = flags;
    assign st[2]  = {8'h02, 8'h00, 6'd0, mode, 5'd0, ld_state};
    assign st[3]  = n_stat;
    assign st[4]  = n_ui;
    assign st[5]  = n_padrd;
    assign st[6]  = n_wr;
    assign st[7]  = link_addr;
    assign st[8]  = n_file;
    assign st[9]  = crc_file;
    assign st[10] = file_end;
    assign st[11] = rom_size;
    assign st[12] = crc_rom;
    assign st[13] = n_order;
    assign st[14] = n_drop;
    assign st[15] = t_start;
    assign st[16] = t_end;
    assign st[17] = info_size;
    assign st[18] = info_crc;
    assign st[19] = {24'd0, info_type};
    assign st[20] = crc_sd;
    assign st[21] = hdr_w0;
    assign st[22] = hdr_w1;
    assign st[23] = {hdr_compl, 4'd0, scores};
    assign st[24] = {16'd0, n_loads, rom_type};
    assign st[25] = {8'd0, rom_mask};
    assign st[26] = {8'd0, ram_mask};
    assign st[27] = t_boot;
    assign st[28] = sd_reads;
    assign st[29] = {sd_forced, sd_stall};
    assign st[30] = {sd_late, 5'd0, sd_rfmax};
    assign st[31] = pad_raw;
    assign st[32] = pad_polls;
    assign st[33] = n_scr;
    assign st[34] = last_ui_ms;
    assign st[35] = n_log;
    assign st[36] = snes_frames;
    assign st[37] = {n_big[15:0], n_ign[15:0]};
    genvar gi;
    generate for (gi = 38; gi < 56; gi = gi + 1) begin : g_st0
        assign st[gi] = 32'd0;
    end endgenerate
    wire [1791:0] stat;
    generate for (gi = 0; gi < 56; gi = gi + 1) begin : g_stat
        assign stat[32*gi +: 32] = st[gi];
    end endgenerate

    // log rows 16-21 = entries 0-5 (newest first): words 56 address, 57 count, 58 {kind, D0},
    // 59 repeats, 60 time, 61 row number
    localparam [4:0] LOG_ROW0 = 5'd16;
    wire [4:0] row_next;
    wire [4:0] lrow = row_next - LOG_ROW0;
    assign log_idx = lrow[3:0];
    wire [255:0] rowstat = {64'd0, {28'd0, lrow[3:0]}, {10'd0, log_q[85:64]}, {16'd0, log_q[103:88]},
                            {log_q[63:56], 22'd0, log_q[87:86]}, {8'd0, log_q[55:32]},
                            log_q[31:0]};

    // external cells: strings by row (positions from diag.txt, see notes/snes-load.md)
    wire [4:0] ext_row;
    wire [6:0] ext_col;
    reg  [7:0] ext_s = 8'h20;
    reg        ext_t = 1'b0;
    assign txt_addr = ext_row == 5'd6 ? {2'd3, ext_col[4:0] - 5'd12} : {ld_kind, ext_col[4:0] - 5'd8};
    function [7:0] ch(input [8*24-1:0] s, input [6:0] i);       // character i of a 24-char string
        ch = i < 7'd24 ? s[8*(23 - i) +: 8] : 8'h20;
    endfunction
    reg [8*24-1:0] s_state, s_map, s_ver;
    always @(*) begin
        case (ld_state)
            S_IDLE:   s_state = "waiting (file browser)  ";
            S_LOAD:   s_state = "LOADING                 ";
            S_PARSE:  s_state = "PARSING HEADER          ";
            S_VERIFY: s_state = "VERIFYING SDRAM         ";
            S_SHOW:   s_state = "VERIFIED - STARTING     ";
            S_RUN:    s_state = "RUNNING                 ";
            S_FAIL:   s_state = "VERIFY FAILED           ";
            default:  s_state = "NOT A ROM FILE          ";
        endcase
        case ({ld_kind, ld_sa1})
            3'b000:  s_map = "LoROM                   ";
            3'b001:  s_map = "LoROM + SA-1            ";
            3'b010:  s_map = "HiROM                   ";
            3'b011:  s_map = "HiROM + SA-1            ";
            default: s_map = "ExHiROM                 ";
        endcase
        if (ld_unsup) s_map[8*12-1:0] = " (no chip)  ";
        if (ld_state < S_SHOW || ld_state == S_NOTROM)
            s_ver = "                        ";
        else if (ok_info)
            s_ver = "= INFO CRC: OK          ";
        else if (ok_fly && !info_ok)
            s_ver = "= TRANSFER CRC: OK      ";
        else
            s_ver = "MISMATCH                ";
    end
    always @(posedge clk_vid) begin
        ext_t <= ext_row == 5'd6 || ext_row == 5'd7;
        case (ext_row)
            5'd0:    ext_s <= ch(s_state, ext_col - 7'd47);
            5'd5:    ext_s <= ch(info_ok ? "SNTROM01 ok             " : "no info block           ", ext_col - 7'd7);
            5'd9:    ext_s <= ld_state >= S_VERIFY && ld_state != S_NOTROM ? ch(s_map, ext_col - 7'd7) : 8'h20;
            5'd10:   ext_s <= ch(s_ver, ext_col - 7'd35);
            default: ext_s <= ch(pad_std ? "std pad                 " : "no pad                  ", ext_col - 7'd54);
        endcase
    end
    wire [7:0] ext_q = ext_t ? txt_q : ext_s;

    wire [7:0] or_, og, ob;
    wire       ovalid;
    overlay #(.TMPL_HEX(TMPL_HEX), .FONT_HEX(FONT_HEX), .FLAG_WORD(1)) ovl (
        .clk(clk_vid), .hx(cx), .vy(cy), .mode(mode), .stat(stat), .rowstat(rowstat),
        .row_next(row_next), .scr_addr(scr_addr), .scr_q(scr_q), .ext_row(ext_row),
        .ext_col(ext_col), .ext_q(ext_q), .r(or_), .g(og), .b(ob), .valid(ovalid));

    // snes_video's outputs are 3 clocks ahead of the overlay's
    reg [26:0] vd1, vd2, vd3;
    always @(posedge clk_vid) begin
        vd1 <= {vs0, vs1, vs2, vr, vg, vb};
        vd2 <= vd1;
        vd3 <= vd2;
    end
    wire [7:0] mr = ovalid ? or_ : vd3[23:16];
    wire [7:0] mg = ovalid ? og  : vd3[15:8];
    wire [7:0] mb = ovalid ? ob  : vd3[7:0];
    reg so0 = 1'b0, so1 = 1'b0, so2 = 1'b0;
    always @(posedge clk_vid) begin
        {so0, so1, so2} <= vd3[26:24];
        case (CH_ORDER)
            1:       {ch1, ch2, ch3} <= {mr, mb, mg};
            2:       {ch1, ch2, ch3} <= {mg, mr, mb};
            3:       {ch1, ch2, ch3} <= {mg, mb, mr};
            4:       {ch1, ch2, ch3} <= {mb, mr, mg};
            5:       {ch1, ch2, ch3} <= {mb, mg, mr};
            default: {ch1, ch2, ch3} <= {mr, mg, mb};
        endcase
    end
    assign {s0, s1, s2} = {so0, so1, so2};
    altddio_out #(
        .extend_oe_disable("OFF"), .intended_device_family("Cyclone V"),
        .invert_output("OFF"), .lpm_hint("UNUSED"), .lpm_type("altddio_out"),
        .oe_reg("UNREGISTERED"), .power_up_high("OFF"), .width(1)
    ) pclk_ddio (
        .datain_h(1'b0), .datain_l(1'b1), .outclock(clk_vid), .dataout(pclk),
        .aclr(1'b0), .aset(1'b0), .oe(1'b1), .oe_out(), .outclocken(1'b1), .sclr(1'b0), .sset(1'b0)
    );

    // ================================================================ audio (silent until a game runs)
    wire mclk;
    audio_pll apll (.refclk(clk), .outclk_0(mclk), .locked());
    wire [15:0] al = core_reset ? 16'd0 : audio_l;
    wire [15:0] ar = core_reset ? 16'd0 : audio_r;
    i2s_out #(.FRAMING(AUD_FRAMING)) aout (
        .clk_src(clk_sys), .l(al), .r(ar),
        .mclk(mclk), .mclk_pin(aud_mclk), .bclk(aud_bclk), .lrclk(aud_lrclk), .sdata(aud_sdata));
endmodule
