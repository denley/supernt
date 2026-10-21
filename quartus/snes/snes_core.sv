// SPDX-License-Identifier: GPL-3.0-or-later
// SNES + SA-1 for the Super Nt, all memory in block RAM (notes/snes-quartus.md).
//
// Wraps `main` (srg320's MiSTer SNES core via agg23's openfpga-SNES, GPL-3.0,
// ~/src/vendor/openfpga-SNES/rtl/upstream/main.v) the way rtl/mister_top/SNES.sv (MAIN_SNES)
// does on the Pocket, minus everything this board doesn't have yet:
// - No SDRAM/PSRAM: WRAM 128 KB, VRAM 2 x 32 KB, ARAM 64 KB, BW-RAM (BSRAM) and the cartridge
//   ROM are M10K. The ROM is initialised from a $readmemh file (16-bit little-endian words) and
//   mirrored over the whole ROM address space.
// - No ROM loading or header parsing: ROM_TYPE/ROM_MASK/RAM_MASK are parameters (what the
//   Pocket's rom_parser.sv / MiSTer derive from the header: SA-1 = ROM_TYPE 8'h60, masks =
//   (1024 << size) - 1).
// - Controller port 1 only (serial lines out, see snes_top.sv); no cheats, save states, MSU.
// The RAMs are plain inferred Verilog (Quartus maps them to M10K; Verilator simulates the same
// code). Reads have one clk_sys cycle of latency like the altsyncram wrappers in bram.vhd.
module snes_core #(
    parameter        ROM_HEX  = "sa1test.hex",
    parameter        ROM_AW   = 12,          // ROM words = 2^ROM_AW (16-bit) -> 8 KB
    parameter [7:0]  ROM_TYPE = 8'h60,       // [7:4] = 6: SA-1, [3:0] = 0: LoROM area
    parameter [23:0] ROM_MASK = 24'h007FFF,  // header ROM size $05 = 32 KB
    parameter [23:0] RAM_MASK = 24'h0007FF,  // header RAM size $01 = 2 KB
    parameter        BSRAM_AW = 11           // BW-RAM bytes = 2^BSRAM_AW
) (
    input  wire        clk_sys,      // SNES master clock, 21.442 MHz (MCLK = ACLK)
    input  wire        reset,        // synchronous to clk_sys, active high

    output wire [7:0]  r, g, b,
    output wire        dotclk,       // PPU dot clock phase: 1 = sub/left half, 0 = main/right
    output wire        hde,          // horizontal display enable (256 dots)
    output wire        vde,          // vertical display enable (224/239 lines)
    output wire        high_res,     // 512-pixel line (true or pseudo hi-res)
    output wire        v224,         // 224-line mode (overscan off)
    output wire [15:0] audio_l, audio_r,
    // controller port lines, core polarity: strobe = latch (active high), clk = 1 while a
    // clock pulse is in progress (the real line is low then), d0 = port 1 data as on the pin
    output wire        joy_strb,
    output wire        joy_clk,
    input  wire        joy1_d0
);
    // Reset as in MAIN_SNES: released on a fixed phase of a 4-cycle divider.
    reg       reset_n = 1'b0;
    reg [1:0] div = 2'd0;
    always @(posedge clk_sys) begin
        div <= div + 2'd1;
        if (div == 2'd2) reset_n <= ~reset;
    end

    wire [23:0] rom_addr;
    wire [15:0] rom_q;
    wire        rom_oe_n, rom_word;
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

    wire joy1_clk, joy2_clk;
    assign joy_clk = joy1_clk | joy2_clk;

    main #(
        .USE_CX4(1'b0), .USE_SDD1(1'b0), .USE_GSU(1'b0), .USE_SA1(1'b1), .USE_DSPn(1'b0),
        .USE_SPC7110(1'b0), .USE_BSX(1'b0), .USE_MSU(1'b0), .USE_SS(1'b0), .USE_SUFAMI(1'b0)
    ) main (
        .RESET_N(reset_n),
        .MCLK(clk_sys), .ACLK(clk_sys),

        .ROM_TYPE(ROM_TYPE), .ROM_MASK(ROM_MASK), .RAM_MASK(RAM_MASK), .RAM_SIZE(4'd0),

        .SYSCLKR_CE(), .SYSCLKF_CE(), .REFRESH(),

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

        // Port 1 D0 from the pad, D1 and port 2 idle high (no buttons pressed).
        .JOY1_DI({1'b1, joy1_d0}), .JOY2_DI(2'b11), .JOY_STRB(joy_strb), .JOY1_CLK(joy1_clk),
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

    // Cartridge ROM: 16-bit words, mirrored (address bits above ROM_AW+1 ignored). Byte reads
    // at odd addresses return the high byte in both halves, like sdram.sv's port 0.
    (* ramstyle = "M10K" *) reg [15:0] rom [0:(1 << ROM_AW) - 1] /* verilator public_flat_rw */;
    initial $readmemh(ROM_HEX, rom);
    reg [15:0] rom_w;
    reg        rom_hi;
    always @(posedge clk_sys) begin
        rom_w  <= rom[rom_addr[ROM_AW:1]];
        rom_hi <= rom_addr[0] & ~rom_word;
    end
    assign rom_q = rom_hi ? {rom_w[15:8], rom_w[15:8]} : rom_w;

    snes_spram #(.AW(17)) wram (
        .clk(clk_sys), .addr(wram_addr), .d(wram_d), .we(~wram_ce_n & ~wram_we_n), .q(wram_q));
    snes_spram #(.AW(15)) vram1 (
        .clk(clk_sys), .addr(vram1_addr[14:0]), .d(vram1_d), .we(~vram1_we_n), .q(vram1_q));
    snes_spram #(.AW(15)) vram2 (
        .clk(clk_sys), .addr(vram2_addr[14:0]), .d(vram2_d), .we(~vram2_we_n), .q(vram2_q));
    snes_spram #(.AW(16)) aram (
        .clk(clk_sys), .addr(aram_addr), .d(aram_d), .we(~aram_ce_n & ~aram_we_n), .q(aram_q));
    snes_spram #(.AW(BSRAM_AW)) bsram (
        .clk(clk_sys), .addr(bsram_addr[BSRAM_AW-1:0]), .d(bsram_d),
        .we(~bsram_ce_n & ~bsram_we_n), .q(bsram_q));
endmodule

// Single-port RAM, registered address, new data on read-during-write (as bram.vhd's spram).
// Powers up as zero.
module snes_spram #(parameter AW = 8, parameter DW = 8) (
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
