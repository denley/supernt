// SPDX-License-Identifier: GPL-3.0-or-later
// Virtual button presses for the SPC player's UI (hwtest v4, notes/hardware-tests.md): the PIC
// reads the pad over the link (0x2000_0000 / 0x2001_0000, notes/controllers.md) in a ~32 ms UI
// loop and waits, presumably for a button, before it sends the file. So that one hands-free
// video tells which button starts playback, this presses one button at a time in what the
// core answers there (OR'd with the real pad by the caller):
//   - wait until the PIC has read the pad registers for WAIT_US with no file transfer (a
//     transfer during the wait restarts it; FILE_BYTES data bytes during the wait = the file
//     came without help: done, button F);
//   - then press the buttons in ORDER, PRESS_US each, GAP_US apart, round and round;
//   - the first `xfer` (a write run of XFER bytes, link_logger.sv) while pressing ends it for
//     good and records the button pressed last before it.
// Buttons are pad bit numbers (raw order, bit 0 first): 0 B, 1 Y, 2 SELECT, 3 START, 4 UP,
// 5 DOWN, 6 LEFT, 7 RIGHT, 8 A, 9 X, 10 L, 11 R. Order: A, START, X, Y, L, R, UP, DOWN, LEFT,
// RIGHT, SELECT, B (B and SELECT last: B may mean "back").
module vpress #(
    parameter integer WAIT_US    = 10_000_000,
    parameter integer PRESS_US   = 500_000,
    parameter integer GAP_US     = 3_000_000,
    parameter integer FILE_BYTES = 32768
) (
    input  wire        clk,             // 74.25 MHz
    input  wire [31:0] usec,            // time base (link_logger.sv)
    input  wire        ui_rd,           // pulse: the PIC read a pad register
    input  wire        wr,              // pulse: a data byte written
    input  wire        xfer,            // pulse: a write run reached the transfer length
    output reg  [15:0] mask = 16'd0,    // virtual buttons held now
    output reg  [1:0]  state = 2'd0,    // 0 no UI yet, 1 waiting, 2 pressing, 3 done
    output reg  [3:0]  btn = 4'hF,      // button of the current / last press (F = none yet)
    output reg  [7:0]  n_press = 8'd0,
    output reg  [31:0] ui_t = 32'd0,    // first pad read
    output reg  [7:0]  n_wait = 8'd0,   // transfers seen while waiting (each restarts the wait)
    output reg  [3:0]  xfer_btn = 4'hF, // last press before the transfer (F = none)
    output reg  [7:0]  xfer_np = 8'd0,  // its press number (1 = the first press)
    output reg  [31:0] xfer_t = 32'd0,  // time of the transfer
    output reg  [31:0] xfer_dt = 32'd0  // from the start of that press to the transfer (us)
);
    function [3:0] order(input [3:0] k);
        case (k)
            4'd0: order = 4'd8;   4'd1: order = 4'd3;   4'd2: order = 4'd9;   4'd3: order = 4'd1;
            4'd4: order = 4'd10;  4'd5: order = 4'd11;  4'd6: order = 4'd4;   4'd7: order = 4'd5;
            4'd8: order = 4'd6;   4'd9: order = 4'd7;   4'd10: order = 4'd2;  default: order = 4'd0;
        endcase
    endfunction

    reg [31:0] t0 = 32'd0;              // start of the wait / of the current press
    reg [31:0] wbytes = 32'd0;          // data bytes since the wait began
    reg [3:0]  k = 4'd0;                // position in the order
    reg        on = 1'b0;               // pressing (else in the gap)
    wire [31:0] dt = usec - t0;
    always @(posedge clk) begin
        case (state)
            2'd0: if (ui_rd) begin
                    state <= 2'd1;
                    ui_t <= usec;
                    t0 <= usec;
                    wbytes <= 32'd0;
                end
            2'd1: begin
                    if (wr) wbytes <= wbytes + 32'd1;
                    if (wbytes >= FILE_BYTES) begin
                        state <= 2'd3;              // the file came without a press
                        xfer_t <= usec;
                    end else if (xfer) begin
                        t0 <= usec;
                        n_wait <= n_wait + 8'd1;
                    end else if (dt >= WAIT_US) begin
                        state <= 2'd2;
                        t0 <= usec;
                        k <= 4'd0;
                        btn <= order(4'd0);
                        mask <= 16'd1 << order(4'd0);
                        n_press <= 8'd1;
                        on <= 1'b1;
                    end
                end
            2'd2: begin
                    if (xfer) begin
                        state <= 2'd3;
                        mask <= 16'd0;
                        xfer_btn <= btn;
                        xfer_np <= n_press;
                        xfer_t <= usec;
                        xfer_dt <= on ? dt : dt + PRESS_US;
                    end else if (on && dt >= PRESS_US) begin
                        on <= 1'b0;
                        mask <= 16'd0;
                        t0 <= usec;
                    end else if (!on && dt >= GAP_US) begin
                        on <= 1'b1;
                        t0 <= usec;
                        k <= k == 4'd11 ? 4'd0 : k + 4'd1;
                        btn <= order(k == 4'd11 ? 4'd0 : k + 4'd1);
                        mask <= 16'd1 << order(k == 4'd11 ? 4'd0 : k + 4'd1);
                        n_press <= n_press + 8'd1;
                    end
                end
            default: mask <= 16'd0;
        endcase
    end
endmodule
