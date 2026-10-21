// Minimal toolchain test: a free-running counter on a clock input pin, MSB on an output pin.
// Pins are set in blinky.qsf. The clock pin is a best guess (W16, probably the 74.25 MHz
// reference) and the output is an HDMI data pin, so this checks the flow, not the board.
module top (
    input  wire clk,
    output wire led
);
    reg [25:0] ctr = 26'd0;
    always @(posedge clk)
        ctr <= ctr + 26'd1;
    assign led = ctr[25];
endmodule
