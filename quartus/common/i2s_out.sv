// SPDX-License-Identifier: GPL-3.0-or-later
// Stereo 16-bit samples from any clock domain -> the AD9889B's serial audio input at 48 kHz
// (pins and clocking as i2s_test.sv / notes/audio.md: MCLK 12.288 MHz, BCLK = MCLK/4,
// LRCLK = BCLK/64, 24-bit slots MSB first, changes on BCLK falling edges).
// FRAMING 0 = I2S (MSB one BCLK after the LRCLK edge), 1 = left-justified.
// Resampling is a sample-and-hold: once per 48 kHz frame the latest source sample is taken
// (fine for the SNES DSP's 32 kHz output as a first step).
module i2s_out #(
    parameter FRAMING = 0
) (
    // source side
    input  wire        clk_src,
    input  wire [15:0] l, r,            // signed
    // output side
    input  wire        mclk,            // 12.288 MHz
    output wire        mclk_pin,
    output reg         bclk = 1'b0,
    output reg         lrclk = 1'b0,
    output reg         sdata = 1'b0
);
    altddio_out #(
        .extend_oe_disable("OFF"), .intended_device_family("Cyclone V"),
        .invert_output("OFF"), .lpm_hint("UNUSED"), .lpm_type("altddio_out"),
        .oe_reg("UNREGISTERED"), .power_up_high("OFF"), .width(1)
    ) mclk_ddio (
        .datain_h(1'b1), .datain_l(1'b0), .outclock(mclk), .dataout(mclk_pin),
        .aclr(1'b0), .aset(1'b0), .oe(1'b1), .oe_out(), .outclocken(1'b1), .sclr(1'b0), .sset(1'b0)
    );

    // Handshake: the output side toggles req once per frame; the source side answers by
    // copying the sample into hold and toggling ack; the output side takes hold on ack.
    reg req = 1'b0;
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg [2:0] req_s = 3'd0;
    reg ack = 1'b0;
    reg [31:0] hold = 32'd0;
    always @(posedge clk_src) begin
        req_s <= {req_s[1:0], req};
        if (req_s[2] != req_s[1]) begin
            hold <= {l, r};
            ack  <= ~ack;
        end
    end
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg [2:0] ack_s = 3'd0;
    reg [31:0] smp = 32'd0;             // {left, right} for the frame being sent
    reg [31:0] next = 32'd0;
    always @(posedge mclk) begin
        ack_s <= {ack_s[1:0], ack};
        if (ack_s[2] != ack_s[1]) next <= hold;
    end

    reg [1:0] div = 2'd0;
    reg [5:0] bit_n = 6'd0;
    wire [5:0] nb   = bit_n + 6'd1;
    wire [4:0] slot = nb[4:0];
    wire [4:0] p    = FRAMING ? slot : slot - 5'd1;
    wire [15:0] w   = nb[5] ? smp[15:0] : smp[31:16];
    wire       dbit = p < 5'd16 && w[5'd15 - p];   // 16 data bits, then zeros to 24/32
    always @(posedge mclk) begin
        div <= div + 2'd1;
        if (div == 2'd1) bclk <= 1'b1;
        if (div == 2'd3) begin
            bclk  <= 1'b0;
            bit_n <= nb;
            lrclk <= nb[5];
            sdata <= dbit;
            if (bit_n == 6'd62) smp <= next;
            if (bit_n == 6'd31) req <= ~req;  // ask for the next sample mid-frame
        end
    end
endmodule
