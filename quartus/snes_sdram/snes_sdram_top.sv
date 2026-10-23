// SPDX-License-Identifier: GPL-3.0-or-later
// Super Nt top level: SNES + SA-1 core with the cartridge ROM in the x8 SDRAM pair
// (notes/snes-sdram.md). Same as quartus/snes/snes_top.sv (video, audio, controller port 1, same
// parameters) plus:
//   - snes_sdram_pll: clk_sys 21.44196 MHz and clk_mem 85.76784 MHz (4 x) from one VCO;
//   - quartus/common/sdram_rom.sv on clk_mem serving the core's ROM port;
//   - a boot copier: the built-in test ROM (8 KB of block RAM, ROM_HEX) is written into SDRAM
//     words 0 .. ROM_WORDS-1 (mirrored every 8 KB, i.e. the 32 KB .sfc image), then ROM reads
//     are enabled and the SNES reset is released, so the core runs from SDRAM.
// Loading through the PIC32 link (quartus/common/link_loader.sv) is not wired in yet.
//
// Pins: board clock W16, the HDMI transmitter's video and audio pins and controller port 1 as in
// quartus/snes/pins.tcl, the x8 SDRAM pair as in quartus/hwtest/pins.tcl (notes/sdram.md):
// commands/address/DQ, clock AB11 (DDIO), AB10 driven to AB10_LEVEL (built with 1 = v1's "CKE";
// spc.cor drives it low, notes/sdram.md "Constant pins"), DQM candidates held low (open drain,
// DQM_LOW = 1) or released. Every other pin is left unused. hwtest v1 saw no SDRAM response
// with AB10 high: set AB10_LEVEL/DQM_LOW from hwtest v2's clean hypothesis before using this.
module top #(
    parameter ROM_HEX    = "../../build/snes/sa1test.hex",
    parameter BOOT_AW    = 12,       // boot ROM: 2^BOOT_AW 16-bit words (8 KB)
    parameter ROM_WORDS  = 16384,    // words copied into SDRAM (32 KB, the .sfc size)
    parameter [23:0] ROM_MASK = 24'h007FFF,  // header ROM size $05 = 32 KB
    // SDRAM read-capture point (sdram_rom.sv; hwtest terms: rise n = 2n, fall n.5 = 2n+1).
    // Quartus builds take it from sdram_cfg.tcl (snes_sdram.qsf), so keep the two the same.
    parameter CAPTURE_HALF = 7,
    // PLL phases (strings, relative to clk_sys) of the SDRAM controller clock, the SDRAM clock
    // source and the read-capture clock (sdram_cfg.tcl; snes_sdram_pll.v). All "0 ps" = hwtest's
    // arrangement.
    parameter MEM_PHASE  = "1250 ps",
    parameter SD_PHASE   = "10618 ps",
    parameter CAP_PHASE  = "625 ps",
    parameter DQM_LOW    = 1,        // 1: drive the DQM candidate pins low, 0: release them
    // Colour channel mapping: which colour goes to the pin groups ch1/ch2/ch3. pins.tcl already
    // assigns ch1/ch2/ch3 = R/G/B as confirmed on the console (vtest, 21 Oct 2026), so 0.
    // 0: R,G,B  1: R,B,G  2: G,R,B  3: G,B,R  4: B,R,G  5: B,G,R.
    parameter CH_ORDER   = 0,
    // HS/VS/DE roles of P16/M16/M18 (table in snes_video.sv). 3 = {VS, DE, HS}, confirmed on the
    // console with vtest. -1 cycles through all 6 every 8 s (white boxes top left = order + 1).
    parameter SYNC_ORDER = 3,
    parameter OUT_W      = 768,     // picture width on the 1280-pixel line (896 = 4:3)
    parameter LOCK       = 1,       // align output frames to the SNES (snes_video.sv)
    parameter [15:0] RESET_CYCLES = 16'hffff, // core reset after the boot copy (clk_sys cycles)
    // Serial audio framing the AD9889B expects (notes/audio.md): 0 = I2S, 1 = left-justified.
    // I2S confirmed on the console (hwtest v3, 22 Oct 2026); the PIC enables the HDMI audio
    // only once its 0x2004 status poll has passed (notes/pic-link.md).
    parameter AUD_FRAMING = 0,
    // Controller port wiring (notes/controllers.md, numbering as quartus/common/pad_test.sv):
    // bit 1 = swap roles (latch on J13/K16, clock on P14), bit 0 = invert both outputs.
    // 0 confirmed on the console (hwtest, 22 Oct 2026: FFFF0000 idle, B/Start/A read right).
    parameter [1:0] PAD_CFG = 2'd0,
    // AB10 level (notes/sdram.md "Constant pins"): from hwtest v2 (hypotheses 0/1 = low).
    parameter AB10_LEVEL = 1
) (
    input  wire       clk,      // W16, 74.25 MHz
    output wire       pclk,     // M22, pixel clock to the AD9889B
    output wire       s0,       // P16 VSYNC \
    output wire       s1,       // M16 DE     } with SYNC_ORDER 3
    output wire       s2,       // M18 HSYNC /
    output reg  [7:0] ch1,      // red:   K21 K22 M20 L22 T17 T18 R15 T22 (bit 7..0)
    output reg  [7:0] ch2,      // green: N20 P22 R22 R21 P19 P18 N16 N19
    output reg  [7:0] ch3,      // blue:  T20 T15 T19 R16 M21 N21 P17 R17
    // serial audio to the AD9889B (notes/audio.md)
    output wire       aud_mclk, // L17, 12.288 MHz
    output wire       aud_bclk, // L19, 3.072 MHz
    output wire       aud_lrclk,// K17, 48 kHz
    output wire       aud_sdata,// L18
    // controller port 1 (notes/controllers.md)
    output reg        pad_p14 = 1'b0,  // likely LATCH
    output reg        pad_j13 = 1'b0,  // } likely CLOCK (ports 1 and 2, same signal as spc.cor)
    output reg        pad_k16 = 1'b0,  // }
    input  wire       pad_t12,         // port 1 data
    // x8 SDRAM pair (notes/sdram.md, quartus/hwtest/pins.tcl)
    output wire        sd_clk,   // AB11 (DDIO, inverted clk_mem)
    output wire        sd_cs_n,  // AB17
    output wire        sd_ras_n, // AA17
    output wire        sd_cas_n, // AB18
    output wire        sd_we_n,  // AA18
    output wire [11:0] sd_a,     // A0-A9 AB13 AA13 AB12 AA12 U2 U1 W2 AA2 AA1 N1, A10 AA14, A11 N2
    output wire [1:0]  sd_ba,    // AA15 AB15 (order unknown)
    inout  wire [15:0] sd_dq,    // 7:0 chip A (2A), 15:8 chip B (3B)
    output wire        sd_cke,   // AB10, CKE candidate
    inout  wire [7:0]  sd_dqm    // Y3 W9 W8 Y9 Y10 R11 R10 Y11, DQM candidates (0 or Z)
);
    // ---------------------------------------------------------------- clocks and reset
    wire clk_vid = clk;         // 720p pixel clock straight from the 74.25 MHz board clock
    wire clk_sys;               // 21.44196 MHz SNES master clock (60.000 Hz frames)
    wire clk_mem;               // 85.76784 MHz SDRAM controller clock, 4 x clk_sys, MEM_PHASE late
    wire clk_sd;                // SD_PHASE copy, drives the SDRAM clock DDIO
    wire clk_cap;               // CAP_PHASE copy, clocks the read-capture register
    wire pll_locked;
    snes_sdram_pll #(.MEM_PHASE(MEM_PHASE), .SD_PHASE(SD_PHASE), .CAP_PHASE(CAP_PHASE)) pll (
        .refclk(clk), .rst(1'b0), .outclk_0(clk_sys), .outclk_1(clk_mem), .outclk_2(clk_sd),
        .outclk_3(clk_cap), .locked(pll_locked));

    // clk_mem side: SDRAM controller reset until the PLL is locked, then the boot copy.
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg [1:0]  lock_mem = 2'b00;
    always @(posedge clk_mem) lock_mem <= {lock_mem[0], pll_locked};
    wire       mem_reset = ~lock_mem[1];

    // ---------------------------------------------------------------- SDRAM
    wire [23:0] rom_addr;
    wire        rom_word, rom_oe_n, sysclkf_ce;
    wire [15:0] rom_q;
    wire        sd_ready, wr_ack;
    reg         wr_req = 1'b0;
    reg  [23:0] wr_addr = 24'd0;
    reg  [15:0] wr_data = 16'd0;
    reg         loaded = 1'b0;      // boot copy done: ROM reads on (clk_mem)
    reg         sys_tog = 1'b0;     // clk_sys phase for the controller
    wire [15:0] sd_dq_out;
    wire        sd_dq_oe;
    wire [15:0] sd_forced /* verilator public_flat_rd */, sd_stall /* verilator public_flat_rd */;
    wire [15:0] sd_late /* verilator public_flat_rd */;
    wire [10:0] sd_rfmax /* verilator public_flat_rd */;
    always @(posedge clk_sys) sys_tog <= ~sys_tog;
    assign sd_dq  = sd_dq_oe ? sd_dq_out : 16'hzzzz;
    assign sd_cke = AB10_LEVEL;
    assign sd_dqm = DQM_LOW ? 8'h00 : 8'hzz;
    // Hidden refresh/write slots (sdram_rom.sv): with the SA-1 mapper, ROM addresses change only
    // at the clk_sys edge after a cycle with ROM_OE_N (= SA-1 CLK_CE) high or with SYSCLKF_CE
    // high (the SNES's ROM window ends, SA1.vhd); in any other cycle nothing latency-critical
    // starts at the next edge.
    sdram_rom #(.CAPTURE_HALF(CAPTURE_HALF)) sdram (
        .clk(clk_mem), .clk_sd(clk_sd), .clk_cap(clk_cap), .reset(mem_reset), .ready(sd_ready),
        .sys_tog(sys_tog),
        .rom_en(loaded), .rom_addr(rom_addr), .rom_word(rom_word), .rom_q(rom_q),
        .rfsh_ok(~rom_oe_n & ~sysclkf_ce),
        .wr_req(wr_req), .wr_addr(wr_addr), .wr_data(wr_data), .wr_ack(wr_ack),
        .aux_req(1'b0), .aux_addr(24'd0), .aux_ack(), .aux_valid(), .aux_q(),
        .sd_clk(sd_clk), .sd_cs_n(sd_cs_n), .sd_ras_n(sd_ras_n), .sd_cas_n(sd_cas_n),
        .sd_we_n(sd_we_n), .sd_a(sd_a), .sd_ba(sd_ba), .sd_dq_in(sd_dq), .sd_dq_out(sd_dq_out),
        .sd_dq_oe(sd_dq_oe),
        .n_rf_forced(sd_forced), .n_rf_stall(sd_stall), .n_late(sd_late), .rf_max(sd_rfmax)
    );

    // Boot copy (clk_mem): SDRAM word i <- boot_rom[i mod 2^BOOT_AW], i = 0 .. boot_len-1.
    // boot_len is a register so the simulation can skip the copy (ROM image preloaded).
    (* ramstyle = "M10K" *) reg [15:0] boot_rom [0:(1 << BOOT_AW) - 1] /* verilator public_flat_rw */;
    initial $readmemh(ROM_HEX, boot_rom);
    reg [16:0] boot_len /* verilator public_flat_rw */ = ROM_WORDS;
    reg [16:0] bi = 17'd0;
    reg [15:0] bd = 16'd0;
    reg [1:0]  bst = 2'd0;
    always @(posedge clk_mem) begin
        bd <= boot_rom[bi[BOOT_AW-1:0]];
        if (mem_reset || !sd_ready) begin
            bi <= 17'd0; bst <= 2'd0; wr_req <= 1'b0; loaded <= 1'b0;
        end else if (!loaded) case (bst)
            2'd0: if (bi == boot_len) loaded <= 1'b1; else bst <= 2'd1;   // boot_rom read
            2'd1: begin                                                   // bd valid
                wr_req <= 1'b1; wr_addr <= {7'd0, bi}; wr_data <= bd; bst <= 2'd2;
            end
            default: if (wr_ack) begin
                wr_req <= 1'b0; bi <= bi + 17'd1; bst <= 2'd0;
            end
        endcase
    end

    // clk_sys side: hold the core in reset until the copy is done, then ~3 ms more.
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg [1:0]  lock_sync = 2'b00;
    reg [15:0] rst_cnt = 16'd0;
    reg        core_reset = 1'b1;
    always @(posedge clk_sys) begin
        lock_sync <= {lock_sync[0], loaded};
        if (!lock_sync[1]) begin
            rst_cnt    <= 16'd0;
            core_reset <= 1'b1;
        end else if (rst_cnt != RESET_CYCLES)
            rst_cnt <= rst_cnt + 16'd1;
        else
            core_reset <= 1'b0;
    end
    reg [23:0] rom_mask /* verilator public_flat_rw */ = ROM_MASK;   // constant in hardware
    reg [7:0]  rom_type /* verilator public_flat_rw */ = 8'h60;      // SA-1 (the sim may change it)

    // ---------------------------------------------------------------- SNES
    wire [7:0] r, g, b;
    wire       dotclk, hde, vde, high_res, v224;
    wire [15:0] audio_l /* verilator public_flat_rd */, audio_r;
    wire        joy_strb, joy_clk, joy_d0;
    snes_sdram_core snes (
        .clk_sys(clk_sys), .reset(core_reset), .rom_type(rom_type), .rom_mask(rom_mask),
        .ram_mask(24'h0007FF),
        .rom_addr(rom_addr), .rom_word(rom_word), .rom_q(rom_q), .rom_oe_n(rom_oe_n),
        .sysclkf_ce(sysclkf_ce), .sysclkr_ce(),
        .r(r), .g(g), .b(b), .dotclk(dotclk), .hde(hde), .vde(vde), .high_res(high_res),
        .v224(v224), .audio_l(audio_l), .audio_r(audio_r),
        .joy_strb(joy_strb), .joy_clk(joy_clk), .joy1_clk(), .joy2_clk(), .joy1_d0(joy_d0),
        .joy2_d0(1'b1), .ext_aram_addr(), .ext_aram_d(), .ext_aram_rd(), .ext_aram_wr(), .ext_aram_q(8'h00),
        .bsram_clr(1'b0), .bsram_clr_done()
    );

    // ---------------------------------------------------------------- controller port 1
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg [1:0] t12_s = 2'b11;
    assign joy_d0 = t12_s[1];
    wire latch_ln = joy_strb, clock_ln = ~joy_clk;      // real line levels: clock idles high
    always @(posedge clk_sys) begin
        t12_s   <= {t12_s[0], pad_t12};
        pad_p14 <= (PAD_CFG[1] ? clock_ln : latch_ln) ^ PAD_CFG[0];
        pad_j13 <= (PAD_CFG[1] ? latch_ln : clock_ln) ^ PAD_CFG[0];
        pad_k16 <= (PAD_CFG[1] ? latch_ln : clock_ln) ^ PAD_CFG[0];
    end

    // ---------------------------------------------------------------- video
    wire [7:0] vr, vg, vb;
    wire       vs0, vs1, vs2;
    snes_video #(.OUT_W(OUT_W), .LOCK(LOCK), .SYNC_ORDER(SYNC_ORDER)) video (
        .clk_sys(clk_sys), .r(r), .g(g), .b(b), .dotclk(dotclk), .hde(hde), .vde(vde),
        .high_res(high_res), .v224(v224),
        .clk_vid(clk_vid), .vr(vr), .vg(vg), .vb(vb), .s0(vs0), .s1(vs1), .s2(vs2), .perm(),
        .cx(), .cy()
    );

    // Output registers (packed into the I/O cells, FAST_OUTPUT_REGISTER in snes.qsf).
    reg so0 = 1'b0, so1 = 1'b0, so2 = 1'b0;
    always @(posedge clk_vid) begin
        {so0, so1, so2} <= {vs0, vs1, vs2};
        case (CH_ORDER)
            1:       {ch1, ch2, ch3} <= {vr, vb, vg};
            2:       {ch1, ch2, ch3} <= {vg, vr, vb};
            3:       {ch1, ch2, ch3} <= {vg, vb, vr};
            4:       {ch1, ch2, ch3} <= {vb, vr, vg};
            5:       {ch1, ch2, ch3} <= {vb, vg, vr};
            default: {ch1, ch2, ch3} <= {vr, vg, vb};
        endcase
    end
    assign {s0, s1, s2} = {so0, so1, so2};

    // Pixel clock: a DDIO output register driving 0 in the high half and 1 in the low half of
    // clk_vid, i.e. the inverted clock with the same output path as the data. The AD9889B
    // samples on its rising edge, half a period (6.7 ns) after the data changed.
    altddio_out #(
        .extend_oe_disable("OFF"), .intended_device_family("Cyclone V"),
        .invert_output("OFF"), .lpm_hint("UNUSED"), .lpm_type("altddio_out"),
        .oe_reg("UNREGISTERED"), .power_up_high("OFF"), .width(1)
    ) pclk_ddio (
        .datain_h(1'b0), .datain_l(1'b1), .outclock(clk_vid), .dataout(pclk),
        .aclr(1'b0), .aset(1'b0), .oe(1'b1), .oe_out(), .outclocken(1'b1), .sclr(1'b0), .sset(1'b0)
    );

    // ---------------------------------------------------------------- audio
    // DSP output (32 kHz, clk_sys domain) -> 48 kHz serial audio, sample-and-hold.
    wire mclk;
    audio_pll apll (.refclk(clk), .outclk_0(mclk), .locked());
    i2s_out #(.FRAMING(AUD_FRAMING)) aout (
        .clk_src(clk_sys), .l(audio_l), .r(audio_r),
        .mclk(mclk), .mclk_pin(aud_mclk), .bclk(aud_bclk), .lrclk(aud_lrclk), .sdata(aud_sdata));
endmodule
