// SPDX-License-Identifier: GPL-3.0-or-later
// ROM loader for quartus/snes_load (notes/snes-load.md): takes the file the SPC player sends
// over the PIC32 link (link_ui.sv's f_go stream: byte at link address 0xFF00 + file offset),
// stores the ROM part in SDRAM (sdram_rom8.sv, byte k of the ROM at SDRAM byte k), works out
// the mapper from the ROM header, reads the whole ROM back from SDRAM and compares its CRC-32,
// and then lets the SNES run. File layout (tools/rom2spc.py): a complete .spc (0x10200 bytes)
// with an info block at 0x10180-0x101BF ("SNTROM01", ROM size, ROM CRC-32, name), then the ROM.
//
// States (`state`):
//   0 IDLE    no file yet (the player's file browser is on screen)
//   1 LOAD    file bytes arriving; the SNES is held in reset and ROM reads are off
//   2 PARSE   transfer over: header scores, mapper, masks
//   3 VERIFY  reading the ROM back from SDRAM (CRC-32)
//   4 SHOW    results on the diagnostics page for SHOW_MS, then RUN
//   5 RUN     ROM reads on, SNES out of reset
//   6 FAIL    the read-back CRC doesn't match (no boot; `force_boot` boots anyway)
//   7 NOTROM  the file had no ROM part (a plain .spc)
// A file byte arriving in any state but LOAD starts a new load (SNES back in reset), except in
// RUN while `accept` is low: then it is only counted (n_ign). The top sets `accept` only while
// the file browser is on screen, so a file the player sends by itself while a game runs (e.g.
// auto-advance to the next file) can't reset the game.
// End of the transfer: all `info size` ROM bytes received (info block present), or no file
// byte for DONE_MS with more than 0x10200 bytes received... or DONE_MS with fewer (NOTROM).
//
// Header detection as the Pocket's rom_parser.sv / MiSTer (LoROM header at ROM 0x7FC0, HiROM
// 0xFFC0, ExHiROM 0x40FFC0: +4 if checksum + complement = FFFF, +2 dev id 33, +1 each for a
// plausible type/ROM size/RAM size/region, +2 for the matching map mode, ExHiROM +4 if any):
// LoROM if its score is >= both others, HiROM if >= ExHiROM, ExHiROM if > 0. Chip: SA-1
// (map 23, type 32/34/35) -> ROM_TYPE 6x; other chips are not in this core (flagged, booted as
// plain Lo/HiROM). ROM mask = next power of two of the size - 1; RAM mask = (1 KB << RAM size)
// - 1 (0 for none).
module rom_loader #(
    parameter integer CLK_KHZ  = 107210,
    parameter integer DONE_MS  = 250,
    parameter integer SHOW_MS  = 4000,
    parameter [31:0]  FILE_BASE = 32'h0000_FF00
) (
    input  wire        clk,
    input  wire [31:0] ms,                  // time (link_ui)
    input  wire        f_go,
    input  wire [31:0] f_addr,
    input  wire [7:0]  f_data,
    input  wire        force_boot,          // FAIL -> RUN (pad combination, synchronised)
    input  wire        accept,              // RUN: a new file may replace the game (synchronised)
    // SDRAM (sdram_rom8.sv)
    input  wire        sd_ready,
    output reg         wr_req = 1'b0,
    output reg  [22:0] wr_addr = 23'd0,
    output reg  [7:0]  wr_data = 8'd0,
    input  wire        wr_ack,
    output reg         aux_req = 1'b0,
    output reg  [22:0] aux_addr = 23'd0,
    input  wire        aux_ack,
    input  wire        aux_valid,
    input  wire [7:0]  aux_q,
    // to the core (quasi-static: they change only while the core is in reset)
    output reg         rom_en = 1'b0,       // ROM reads on, SNES may run
    output reg  [7:0]  rom_type = 8'd0,
    output reg  [23:0] rom_mask = 24'd0,
    output reg  [23:0] ram_mask = 24'd0,
    // header titles and the info block's name, read port for the overlay (clk_vid):
    // 0x00-0x1F LoROM header bytes 0-31, 0x20 HiROM, 0x40 ExHiROM, 0x60-0x7F the name
    input  wire        clk_vid,
    input  wire [6:0]  txt_addr,
    output reg  [7:0]  txt_q,
    // status
    output reg  [2:0]  state = 3'd0,
    output reg  [31:0] n_file = 32'd0,      // file bytes received
    output reg  [31:0] file_end = 32'd0,    // highest file offset + 1
    output reg  [31:0] crc_file = 32'd0,    // CRC-32 of the file bytes in arrival order
    output reg  [31:0] rom_size = 32'd0,    // highest ROM offset + 1
    output reg  [31:0] crc_rom = 32'd0,     // CRC-32 of the ROM bytes in arrival order
    output reg  [31:0] crc_sd = 32'd0,      // CRC-32 of the ROM read back from SDRAM
    output reg  [31:0] n_order = 32'd0,     // bytes not at the expected (next) offset
    output reg  [31:0] n_drop = 32'd0,      // bytes lost to a full write FIFO
    output reg  [31:0] n_big = 32'd0,       // ROM bytes beyond 8 MB (not stored)
    output reg  [31:0] n_ign = 32'd0,       // file bytes ignored while a game ran
    output reg  [31:0] t_start = 32'd0,     // ms: first byte
    output reg  [31:0] t_end = 32'd0,       // ms: transfer over
    output reg  [31:0] t_boot = 32'd0,      // ms: SNES released
    output reg  [7:0]  n_loads = 8'd0,
    output wire        info_ok,             // magic "SNTROM01" seen
    output wire [31:0] info_size,
    output wire [31:0] info_crc,
    output wire [7:0]  info_type,           // the tool's mapper guess
    output reg  [1:0]  kind = 2'd0,         // 0 LoROM 1 HiROM 2 ExHiROM
    output reg         sa1 = 1'b0,
    output reg         chip_unsup = 1'b0,
    output reg  [11:0] scores = 12'd0,      // {ExHi, Hi, Lo} 4 bits each (saturated)
    output reg  [31:0] hdr_w0 = 32'd0,      // chosen header {map, type, rom size, ram size}
    output reg  [31:0] hdr_w1 = 32'd0,      // {region, dev, checksum[15:0]}
    output reg  [15:0] hdr_compl = 16'd0,
    output reg         ok_info = 1'b0,      // crc_sd == info_crc (and sizes match)
    output reg         ok_fly = 1'b0,       // crc_sd == crc_rom
    // v2: save RAM kept across reloads of the same game (ROM CRC-32 as the last game booted);
    // BW-RAM/SRAM is cleared (by the top, while `ram_clear`) when another game is booted
    output reg         ram_keep = 1'b0,     // valid from SHOW on
    output wire        ram_clear,           // SHOW and not ram_keep: the top clears the RAM
    output reg  [31:0] last_game = 32'd0,   // ROM CRC-32 of the game booted last (0: none)
    output reg         aram_clr_done = 1'b0 // ARAM (SDRAM bank 3) cleared for this boot
);
    localparam [2:0] S_IDLE = 0, S_LOAD = 1, S_PARSE = 2, S_VERIFY = 3, S_SHOW = 4, S_RUN = 5,
                     S_FAIL = 6, S_NOTROM = 7;
    localparam [31:0] ROM_OFF = 32'h10200, INFO_OFF = 32'h10180;
    localparam [22:0] ARAM_BASE = 23'h600000;     // sdram_rom8.sv's ARAM bank
    reg  [16:0] aclr = 17'd0;                     // ARAM bytes cleared (SHOW)
    assign ram_clear = (state == S_SHOW || state == S_FAIL) && !ram_keep;

    function [31:0] crc8(input [31:0] c, input [7:0] b);    // reflected CRC-32, one byte
        integer i;
        reg [31:0] r;
        begin
            r = c ^ {24'd0, b};
            for (i = 0; i < 8; i = i + 1)
                r = r[0] ? (r >> 1) ^ 32'hEDB88320 : r >> 1;
            crc8 = r;
        end
    endfunction

    // ------------------------------------------------------------ stage 1: decode the byte
    wire [31:0] off = f_addr - FILE_BASE;
    wire [31:0] k   = off - ROM_OFF;            // ROM offset (valid if off >= ROM_OFF)
    reg         b_go = 1'b0, b_rom = 1'b0, b_info = 1'b0;
    reg  [31:0] b_off = 32'd0, b_k = 32'd0;
    reg  [7:0]  b_d = 8'd0;
    reg  [1:0]  b_area = 2'd0;
    reg         b_hdr = 1'b0;
    always @(posedge clk) begin
        b_go <= f_go;
        b_off <= off;
        b_k <= k;
        b_d <= f_data;
        b_rom <= off >= ROM_OFF;
        b_info <= off >= INFO_OFF && off < INFO_OFF + 32'h40;
        b_hdr <= k[31:5] == 27'h3FE || k[31:5] == 27'h7FE || k[31:5] == 27'h207FE;  // 7FC0 FFC0 40FFC0 + 0..1F
        b_area <= k[22] ? 2'd2 : k[15] ? 2'd1 : 2'd0;
    end

    // ------------------------------------------------------------ info block and header bytes
    reg [7:0] info [0:19];                      // info block bytes 0x00-0x13
    integer ii;
    initial for (ii = 0; ii < 20; ii = ii + 1) info[ii] = 8'd0;
    assign info_ok = {info[0], info[1], info[2], info[3], info[4], info[5], info[6], info[7]} ==
                     64'h534E54524F4D3031;      // "SNTROM01"
    assign info_size = {info[11], info[10], info[9], info[8]};
    assign info_crc  = {info[15], info[14], info[13], info[12]};
    assign info_type = info[17];
    // header fields 0x15-0x1F per area
    reg [7:0] hf [0:2][0:10];
    integer ai, fi;
    initial for (ai = 0; ai < 3; ai = ai + 1) for (fi = 0; fi < 11; fi = fi + 1) hf[ai][fi] = 8'd0;
    // titles and name for the overlay
    (* ramstyle = "M10K, no_rw_check" *) reg [7:0] txt [0:127];
    initial for (ii = 0; ii < 128; ii = ii + 1) txt[ii] = 8'h20;
    reg        t_we = 1'b0;
    reg [6:0]  t_wa = 7'd0;
    reg [7:0]  t_wd = 8'd0;
    always @(posedge clk) if (t_we) txt[t_wa] <= t_wd;
    always @(posedge clk_vid) txt_q <= txt[txt_addr];

    // ------------------------------------------------------------ write FIFO
    // registers, not a RAM: as an M10K, Quartus moved the controller's accept logic into its
    // read clock enable, which put the SNES CPU address on a one-cycle path
    (* ramstyle = "logic" *) reg [30:0] fifo [0:15];    // {address[22:0], byte}
    reg [4:0]  wp = 5'd0, rp = 5'd0;
    wire       f_empty = wp == rp;
    wire       f_full = (wp - rp) == 5'd16;
    reg        push = 1'b0;
    reg [30:0] push_d = 31'd0;
    reg        fifo_clr = 1'b0;
    always @(posedge clk) begin
        if (push && !f_full) begin
            fifo[wp[3:0]] <= push_d;
            wp <= wp + 5'd1;
        end
        if (wr_ack) rp <= rp + 5'd1;
        if (fifo_clr) begin wp <= 5'd0; rp <= 5'd0; end
    end
    always @(posedge clk) begin
        wr_req  <= !f_empty && !wr_ack && !fifo_clr;
        wr_addr <= fifo[rp[3:0]][30:8];
        wr_data <= fifo[rp[3:0]][7:0];
    end

    // ------------------------------------------------------------ header scoring
    function [3:0] score(input [1:0] ar, input [7:0] map, input [7:0] typ, input [7:0] rsz,
                         input [7:0] ssz, input [7:0] reg_, input [7:0] dev, input [15:0] cpl,
                         input [15:0] sum);
        reg [3:0] s;
        begin
            s = 4'd0;
            if (sum != 16'd0 && cpl != 16'd0 && sum + cpl == 16'hFFFF) s = s + 4'd4;
            if (dev == 8'h33) s = s + 4'd2;
            if (typ < 8'd8) s = s + 4'd1;
            if (rsz < 8'd16) s = s + 4'd1;
            if (ssz < 8'd8) s = s + 4'd1;
            if (reg_ < 8'd14) s = s + 4'd1;
            if (ar == 2'd0 && (map == 8'h20 || map == 8'h22)) s = s + 4'd2;
            if (ar == 2'd1 && map == 8'h21) s = s + 4'd2;
            if (ar == 2'd2 && (map == 8'h25 || map == 8'h35)) s = s + 4'd2;
            if (ar == 2'd2 && s != 4'd0) s = (s > 4'd11) ? 4'd15 : s + 4'd4;
            score = s;
        end
    endfunction
    // fields: hf[a][0] = 0x15 map, 1 type, 2 ROM size, 3 RAM size, 4 region, 5 dev, 6 version,
    // 7-8 complement, 9-10 checksum
    wire [3:0] sc0 = rom_size > 32'h7FE0 ?
        score(2'd0, hf[0][0], hf[0][1], hf[0][2], hf[0][3], hf[0][4], hf[0][5], {hf[0][8], hf[0][7]}, {hf[0][10], hf[0][9]}) : 4'd0;
    wire [3:0] sc1 = rom_size > 32'hFFE0 ?
        score(2'd1, hf[1][0], hf[1][1], hf[1][2], hf[1][3], hf[1][4], hf[1][5], {hf[1][8], hf[1][7]}, {hf[1][10], hf[1][9]}) : 4'd0;
    wire [3:0] sc2 = rom_size > 32'h40FFE0 ?
        score(2'd2, hf[2][0], hf[2][1], hf[2][2], hf[2][3], hf[2][4], hf[2][5], {hf[2][8], hf[2][7]}, {hf[2][10], hf[2][9]}) : 4'd0;
    // (registered in stages: S_PARSE waits for them; its inputs don't change there)
    reg  [3:0] sc0_q = 4'd0, sc1_q = 4'd0, sc2_q = 4'd0;
    wire [1:0] win = (sc0_q >= sc1_q && sc0_q >= sc2_q) ? 2'd0 : (sc1_q >= sc2_q) ? 2'd1 :
                     (sc2_q != 4'd0) ? 2'd2 : 2'd0;
    reg  [1:0] win_q = 2'd0;
    wire [23:0] sz1 = rom_size[23:0] - 24'd1;
    wire [23:0] m1 = sz1 | (sz1 >> 1);
    wire [23:0] m2 = m1 | (m1 >> 2);
    wire [23:0] m3 = m2 | (m2 >> 4);
    wire [23:0] m4 = m3 | (m3 >> 8);
    wire [23:0] pow_mask = m4 | (m4 >> 16);
    reg  [23:0] pmask_q = 24'd0;
    reg  [7:0]  map_q = 8'd0, typ_q = 8'd0, ssz_q = 8'd0;
    reg  [3:0]  pdly = 4'd0;
    always @(posedge clk) begin
        sc0_q <= sc0; sc1_q <= sc1; sc2_q <= sc2;
        win_q <= win;
        pmask_q <= pow_mask;
        map_q <= hf[win_q][0]; typ_q <= hf[win_q][1]; ssz_q <= hf[win_q][3];
    end

    // ------------------------------------------------------------ main state machine
    reg [31:0] exp_off = 32'd0;
    reg [31:0] t_last = 32'd0;
    reg [23:0] vk = 24'd0;                      // verify: next byte to read
    reg [23:0] vn = 24'd0;                      // verify: bytes checked
    wire [23:0] vlim = rom_size[31:23] != 9'd0 || rom_size[22:21] == 2'b11 ? 24'h600000 : rom_size[23:0];
    reg [31:0] vcrc = 32'hFFFFFFFF;
    reg [31:0] fcrc = 32'hFFFFFFFF, rcrc = 32'hFFFFFFFF;
    reg [31:0] t_show = 32'd0;
    wire [7:0] map_w = map_q, typ_w = typ_q, ssz_w = ssz_q;
    wire       sa1_w = map_w == 8'h23 && (typ_w == 8'h32 || typ_w == 8'h34 || typ_w == 8'h35);
    wire       got_all = info_ok && rom_size >= info_size && info_size != 32'd0 && n_file > ROM_OFF;
    wire       idle_long = ms - t_last >= DONE_MS;
    always @(posedge clk) begin
        push <= 1'b0;
        t_we <= 1'b0;
        fifo_clr <= 1'b0;
        // ---- every file byte (stage 2)
        if (b_go && state == S_RUN && !accept) begin
            n_ign <= n_ign + 32'd1;
        end else if (b_go) begin
            if (state != S_LOAD) begin
                // a new file: start over
                state <= S_LOAD;
                rom_en <= 1'b0;
                n_file <= 32'd1;
                file_end <= b_off + 32'd1;
                fcrc <= crc8(32'hFFFFFFFF, b_d);
                rcrc <= 32'hFFFFFFFF;
                rom_size <= b_rom ? b_k + 32'd1 : 32'd0;
                exp_off <= b_off + 32'd1;
                n_order <= b_off != 32'd0 ? 32'd1 : 32'd0;
                n_drop <= 32'd0;
                n_big <= 32'd0;
                t_start <= ms;
                n_loads <= n_loads + 8'd1;
                for (ii = 0; ii < 20; ii = ii + 1) info[ii] <= 8'd0;
                for (ai = 0; ai < 3; ai = ai + 1) for (fi = 0; fi < 11; fi = fi + 1) hf[ai][fi] <= 8'd0;
                ok_info <= 1'b0; ok_fly <= 1'b0;
                fifo_clr <= 1'b1;
            end else begin
                n_file <= n_file + 32'd1;
                if (b_off + 32'd1 > file_end) file_end <= b_off + 32'd1;
                fcrc <= crc8(fcrc, b_d);
                if (b_off != exp_off) n_order <= n_order + 32'd1;
                exp_off <= b_off + 32'd1;
                if (b_rom) begin
                    rcrc <= crc8(rcrc, b_d);
                    if (b_k + 32'd1 > rom_size) rom_size <= b_k + 32'd1;
                end
            end
            t_last <= ms;
            if (b_info && b_off[5:0] < 6'd20) info[b_off[5:0]] <= b_d;
            if (b_info && b_off[5]) begin
                t_we <= 1'b1; t_wa <= {2'd3, b_off[4:0]}; t_wd <= b_d;
            end
            if (b_rom) begin
                if (b_k[31:23] != 9'd0 || b_k[22:21] == 2'b11) n_big <= n_big + 32'd1;   // >= 6 MB: the ARAM bank
                else if (f_full) n_drop <= n_drop + 32'd1;
                else begin
                    push <= 1'b1;
                    push_d <= {b_k[22:0], b_d};
                end
                if (b_hdr) begin
                    if (b_k[4:0] < 5'd21) begin
                        t_we <= 1'b1; t_wa <= {b_area, b_k[4:0]}; t_wd <= b_d;
                    end
                    if (b_k[4:0] >= 5'h15) hf[b_area][b_k[4:0] - 5'h15] <= b_d;
                end
            end
        end else case (state)
            S_LOAD: if (got_all && f_empty || idle_long) begin
                t_end <= ms;
                crc_file <= ~fcrc;
                crc_rom <= ~rcrc;
                state <= rom_size != 32'd0 ? S_PARSE : S_NOTROM;
                pdly <= 4'd0;
            end
            S_PARSE: if (pdly != 4'd8) pdly <= pdly + 4'd1;
                else if (f_empty && !wr_req) begin
                scores <= {sc2_q, sc1_q, sc0_q};
                kind <= win_q;
                sa1 <= sa1_w;
                // chips this core doesn't have (rom_parser.sv's list, roughly): DSP/ST/OBC1
                // (type 03/05/F6/25 with map 20/21/30/31), SPC7110 (map 3A), S-RTC (35/55),
                // CX4 (20/F3), SDD1 (32/43,45), GSU (20/13,14,15,1A)
                chip_unsup <= (typ_w == 8'h03 || typ_w == 8'h05 || typ_w == 8'hF6 || typ_w == 8'h25 ||
                               typ_w == 8'hF3 || typ_w == 8'h43 || typ_w == 8'h45 || typ_w == 8'h13 ||
                               typ_w == 8'h14 || typ_w == 8'h15 || typ_w == 8'h1A || typ_w == 8'h55 ||
                               map_w == 8'h3A) && map_w != 8'h23;
                hdr_w0 <= {hf[win_q][0], hf[win_q][1], hf[win_q][2], hf[win_q][3]};
                hdr_w1 <= {hf[win_q][4], hf[win_q][5], hf[win_q][10], hf[win_q][9]};
                hdr_compl <= {hf[win_q][8], hf[win_q][7]};
                rom_type <= {sa1_w ? 4'h6 : 4'h0, 2'b00, win_q};
                rom_mask <= pmask_q;
                ram_mask <= ssz_w == 8'd0 ? 24'd0 : ssz_w > 8'd7 ? 24'h01FFFF : (24'd1024 << ssz_w[2:0]) - 24'd1;
                vk <= 24'd0; vn <= 24'd0; vcrc <= 32'hFFFFFFFF;
                state <= S_VERIFY;
            end
            S_VERIFY: begin
                if (!aux_req && vk < vlim && vk == vn && sd_ready) begin
                    aux_req <= 1'b1; aux_addr <= vk[22:0];
                end
                if (aux_ack) begin aux_req <= 1'b0; vk <= vk + 24'd1; end
                if (aux_valid) begin
                    vcrc <= crc8(vcrc, aux_q);
                    vn <= vn + 24'd1;
                    // synthesis translate_off
                    if (vn < 24'd6) $display("rom_loader: read back %06h = %02h", vn, aux_q);
                    // synthesis translate_on
                end
                if (vn == vlim && vk == vlim) begin
                    crc_sd <= ~vcrc;
                    ok_info <= info_ok && ~vcrc == info_crc && info_size == rom_size;
                    ok_fly <= ~vcrc == crc_rom;
                    t_show <= ms;
                    state <= (info_ok ? ~vcrc == info_crc && info_size == rom_size : ~vcrc == crc_rom) ? S_SHOW : S_FAIL;
                    ram_keep <= last_game != 32'd0 && last_game == ~vcrc;
                    aclr <= 17'd0;
                    aram_clr_done <= 1'b0;
                end
            end
            S_SHOW: begin
                // ARAM to zero (as the block RAM it replaces powered up), through the write FIFO
                if (!aram_clr_done && !f_full && !push) begin
                    push <= 1'b1;
                    push_d <= {ARAM_BASE + {6'd0, aclr}, 8'h00};
                    aclr <= aclr + 17'd1;
                    if (aclr == 17'hFFFF) aram_clr_done <= 1'b1;
                end
                if (ms - t_show >= SHOW_MS && aram_clr_done && f_empty && !wr_req) begin
                    rom_en <= 1'b1;
                    t_boot <= ms;
                    last_game <= crc_sd;
                    state <= S_RUN;
                end
            end
            S_FAIL: if (force_boot) begin
                if (!aram_clr_done && !f_full && !push) begin
                    push <= 1'b1;
                    push_d <= {ARAM_BASE + {6'd0, aclr}, 8'h00};
                    aclr <= aclr + 17'd1;
                    if (aclr == 17'hFFFF) aram_clr_done <= 1'b1;
                end
                if (aram_clr_done && f_empty && !wr_req) begin
                    rom_en <= 1'b1;
                    t_boot <= ms;
                    last_game <= crc_sd;
                    state <= S_RUN;
                end
            end
            default: ;
        endcase
    end
endmodule
