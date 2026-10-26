// SPDX-License-Identifier: GPL-3.0-or-later
// SNES + SA-1 for the Super Nt with the cartridge ROM outside (quartus/snes_sdram, ROM in
// SDRAM; notes/snes-sdram.md). Copy of quartus/snes/snes_core.sv with the ROM port brought out
// (rom_addr/rom_word/rom_q as main.v's ROM_ADDR/ROM_WORD/ROM_Q, plus ROM_OE_N and SYSCLKF_CE for
// the SDRAM controller's refresh slots) and ROM_MASK as an input.
//
// Wraps `main` (srg320's MiSTer SNES core via agg23's openfpga-SNES, GPL-3.0,
// ~/src/vendor/openfpga-SNES/rtl/upstream/main.v) the way rtl/mister_top/SNES.sv (MAIN_SNES)
// does on the Pocket, minus everything this board doesn't have yet:
// - WRAM 128 KB, VRAM 2 x 32 KB, ARAM 64 KB (or, ARAM_EXT = 1, outside through the ext_aram
//   ports) and BW-RAM (BSRAM) are M10K; the cartridge ROM is
//   served through the rom_* ports (SDRAM, quartus/common/sdram_rom.sv). BW-RAM has a second
//   port on its own clock (bs_*: quartus/snes_load's save loading and on-screen dump).
// - No header parsing here: rom_type, rom_mask and ram_mask are inputs (what the Pocket's
//   rom_parser.sv / MiSTer derive from the header: SA-1 = ROM_TYPE 8'h60, LoROM 00, HiROM 01,
//   masks = (1024 << size) - 1); quartus/snes_load derives them at run time
//   (rom_loader.sv), quartus/snes_sdram passes constants. They must only change while the core
//   is in reset (the SDC treats them as static).
// - Controller port 1 only (serial lines out, see snes_sdram_top.sv); no cheats, save states,
//   MSU.
// The RAMs are plain inferred Verilog (Quartus maps them to M10K; Verilator simulates the same
// code). Reads have one clk_sys cycle of latency like the altsyncram wrappers in bram.vhd.
module snes_sdram_core #(
    parameter        BSRAM_AW = 11,          // BW-RAM bytes = 2^BSRAM_AW
    parameter        ARAM_EXT = 0,           // 1: ARAM outside (aram_* ports, quartus/snes_load v2)
    parameter        USE_GSU  = 0,           // 1: Super FX (GSU) too (quartus/snes_load v7)
    parameter        USE_SA1  = 1            // 0: no SA-1 (quartus/snes_gsu: the Super FX alone)
) (
    input  wire        clk_sys,      // SNES master clock, 21.442 MHz (MCLK = ACLK)
    input  wire        reset,        // synchronous to clk_sys, active high
    input  wire [7:0]  rom_type,     // [7:4] = 6: SA-1, 7: GSU; [3:0] = 0 LoROM, 1 HiROM, 2 ExHiROM
    input  wire [23:0] rom_mask,     // (1024 << header ROM size) - 1; $7FFF = 32 KB
    input  wire [23:0] ram_mask,     // (1024 << header RAM size) - 1, 0 = none

    // cartridge ROM (main.v ROM_*): byte address, word/byte read, data; ROM_OE_N is the
    // SA-1's CLK_CE for SA-1 carts (SA1.vhd ROM_RD_N), SYSCLKF_CE the SNES bus cycle end
    output wire [23:0] rom_addr,
    output wire        rom_word,
    input  wire [15:0] rom_q,
    output wire        rom_oe_n,
    output wire        sysclkf_ce,
    output wire        sysclkr_ce,

    output wire [7:0]  r, g, b,
    output wire        dotclk,       // PPU dot clock phase: 1 = sub/left half, 0 = main/right
    output wire        hde,          // horizontal display enable (256 dots)
    output wire        vde,          // vertical display enable (224/239 lines)
    output wire        high_res,     // 512-pixel line (true or pseudo hi-res)
    output wire        v224,         // 224-line mode (overscan off)
    output wire [15:0] audio_l, audio_r,
    // controller port lines, core polarity: strobe = latch (active high), clk = 1 while a
    // clock pulse is in progress (the real line is low then), d0 = port 1 data as on the pin;
    // joy_clk = either port's clock, joy1_clk/joy2_clk per port, joy2_d0 = port 2 data (1 =
    // nothing pressed, no pad)
    output wire        joy_strb,
    output wire        joy_clk,
    output wire        joy1_clk,
    output wire        joy2_clk,
    input  wire        joy1_d0,
    input  wire        joy2_d0,
    // ARAM outside (ARAM_EXT = 1): the S-DSP/SPC700's 64 KB as an SDRAM port (sdram_rom8.sv):
    // address, write data, read this cycle, write at the next edge; the byte read comes back on
    // ext_aram_q at least 13 clk_mem (2.6 clk_sys) later and the DSP takes it >= 5 clk_sys after
    // the address change
    output wire [15:0] ext_aram_addr,
    output wire [7:0]  ext_aram_d,
    output wire        ext_aram_rd,
    output wire        ext_aram_wr,
    input  wire [7:0]  ext_aram_q,
    // BW-RAM/SRAM second port (quartus/snes_load v8: the save from the file is written here while
    // the core is held in reset, and the on-screen dump reads it), on clock bs_clk, one cycle of
    // read latency; tie bs_we low when unused
    input  wire                bs_clk,
    input  wire [BSRAM_AW-1:0] bs_addr,
    input  wire [7:0]          bs_d,
    input  wire                bs_we,
    output wire [7:0]          bs_q
);
    // Reset as in MAIN_SNES: released on a fixed phase of a 4-cycle divider.
    reg       reset_n = 1'b0;
    reg [1:0] div = 2'd0;
    always @(posedge clk_sys) begin
        div <= div + 2'd1;
        if (div == 2'd2) reset_n <= ~reset;
    end

    wire [19:0] bsram_addr;
    wire [7:0]  bsram_d, bsram_q;
    wire        bsram_ce_n, bsram_oe_n, bsram_we_n;
    wire [16:0] wram_addr;
    wire [7:0]  wram_d, wram_q;
    wire        wram_ce_n, wram_oe_n, wram_we_n;
    wire [15:0] vram1_addr, vram2_addr;
    wire [7:0]  vram1_d, vram1_q, vram2_d, vram2_q;
    wire        vram1_we_n, vram2_we_n;
    wire [15:0] aram_addr;
    wire [7:0]  aram_d, aram_q;
    wire        aram_ce_n, aram_oe_n, aram_we_n;

    assign joy_clk = joy1_clk | joy2_clk;

    main #(
        .USE_CX4(1'b0), .USE_SDD1(1'b0), .USE_GSU(USE_GSU[0]), .USE_SA1(USE_SA1[0]), .USE_DSPn(1'b0),
        .USE_SPC7110(1'b0), .USE_BSX(1'b0), .USE_MSU(1'b0), .USE_SS(1'b0), .USE_SUFAMI(1'b0)
    ) main (
        .RESET_N(reset_n),
        .MCLK(clk_sys), .ACLK(clk_sys),

        .ROM_TYPE(rom_type), .ROM_MASK(rom_mask), .RAM_MASK(ram_mask), .RAM_SIZE(4'd0),

        .SYSCLKR_CE(sysclkr_ce), .SYSCLKF_CE(sysclkf_ce), .REFRESH(),

        .ROM_ADDR(rom_addr), .ROM_D(), .ROM_Q(rom_q), .ROM_CE_N(), .ROM_OE_N(rom_oe_n),
        .ROM_WE_N(), .ROM_WORD(rom_word),

        .BSRAM_ADDR(bsram_addr), .BSRAM_D(bsram_d), .BSRAM_Q(bsram_q), .BSRAM_CE_N(bsram_ce_n),
        .BSRAM_OE_N(bsram_oe_n), .BSRAM_WE_N(bsram_we_n),

        .WRAM_ADDR(wram_addr), .WRAM_D(wram_d), .WRAM_Q(wram_q), .WRAM_CE_N(wram_ce_n),
        .WRAM_OE_N(wram_oe_n), .WRAM_WE_N(wram_we_n),

        .VRAM1_ADDR(vram1_addr), .VRAM1_DI(vram1_q), .VRAM1_DO(vram1_d), .VRAM1_WE_N(vram1_we_n),
        .VRAM2_ADDR(vram2_addr), .VRAM2_DI(vram2_q), .VRAM2_DO(vram2_d), .VRAM2_WE_N(vram2_we_n),
        .VRAM_OE_N(),

        .ARAM_ADDR(aram_addr), .ARAM_D(aram_d), .ARAM_Q(aram_q), .ARAM_CE_N(aram_ce_n),
        .ARAM_OE_N(aram_oe_n), .ARAM_WE_N(aram_we_n),

        .GSU_ACTIVE(), .GSU_TURBO(1'b0), .GSU_FASTROM(1'b0), .SUFAMI_SWAP(1'b0), .CC_DIP(8'd0),

        .BLEND(1'b0), .PAL(1'b0),
        .HIGH_RES(high_res), .V224_MODE(v224), .FIELD(), .INTERLACE(), .DOTCLK(dotclk),
        .R(r), .G(g), .B(b),
        .HBLANKn(hde), .VBLANKn(vde), .HSYNC(), .VSYNC(), .HVCNT_ATZERO(),

        // D0 of both ports from the pads, the D1 lines idle high.
        .JOY1_DI({1'b1, joy1_d0}), .JOY2_DI({1'b1, joy2_d0}), .JOY_STRB(joy_strb), .JOY1_CLK(joy1_clk),
        .JOY2_CLK(joy2_clk),
        .JOY1_P6(), .JOY2_P6(), .JOY2_P6_in(1'b1), .SNI_JOY(),

        .EXT_RTC(65'd0),
        .GG_EN(1'b0), .GG_CODE(129'd0), .GG_RESET(1'b0), .GG_AVAILABLE(),
        .SPC_MODE(1'b0), .IO_ADDR(17'd0), .IO_DAT(16'd0), .IO_WR(1'b0),
        .DBG_BG_EN(5'b11111), .DBG_CPU_EN(1'b1),
        .TURBO(1'b0), .TURBO_ALLOW(), .DSP_FREQ(1'b0),

        .MSU_TRACK_NUM(), .MSU_TRACK_REQUEST(), .MSU_TRACK_MOUNTING(1'b0),
        .MSU_TRACK_MISSING(1'b0), .MSU_VOLUME(), .MSU_AUDIO_STOP(1'b0), .MSU_AUDIO_REPEAT(),
        .MSU_AUDIO_RESUME(), .MSU_AUDIO_PLAYING(), .MSU_AUDIO_SECTOR(22'd0),
        .MSU_RESUME_SECTOR(), .MSU_AUDIO_LOOP_INDEX(32'd0), .MSU_RESUME_LOOP_INDEX(),
        .MSU_DATA_ADDR(), .MSU_DATA(8'd0), .MSU_DATA_ACK(1'b0), .MSU_DATA_SEEK(),
        .MSU_DATA_REQ(), .MSU_ENABLE(1'b0),

        .SS_SAVE(1'b0), .SS_TOSD(1'b0), .SS_LOAD(1'b0), .SS_SLOT(2'd0), .SS_AVAIL(),
        .SS_DDR_DI(64'd0), .SS_DDR_ACK(1'b0), .SS_DDR_DO(), .SS_DDR_ADDR(), .SS_DDR_WE(),
        .SS_DDR_BE(), .SS_DDR_REQ(),

        .AUDIO_L(audio_l), .AUDIO_R(audio_r)
    );

    snes_sdram_spram #(.AW(17)) wram (
        .clk(clk_sys), .addr(wram_addr), .d(wram_d), .we(~wram_ce_n & ~wram_we_n), .q(wram_q));
    snes_sdram_spram #(.AW(15)) vram1 (
        .clk(clk_sys), .addr(vram1_addr[14:0]), .d(vram1_d), .we(~vram1_we_n), .q(vram1_q));
    snes_sdram_spram #(.AW(15)) vram2 (
        .clk(clk_sys), .addr(vram2_addr[14:0]), .d(vram2_d), .we(~vram2_we_n), .q(vram2_q));
    assign ext_aram_addr = aram_addr;
    assign ext_aram_d    = aram_d;
    assign ext_aram_rd   = ~aram_ce_n & ~aram_oe_n;
    assign ext_aram_wr   = ~aram_ce_n & ~aram_we_n;
    generate if (ARAM_EXT) begin : g_aram_ext
        assign aram_q = ext_aram_q;
    end else begin : g_aram
        snes_sdram_spram #(.AW(16)) aram (
            .clk(clk_sys), .addr(aram_addr), .d(aram_d), .we(~aram_ce_n & ~aram_we_n), .q(aram_q));
    end endgenerate
    snes_sdram_tdpram #(.AW(BSRAM_AW)) bsram (
        .clk_a(clk_sys), .addr_a(bsram_addr[BSRAM_AW-1:0]), .d_a(bsram_d),
        .we_a(~bsram_ce_n & ~bsram_we_n), .q_a(bsram_q),
        .clk_b(bs_clk), .addr_b(bs_addr), .d_b(bs_d), .we_b(bs_we), .q_b(bs_q));
endmodule

// Single-port RAM, registered address, new data on read-during-write (as bram.vhd's spram).
// Powers up as zero.
module snes_sdram_spram #(parameter AW = 8, parameter DW = 8) (
    input  wire          clk,
    input  wire [AW-1:0] addr,
    input  wire [DW-1:0] d,
    input  wire          we,
    output reg  [DW-1:0] q
);
    (* ramstyle = "M10K" *) reg [DW-1:0] mem [0:(1 << AW) - 1] /* verilator public_flat_rd */;
    always @(posedge clk)
        if (we) begin
            mem[addr] <= d;
            q <= d;
        end else
            q <= mem[addr];
endmodule

// True dual-port RAM, one clock per port (Intel's template: M10K), new data on a same-port
// read-during-write; a read of a byte the other port writes in the same cycle is undefined.
// Powers up as zero.
module snes_sdram_tdpram #(parameter AW = 8, parameter DW = 8) (
    input  wire          clk_a,
    input  wire [AW-1:0] addr_a,
    input  wire [DW-1:0] d_a,
    input  wire          we_a,
    output reg  [DW-1:0] q_a,
    input  wire          clk_b,
    input  wire [AW-1:0] addr_b,
    input  wire [DW-1:0] d_b,
    input  wire          we_b,
    output reg  [DW-1:0] q_b
);
    (* ramstyle = "M10K" *) reg [DW-1:0] mem [0:(1 << AW) - 1] /* verilator public_flat_rw */;
    always @(posedge clk_a)
        if (we_a) begin
            mem[addr_a] <= d_a;
            q_a <= d_a;
        end else
            q_a <= mem[addr_a];
    always @(posedge clk_b)
        if (we_b) begin
            mem[addr_b] <= d_b;
            q_b <= d_b;
        end else
            q_b <= mem[addr_b];
endmodule
