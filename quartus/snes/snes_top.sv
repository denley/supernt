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
    parameter [15:0] RESET_CYCLES = 16'hffff  // core reset after PLL lock (clk_sys cycles)
) (
    input  wire       clk,      // W16, 74.25 MHz
    output wire       pclk,     // M22, pixel clock to the AD9889B
    output wire       s0,       // P16 VSYNC \
    output wire       s1,       // M16 DE     } with SYNC_ORDER 3
    output wire       s2,       // M18 HSYNC /
    output reg  [7:0] ch1,      // red:   K21 K22 M20 L22 T17 T18 R15 T22 (bit 7..0)
    output reg  [7:0] ch2,      // green: N20 P22 R22 R21 P19 P18 N16 N19
    output reg  [7:0] ch3       // blue:  T20 T15 T19 R16 M21 N21 P17 R17
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
    snes_core #(.ROM_HEX(ROM_HEX)) snes (
        .clk_sys(clk_sys), .reset(core_reset),
        .r(r), .g(g), .b(b), .dotclk(dotclk), .hde(hde), .vde(vde), .high_res(high_res),
        .v224(v224), .audio_l(), .audio_r()
    );

    // ---------------------------------------------------------------- video
    wire [7:0] vr, vg, vb;
    wire       vs0, vs1, vs2;
    snes_video #(.OUT_W(OUT_W), .LOCK(LOCK), .SYNC_ORDER(SYNC_ORDER)) video (
        .clk_sys(clk_sys), .r(r), .g(g), .b(b), .dotclk(dotclk), .hde(hde), .vde(vde),
        .high_res(high_res), .v224(v224),
        .clk_vid(clk_vid), .vr(vr), .vg(vg), .vb(vb), .s0(vs0), .s1(vs1), .s2(vs2), .perm()
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
endmodule
