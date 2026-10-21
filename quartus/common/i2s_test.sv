// SPDX-License-Identifier: GPL-3.0-or-later
// Audio test for the AD9889B's serial audio input, wired as spc.cor does it (notes/audio.md):
// MCLK 12.288 MHz on L17, BCLK 3.072 MHz (64 fs) on L19, LRCLK 48 kHz on K17, data on L18.
// Data and LRCLK change on BCLK falling edges.
//
// The framing the PIC32 set the AD9889B up for isn't known, so the tone alternates every 4 s
// between two framings, each with its own pitch:
//   mode 0: I2S (MSB one BCLK after the LRCLK edge), 440 Hz
//   mode 1: left-justified (MSB on the LRCLK edge),   880 Hz
// 24-bit samples, MSB first in 32-bit slots, LRCLK low = left. The sine is at 0.9 of full scale,
// so a one-bit misalignment wraps it and sounds harsh: the clean-sounding pitch names the
// framing.
module i2s_test #(
    parameter SINE_HEX = "sine.hex",    // 1024 x 16-bit signed sine (tools/mksine.py)
    parameter integer MODE_SAMPLES = 192000   // 4 s at 48 kHz
) (
    input  wire        mclk,            // 12.288 MHz
    output wire        mclk_pin,        // L17 (DDIO copy of mclk)
    output reg         bclk = 1'b0,     // L19
    output reg         lrclk = 1'b0,    // K17
    output reg         sdata = 1'b0,    // L18
    output reg         mode = 1'b0,
    output reg  [7:0]  secs = 8'd0      // seconds since start (status)
);
    altddio_out #(
        .extend_oe_disable("OFF"), .intended_device_family("Cyclone V"),
        .invert_output("OFF"), .lpm_hint("UNUSED"), .lpm_type("altddio_out"),
        .oe_reg("UNREGISTERED"), .power_up_high("OFF"), .width(1)
    ) mclk_ddio (
        .datain_h(1'b1), .datain_l(1'b0), .outclock(mclk), .dataout(mclk_pin),
        .aclr(1'b0), .aset(1'b0), .oe(1'b1), .oe_out(), .outclocken(1'b1), .sclr(1'b0), .sset(1'b0)
    );

    (* ramstyle = "M10K" *) reg signed [15:0] sine [0:1023];
    initial $readmemh(SINE_HEX, sine);

    reg [1:0]  div = 2'd0;          // MCLK / 4 = BCLK
    reg [5:0]  bit_n = 6'd0;        // BCLK within the 64-BCLK frame
    reg [31:0] phase = 32'd0;
    reg [23:0] sample = 24'd0;
    reg signed [15:0] s_q;
    reg [17:0] nsamp = 18'd0;
    reg [15:0] nsec = 16'd0;

    wire [31:0] inc = mode ? 32'd78741067 : 32'd39370534;   // 880 / 440 Hz at 48 kHz
    // Bit for the next BCLK period nb: sample bit p of the slot (I2S lags by one BCLK; slot
    // bits past the 24-bit sample, and I2S's slot bit 0, are 0).
    wire [5:0] nb   = bit_n + 6'd1;
    wire [4:0] slot = nb[4:0];
    wire [4:0] p    = mode ? slot : slot - 5'd1;
    wire       dbit = p < 5'd24 && sample[5'd23 - p];

    always @(posedge mclk) begin
        div <= div + 2'd1;
        s_q <= sine[phase[31:22]];
        if (div == 2'd1)
            bclk <= 1'b1;                       // rising edge mid-way
        if (div == 2'd3) begin                  // falling edge: next bit
            bclk  <= 1'b0;
            bit_n <= nb;
            lrclk <= nb[5];
            sdata <= dbit;
            if (bit_n == 6'd62) begin           // before the frame: next sample, both channels
                sample <= {s_q, 8'd0};
                phase  <= phase + inc;
                if (nsamp == MODE_SAMPLES - 1) begin
                    nsamp <= 18'd0;
                    mode  <= ~mode;
                end else
                    nsamp <= nsamp + 18'd1;
                if (nsec == 16'd47999) begin
                    nsec <= 16'd0;
                    secs <= secs + 8'd1;
                end else
                    nsec <= nsec + 16'd1;
            end
        end
    end
endmodule
