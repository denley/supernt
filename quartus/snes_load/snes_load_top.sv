// SPDX-License-Identifier: GPL-3.0-or-later
// Super Nt top level: SNES + SA-1 core that loads its ROM from the SD card through the SPC
// player (notes/snes-load.md). The console loads this as SYSTEM/CORES/spc.cor; Tools -> "Play
// SPC Files" starts it and the PIC32 runs the player's file browser on it:
//   - link_ui.sv answers the PIC (status 02, pad registers, 0x2008 = 01), keeps the browser's
//     screen (0x1018_0000), which the overlay draws, and logs every transaction but the file;
//   - picking a file made by tools/rom2spc.py (a silent .spc with the ROM appended) makes the
//     PIC send the whole file to link address 0xFF00 + offset; rom_loader.sv stores the ROM in
//     SDRAM chip B (sdram_rom8.sv, 8-bit), detects the mapper from the header, reads the ROM
//     back and checks its CRC-32 against the file's info block, shows the result for 4 s on the
//     diagnostics page and then releases the SNES (reset, ROM reads on);
//   - the SNES core (quartus/snes_sdram/snes_sdram_core.sv: srg320's MiSTer core with SA-1 and
//     the Lo/HiROM mapper; SA1.vhd with sa1_vbp.patch) reads the ROM through the 8-bit
//     controller at 5 x clk_sys; v2: the SPC700's 64 KB ARAM lives in SDRAM bank 3 too (the
//     controller's ARAM port), which frees the block RAM for 64 KB of BW-RAM/SRAM (kept when
//     the same game is loaded again, cleared for another); video/audio as quartus/snes.
// Controller port 1 is polled by pad_poll.sv only; the SNES gets the bits through a virtual 4021
// (as MiSTer's ioport.sv) unless the menu view is up, the PIC through 0x2000/0x2001 (v2: always,
// as the stock core does; option: only while the menu view is up, as v1).
// v4: port 2 (data on D6, found by v3's pin scan; LATCH and CLOCK shared with port 1), a second
// virtual 4021 for the SNES.
// v5: the menu combination. While a game runs the PIC reads the pad registers (0x2000/0x2001,
// every ~33 ms; v4 console log) and wakes on SELECT, so during a game the registers read 0
// except while DOWN+SELECT is held: SELECT alone (and L+R+SELECT for our pages) stays the game's.
// A PIC that wakes while DOWN+SELECT is (or was within 1.5 s) held is shown at once; one that
// wakes otherwise (none should) stays hidden behind the game with 0s until DOWN+SELECT. Whenever
// the PIC's screen comes up during a game it gets 0s until all buttons are released (a SELECT
// still held would be its BACK TO GAME).
// Views: the game; the menu view (the PIC's screen at 0x1018_0000: its file browser or menu),
// shown by itself before a game, while the PIC is active after a game started (v2 "follow": any
// UI-loop or screen write within the last 600 ms) or toggled by L+R+SELECT+START (1 s); the
// diagnostics status page and the log view (L+R+SELECT, 0.5 s, cycles off -> status -> log ->
// off; the status page is shown by itself from the first file byte until the game starts).
// While the menu view is up a new file from the PIC replaces the game. On the status page L+R+UP
// / DOWN / LEFT (0.5 s) toggle the options: pad poll timing (stock / v1 fast), PIC pad registers
// (always / gated) and follow (on / off). L+R+A (0.5 s): boot after a failed verify.
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
    parameter BSRAM_AW   = 16,      // BW-RAM / SRAM in block RAM: 64 KB (v2; ARAM is in SDRAM)
    parameter TMPL_HEX   = "../../build/snes_load/diag.hex",
    parameter FONT_HEX   = "../../build/hwtest/font.hex",
    // simulation shortcuts (the real values are the defaults)
    parameter integer PAD_START_US = 200000,
    parameter integer DONE_MS = 250,
    parameter integer SHOW_MS = 4000,
    parameter integer COMBO_MS = 500,
    parameter integer MENU_MS = 1000,       // L+R+SELECT+START
    parameter integer FOLLOW_MS = 600,      // the PIC counts as active this long after a UI write
    parameter integer INIT_CYCLES = 21450,
    parameter integer WAKE_MS = 1500        // a PIC waking this long after DOWN+SELECT is shown
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
    input  wire       pad_d6,   // controller port 2 data
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
    wire [31:0] p2_raw /* verilator public_flat_rd */;
    wire        p2_std /* verilator public_flat_rd */;
    reg         opt_fast = 1'b0;                     // clk_vid: v1 pad timing
    reg         opt_gate = 1'b0;                     // clk_vid: v1 PIC pad gating
    reg         opt_follow = 1'b1;                   // clk_vid: show the PIC's screen when it is active
    pad_poll #(.START_US(PAD_START_US)) padp (
        .clk(clk_vid), .fast(opt_fast), .p14(pad_p14), .j13k16(pad_clk), .t12(pad_t12), .d6(pad_d6),
        .raw(pad_raw), .is_std(pad_std), .raw2(p2_raw), .is_std2(p2_std), .polls(pad_polls));
    assign pad_j13 = pad_clk;
    assign pad_k16 = pad_clk;
    wire [11:0] btn  = pad_std ? pad_raw[11:0] : 12'd0;
    wire [11:0] btn2 = p2_std ? p2_raw[11:0] : 12'd0;

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
    wire [8:0]  log_idx;
    wire [136:0] log_q;
    wire [26:0] log_newest;
    wire [8:0]  log_a_n;
    wire [31:0] ms /* verilator public_flat_rd */, n_stat /* verilator public_flat_rd */;
    wire [31:0] n_ui /* verilator public_flat_rd */, n_padrd /* verilator public_flat_rd */;
    wire [31:0] n_wr, n_scr, last_ui_ms, link_addr, n_log /* verilator public_flat_rd */;
    wire [31:0] n_rdall, last_txn_ms /* verilator public_flat_rd */, last_scr_ms, r21_ms;
    wire [7:0]  r21;
    wire [15:0] n_r21;
    link_ui #(.CLK_KHZ(107210)) lnk (
        .clk(clk_mem), .a(link_a), .n_rd(link_nrd), .n_wr(link_nwr), .d_in(link_d),
        .d_out(link_dout), .d_oe(link_oe),
        .pad(pad_m2[11:0]), .pad_std(pad_m2[12]), .pad_en(pic_pad_m[1]),
        .f_go(f_go), .f_addr(f_addr), .f_data(f_data),
        .clk_vid(clk_vid), .scr_addr(scr_addr), .scr_q(scr_q),
        .log_idx(log_idx), .log_q(log_q), .n_log(n_log), .newest(log_newest), .log_a_n(log_a_n),
        .ms(ms), .n_stat(n_stat), .n_ui(n_ui), .n_padrd(n_padrd), .n_data(n_wr), .n_scr(n_scr),
        .last_ui_ms(last_ui_ms), .addr(link_addr), .n_rdall(n_rdall), .last_txn_ms(last_txn_ms),
        .last_scr_ms(last_scr_ms), .r21(r21), .r21_ms(r21_ms), .n_r21(n_r21));

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
    wire [15:0] aram_addr;
    wire [7:0]  aram_d, aram_q;
    wire        aram_rd, aram_wr;
    wire [31:0] n_ar_rd /* verilator public_flat_rd */, n_ar_wr /* verilator public_flat_rd */;
    wire [15:0] n_ar_fwd, n_ar_late /* verilator public_flat_rd */, n_ar_drop /* verilator public_flat_rd */;
    wire [15:0] n_clash /* verilator public_flat_rd */;
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
        .n_reads(sd_reads),
        .ar_en(rom_en), .ar_addr(aram_addr), .ar_rd(aram_rd), .ar_wr(aram_wr), .ar_d(aram_d),
        .ar_q(aram_q), .n_ar_rd(n_ar_rd), .n_ar_wr(n_ar_wr), .n_ar_fwd(n_ar_fwd),
        .n_ar_late(n_ar_late), .n_ar_drop(n_ar_drop), .n_clash(n_clash));

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
    wire        ram_keep /* verilator public_flat_rd */, ram_clear;
    wire [31:0] last_game;
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
        .ok_info(ok_info), .ok_fly(ok_fly),
        .ram_keep(ram_keep), .ram_clear(ram_clear), .last_game(last_game), .aram_clr_done());

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
    wire        joy_strb, joy1_clk, joy2_clk /* verilator public_flat_rd */, joy_d0, joy2_d0;
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg [1:0]  clr_sync = 2'b00;
    always @(posedge clk_sys) clr_sync <= {clr_sync[0], ram_clear};
    snes_sdram_core #(.BSRAM_AW(BSRAM_AW), .ARAM_EXT(1)) snes (
        .clk_sys(clk_sys), .reset(core_reset), .rom_type(rom_type), .rom_mask(rom_mask),
        .ram_mask(ram_mask),
        .rom_addr(rom_addr), .rom_word(rom_word), .rom_q(rom_q), .rom_oe_n(rom_oe_n),
        .sysclkf_ce(sysclkf_ce), .sysclkr_ce(sysclkr_ce),
        .r(r), .g(g), .b(b), .dotclk(dotclk), .hde(hde), .vde(vde), .high_res(high_res),
        .v224(v224), .audio_l(audio_l), .audio_r(audio_r),
        .joy_strb(joy_strb), .joy_clk(), .joy1_clk(joy1_clk), .joy2_clk(joy2_clk),
        .joy1_d0(joy_d0), .joy2_d0(joy2_d0), .ext_aram_addr(aram_addr), .ext_aram_d(aram_d), .ext_aram_rd(aram_rd), .ext_aram_wr(aram_wr),
        .ext_aram_q(aram_q), .bsram_clr(clr_sync[1] & core_reset), .bsram_clr_done());

    // virtual controllers (MiSTer ioport.sv): {B Y SELECT START UP DOWN LEFT RIGHT A X L R 0000},
    // latched on the strobe, shifted at the start of each clock pulse of their port, 0 on the
    // line = pressed; then 0s (a pad's 1s after 16 bits). Port 2 without a pad: the line stays
    // high (reads 0 throughout, as an empty port).
    reg        snes_pad_v /* verilator public_flat_rd */ = 1'b0;   // clk_vid: the SNES gets the pads
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg [11:0] pad_s1 = 12'd0, pad_s2 = 12'd0, pad2_s1 = 12'd0, pad2_s2 = 12'd0;
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg [1:0]  pad_en_s = 2'b00, p2_on_s = 2'b00;
    reg [15:0] joy_lat = 16'hffff, joy2_lat /* verilator public_flat_rd */ = 16'hffff;
    reg        joy1_clk_d = 1'b0, joy2_clk_d = 1'b0;
    wire [11:0] pb  = pad_en_s[1] ? pad_s2 : 12'd0;
    wire [11:0] pb2 = pad_en_s[1] ? pad2_s2 : 12'd0;
    always @(posedge clk_sys) begin
        pad_s1 <= btn;
        pad_s2 <= pad_s1;
        pad2_s1 <= btn2;
        pad2_s2 <= pad2_s1;
        pad_en_s <= {pad_en_s[0], snes_pad_v};
        p2_on_s <= {p2_on_s[0], p2_std};
        joy1_clk_d <= joy1_clk;
        joy2_clk_d <= joy2_clk;
        if (joy_strb)
            joy_lat <= ~{pb[0], pb[1], pb[2], pb[3], pb[4], pb[5], pb[6], pb[7], pb[8], pb[9],
                         pb[10], pb[11], 4'b0000};
        else if (!joy1_clk_d && joy1_clk)
            joy_lat <= {joy_lat[14:0], 1'b0};
        if (joy_strb)
            joy2_lat <= ~{pb2[0], pb2[1], pb2[2], pb2[3], pb2[4], pb2[5], pb2[6], pb2[7], pb2[8],
                          pb2[9], pb2[10], pb2[11], 4'b0000};
        else if (!joy2_clk_d && joy2_clk)
            joy2_lat <= {joy2_lat[14:0], 1'b0};
    end
    assign joy_d0  = joy_lat[15];
    assign joy2_d0 = p2_on_s[1] ? joy2_lat[15] : 1'b1;

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
    // the PIC is active: a UI-loop or screen write within FOLLOW_MS, after the boot (clk_mem)
    reg  pic_act_m = 1'b0;
    always @(posedge clk_mem)
        pic_act_m <= rom_en && ((last_ui_ms > t_boot && ms - last_ui_ms < FOLLOW_MS) ||
                                (last_scr_ms > t_boot && ms - last_scr_ms < FOLLOW_MS));
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg [1:0] pic_act_v = 2'b00;
    always @(posedge clk_vid) pic_act_v <= {pic_act_v[0], pic_act_m};
    reg [16:0] mdiv = 17'd0;
    wire       ms_tick = mdiv == 17'd74249;
    always @(posedge clk_vid) mdiv <= ms_tick ? 17'd0 : mdiv + 17'd1;
    // v4: the woken PIC is shown only after DOWN+SELECT (pic_shown); otherwise it stays hidden
    reg        pic_shown /* verilator public_flat_rd */ = 1'b0;
    reg        pic_act_d = 1'b0;
    reg [10:0] dsel = 11'd0;                         // ms left in which a waking PIC is shown
    wire       dsel_now = btn[5] && btn[2];          // DOWN + SELECT (other buttons allowed)
    always @(posedge clk_vid) begin
        pic_act_d <= pic_act_v[1];
        if (dsel_now) dsel <= WAKE_MS[10:0];
        else if (ms_tick && dsel != 11'd0) dsel <= dsel - 11'd1;
        if (!pic_act_v[1]) pic_shown <= 1'b0;
        else if (!pic_act_d) pic_shown <= dsel_now || dsel != 11'd0;
        else if (dsel_now) pic_shown <= 1'b1;
    end
    wire follow_on = opt_follow && pic_act_v[1] && pic_shown;

    // button combinations, exact (no other button held), held for COMBO_MS / MENU_MS
    localparam [11:0] B_SEL = 12'h004, B_START = 12'h008, B_UP = 12'h010, B_DOWN = 12'h020,
                      B_LEFT = 12'h040, B_A = 12'h100, B_L = 12'h400, B_R = 12'h800;
    localparam [11:0] LR = B_L | B_R;
    wire [2:0] combo = btn == (LR | B_SEL)           ? 3'd1 :     // pages
                       btn == (LR | B_SEL | B_START) ? 3'd2 :     // menu view
                       btn == (LR | B_A)             ? 3'd3 :     // boot anyway
                       btn == (LR | B_UP)            ? 3'd4 :     // option: poll timing
                       btn == (LR | B_DOWN)          ? 3'd5 :     // option: PIC pad gating
                       btn == (LR | B_LEFT)          ? 3'd6 : 3'd0;  // option: follow
    reg [10:0] hold = 11'd0;
    reg [2:0]  held = 3'd0;                         // the combination acted on (until released)
    reg [2:0]  combo_d = 3'd0;
    reg [1:0]  diag_v = 2'd0;                       // 0 off, 1 status page, 2 log view
    reg        menu_t /* verilator public_flat_rd */ = 1'b0;   // menu view by the keys
    wire [10:0] need = combo == 3'd2 ? MENU_MS[10:0] : COMBO_MS[10:0];
    always @(posedge clk_vid) begin
        combo_d <= combo;
        force_v <= 1'b0;
        if (combo == 3'd0 || combo != combo_d) begin
            hold <= 11'd0;
            if (combo == 3'd0) held <= 3'd0;
        end else if (ms_tick && hold < need) begin
            hold <= hold + 11'd1;
        end else if (hold >= need && held == 3'd0) begin
            held <= combo;
            case (combo)
                3'd1: diag_v <= diag_v == 2'd2 ? 2'd0 : diag_v + 2'd1;
                3'd2: menu_t <= ~menu_t;
                3'd4: if (diag_v == 2'd1) opt_fast <= ~opt_fast;
                3'd5: if (diag_v == 2'd1) opt_gate <= ~opt_gate;
                3'd6: if (diag_v == 2'd1) opt_follow <= ~opt_follow;
                default: ;
            endcase
        end
        if (held == 3'd3) force_v <= 1'b1;
        st_prev <= st_v;
        if (st_v != st_prev && st_v == S_LOAD) menu_t <= 1'b0;
        if (st_v != st_prev && st_v == S_RUN) begin menu_t <= 1'b0; diag_v <= 2'd0; end
    end
    wire forced = st_v == S_LOAD || st_v == S_PARSE || st_v == S_VERIFY || st_v == S_SHOW;
    wire menu_up = st_v == S_RUN ? menu_t || follow_on : st_v == S_FAIL ? menu_t : 1'b1;
    // 0 game, 1 menu (the PIC's screen), 2 status page, 3 log view
    wire [1:0] mode /* verilator public_flat_rd */ = diag_v == 2'd2 ? 2'd3 :
                      forced || diag_v == 2'd1 || (st_v == S_FAIL && !menu_t) ? 2'd2 :
                      menu_up ? 2'd1 : 2'd0;
    // v5: during a game the PIC gets buttons while DOWN+SELECT is held (to wake it) and while its
    // screen is shown (follow_on; not the keys' menu view), there only once all buttons held when
    // it came up are released
    reg follow_d = 1'b0, rel_wait = 1'b0;
    always @(posedge clk_vid) begin
        follow_d <= follow_on;
        if (st_v == S_RUN && follow_on && !follow_d) rel_wait <= 1'b1;
        else if (btn == 12'd0) rel_wait <= 1'b0;
        pic_pad_v  <= st_v == S_RUN ? (follow_on ? !rel_wait : dsel_now) :
                      !opt_gate || (menu_up && !forced) || st_v == S_IDLE || st_v == S_NOTROM;
        snes_pad_v <= st_v == S_RUN && !menu_up;
        accept_v   <= menu_up && st_v == S_RUN;
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
    // log view pages: 20 entries each, first the entries after the first file (0-383, in order),
    // then the ring (384-511); the page advances every 150 frames (2.5 s)
    reg  [5:0]  page = 6'd0;
    reg  [7:0]  pframes = 8'd0;
    wire [21:0] pa_m = {12'd0, {1'b0, log_a_n} + 10'd19} * 22'd3277;   // / 20 (exact below 1000)
    wire [5:0]  pa = pa_m[21:16];                                       // ceil(a_n / 20)
    wire [5:0]  npages = pa + 6'd7;
    always @(posedge clk_vid) begin
        if (mode != 2'd3) begin page <= 6'd0; pframes <= 8'd0; end
        else if (cy == 10'd720 && cx == 11'd0) begin
            if (pframes == 8'd149) begin
                pframes <= 8'd0;
                page <= page + 6'd1 >= npages ? 6'd0 : page + 6'd1;
            end else pframes <= pframes + 8'd1;
        end
    end
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
    assign st[38] = n_ar_rd;
    assign st[39] = n_ar_wr;
    assign st[40] = {n_ar_fwd, n_ar_late};
    assign st[41] = {n_ar_drop, n_clash};
    assign st[42] = n_rdall;
    assign st[43] = last_txn_ms;
    assign st[44] = last_scr_ms;
    assign st[45] = {r21, 8'd0, n_r21};
    assign st[46] = r21_ms;
    assign st[47] = last_game;
    assign st[48] = {23'd0, log_a_n};
    genvar gi;
    assign st[49] = p2_raw;
    generate for (gi = 50; gi < 56; gi = gi + 1) begin : g_st0
        assign st[gi] = 32'd0;
    end endgenerate
    wire [1791:0] stat;
    generate for (gi = 0; gi < 56; gi = gi + 1) begin : g_stat
        assign stat[32*gi +: 32] = st[gi];
    end endgenerate

    // log rows: status page rows 20-21 = the 2 newest entries; log view rows 2-21 = page entries.
    // Words 56 address, 57 {seq, count}, 58 {kind at bit 24, first byte}, 59 repeats,
    // 60 t_first, 61 t_last, 62 entry index.
    localparam integer LOG_T0 = 18;
    wire [4:0] row_next;
    wire [4:0] lrow = row_next - 5'd2;
    wire [9:0] pbase = page < pa ? {4'd0, page} * 10'd20 : 10'd384 + {4'd0, page - pa} * 10'd20;
    wire [9:0] lidx = pbase + {5'd0, lrow};
    wire       lblank = mode == 2'd3 ? (row_next < 5'd2 || (page < pa ? lidx >= {1'b0, log_a_n} : lidx > 10'd511)) :
                        (row_next < 5'd20 || n_log < (row_next == 5'd20 ? 32'd1 : 32'd2));
    assign log_idx = mode == 2'd3 ? lidx[8:0] : row_next == 5'd20 ? log_newest[8:0] : log_newest[17:9];
    reg        lblank_q = 1'b0;
    reg  [8:0] lidx_q = 9'd0;
    always @(posedge clk_vid) begin lblank_q <= lblank; lidx_q <= log_idx; end
    wire [255:0] rowstat = lblank_q ? 256'd0 :
        {32'd0, {23'd0, lidx_q}, {8'd0, log_q[103:80]}, {8'd0, log_q[79:56]}, {16'd0, log_q[119:104]},
         {7'd0, log_q[136], 16'd0, log_q[55:48]}, {log_q[135:120], log_q[47:32]}, log_q[31:0]};

    // external cells: strings by row (positions from diag.txt, see notes/snes-load.md)
    wire [4:0] ext_row;
    wire [6:0] ext_col;
    reg  [7:0] ext_s = 8'h20;
    reg        ext_t = 1'b0;
    assign txt_addr = ext_row == 5'd7 ? {2'd3, ext_col[4:0] - 5'd12} : {ld_kind, ext_col[4:0] - 5'd8};
    function [7:0] ch(input [8*24-1:0] s, input [6:0] i);       // character i of a 24-char string
        ch = i < 7'd24 ? s[8*(23 - i) +: 8] : 8'h20;
    endfunction
    function [7:0] chn(input [8*70-1:0] s, input [6:0] i);      // character i of a 70-char string
        chn = i < 7'd70 ? s[8*(69 - i) +: 8] : 8'h20;
    endfunction
    function [7:0] hexc(input [3:0] v);
        hexc = v < 4'd10 ? 8'h30 + {4'd0, v} : 8'h37 + {4'd0, v};
    endfunction
    reg [8*24-1:0] s_state, s_map, s_ver;
    reg [8*70-1:0] s_opt, s_ram;
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
        s_opt = {opt_fast ? "UP poll FAST (v1) " : "UP poll STOCK     ",
                 opt_gate ? "DOWN pad GATED (v1) " : "DOWN pad ALWAYS     ",
                 opt_follow ? "LEFT follow ON   " : "LEFT follow OFF  ",
                 st_v != S_RUN ? "               " :
                 !menu_up ? (pic_act_v[1] ? "view GAME+PIC  " : "view GAME      ") :
                 menu_t ? "view MENU(keys)" : "view MENU(PIC) "};
        s_ram = {ram_mask == 24'd0 ? "none (header RAM size 0)                " :
                 ld_state < S_SHOW || ld_state == S_NOTROM ? "64 KB block RAM                         " :
                 ram_keep ? "64 KB: KEPT (same game as last boot)    " :
                            "64 KB: CLEARED (another game)           ", 240'd0};
    end
    always @(posedge clk_vid) begin
        ext_t <= ext_row == 5'd7 || ext_row == 5'd8;
        case (ext_row)
            5'd0:    ext_s <= ch(s_state, ext_col - 7'd50);
            5'd6:    ext_s <= ch(info_ok ? "SNTROM01 ok             " : "no info block           ", ext_col - 7'd7);
            5'd10:   ext_s <= ld_state >= S_VERIFY && ld_state != S_NOTROM ? ch(s_map, ext_col - 7'd7) : 8'h20;
            5'd11:   ext_s <= ch(s_ver, ext_col - 7'd35);
            5'd15:   ext_s <= chn(s_ram, ext_col - 7'd16);
            5'd16:   ext_s <= chn(s_opt, ext_col - 7'd9);
            5'd17:   ext_s <= ch(p2_std ? "std pad                 " : "no pad                  ", ext_col - 7'd31);
            5'd18:   ext_s <= ext_col < 7'd60 ?
                         ch(mode == 2'd3 ? "20 per page, auto paging" : "2 newest below          ", ext_col - 7'd14) :
                         mode != 2'd3 ? 8'h20 :
                         ext_col == 7'd67 ? "p" : ext_col == 7'd68 ? "g" : ext_col == 7'd70 ? hexc(page[5:4]) :
                         ext_col == 7'd71 ? hexc(page[3:0]) : ext_col == 7'd72 ? "/" :
                         ext_col == 7'd73 ? hexc(npages[5:4]) : ext_col == 7'd74 ? hexc(npages[3:0]) : 8'h20;
            default: ext_s <= ch(pad_std ? "std pad                 " : "no pad                  ", ext_col - 7'd54);
        endcase
    end
    wire [7:0] ext_q = ext_t ? txt_q : ext_s;

    wire [7:0] or_, og, ob;
    wire       ovalid;
    overlay #(.TMPL_HEX(TMPL_HEX), .FONT_HEX(FONT_HEX), .FLAG_WORD(1), .LOG_T0(LOG_T0)) ovl (
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
