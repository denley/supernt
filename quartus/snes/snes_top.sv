// SPDX-License-Identifier: GPL-3.0-or-later
// Super Nt top level: SNES + SA-1 core (snes_core.sv) with the test ROM in block RAM, 720p60
// video out to the AD9889B (snes_video.sv). notes/snes-quartus.md has the details.
//
// Pins: only the board clock (W16, input) and the HDMI transmitter's video pins, which spc.cor
// drives as outputs too (same names and pins as hw/vtest/vtest.v and quartus/vtest/pins.tcl).
// Every other pin is left unused (Quartus reserves them as inputs with weak pull-up,
// quartus/common/supernt.tcl).
module top #(
    parameter ROM_HEX    = "../../build/snes/sa1test.hex",
    // Colour channel mapping: which colour goes to the pin groups ch1/ch2/ch3. pins.tcl already
    // assigns ch1/ch2/ch3 = R/G/B as confirmed on the console (vtest, 21 Oct 2026), so 0.
    // 0: R,G,B  1: R,B,G  2: G,R,B  3: G,B,R  4: B,R,G  5: B,G,R.
    parameter CH_ORDER   = 0,
    // HS/VS/DE roles of P16/M16/M18 (table in snes_video.sv). 3 = {VS, DE, HS}, confirmed on the
    // console with vtest. -1 cycles through all 6 every 8 s (white boxes top left = order + 1).
    parameter SYNC_ORDER = 3,
    parameter OUT_W      = 768,     // picture width on the 1280-pixel line (896 = 4:3)
    parameter LOCK       = 1,       // align output frames to the SNES (snes_video.sv)
    parameter [15:0] RESET_CYCLES = 16'hffff, // core reset after PLL lock (clk_sys cycles)
    // Serial audio framing the AD9889B expects (notes/audio.md): 0 = I2S, 1 = left-justified.
    // I2S confirmed on the console (hwtest v3, 22 Oct 2026); the PIC enables the HDMI audio
    // only once its 0x2004 status poll has passed (notes/pic-link.md).
    parameter AUD_FRAMING = 0,
    // Controller port wiring (notes/controllers.md, numbering as quartus/common/pad_test.sv):
    // bit 1 = swap roles (latch on J13/K16, clock on P14), bit 0 = invert both outputs.
    // 0 confirmed on the console (hwtest, 22 Oct 2026: FFFF0000 idle, B/Start/A read right).
    parameter [1:0] PAD_CFG = 2'd0
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
    input  wire       pad_t12          // port 1 data
);
    // ---------------------------------------------------------------- clocks and reset
    wire clk_vid = clk;         // 720p pixel clock straight from the 74.25 MHz board clock
    wire clk_sys;               // 21.44196 MHz SNES master clock (60.000 Hz frames, snes_pll.v)
    wire pll_locked;
    snes_pll pll (.refclk(clk), .rst(1'b0), .outclk_0(clk_sys), .locked(pll_locked));

    // Hold the core in reset until the PLL has been locked for ~3 ms.
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg [1:0]  lock_sync = 2'b00;
    reg [15:0] rst_cnt = 16'd0;
    reg        core_reset = 1'b1;
    always @(posedge clk_sys) begin
        lock_sync <= {lock_sync[0], pll_locked};
        if (!lock_sync[1]) begin
            rst_cnt    <= 16'd0;
            core_reset <= 1'b1;
        end else if (rst_cnt != RESET_CYCLES)
            rst_cnt <= rst_cnt + 16'd1;
        else
            core_reset <= 1'b0;
    end

    // ---------------------------------------------------------------- SNES
    wire [7:0] r, g, b;
    wire       dotclk, hde, vde, high_res, v224;
    wire [15:0] audio_l /* verilator public_flat_rd */, audio_r;
    wire        joy_strb, joy_clk, joy_d0;
    snes_core #(.ROM_HEX(ROM_HEX)) snes (
        .clk_sys(clk_sys), .reset(core_reset),
        .r(r), .g(g), .b(b), .dotclk(dotclk), .hde(hde), .vde(vde), .high_res(high_res),
        .v224(v224), .audio_l(audio_l), .audio_r(audio_r),
        .joy_strb(joy_strb), .joy_clk(joy_clk), .joy1_d0(joy_d0)
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
