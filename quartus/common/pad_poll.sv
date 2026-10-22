// SPDX-License-Identifier: GPL-3.0-or-later
// Controller port 1 poller for quartus/snes_load (notes/controllers.md): the wiring confirmed
// on the console (PAD_CFG 0: P14 = LATCH, J13 + K16 = CLOCK, data on T12, 1 = line low =
// pressed), timing as quartus/common/pad_test.sv (latch high 12 us, 32 bits, clock low 6 us /
// high 6 us, each bit sampled 6 us after the previous clock rise), one poll every PERIOD_US.
// `raw` = the 32 bits of the newest poll, bit 0 first: 11-0 = R L X A RIGHT LEFT DOWN UP START
// SELECT Y B, 15-12 the ID (0 on a standard pad), 31-16 all 1 on a standard pad (`std`).
// The SNES core and the PIC both get these bits (the SNES through a virtual 4021 in the top),
// so the physical port is only ever driven by this poller.
module pad_poll #(
    parameter integer CLK_MHZ   = 74,      // clk in MHz (rounded; 1 us = CLK_MHZ cycles)
    parameter integer START_US  = 200000,  // first poll after configuration
    parameter integer PERIOD_US = 1000
) (
    input  wire        clk,
    output reg         p14 = 1'b0,          // LATCH (low until the first poll)
    output reg         j13k16 = 1'b0,       // CLOCK (idles high once polling)
    input  wire        t12,
    output reg  [31:0] raw = 32'd0,
    output wire        is_std,
    output reg  [31:0] polls = 32'd0
);
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg [1:0] ts = 2'b11;
    always @(posedge clk) ts <= {ts[0], t12};

    reg [6:0]  udiv = 7'd0;
    wire       us = udiv == CLK_MHZ - 1;
    always @(posedge clk) udiv <= us ? 7'd0 : udiv + 7'd1;

    reg [17:0] wait_us = START_US[17:0];
    reg [2:0]  st = 3'd0;
    reg [4:0]  t = 5'd0;
    reg [5:0]  n = 6'd0;
    reg [31:0] sh = 32'd0;
    reg        latch = 1'b0, clkp = 1'b1, active = 1'b0;
    localparam S_WAIT = 3'd0, S_LATCH = 3'd1, S_FIRST = 3'd2, S_LOW = 3'd3, S_HIGH = 3'd4;
    assign is_std = raw[15:12] == 4'd0 && raw[31:16] == 16'hFFFF;

    always @(posedge clk) begin
        if (active) begin
            p14    <= latch;
            j13k16 <= clkp;
        end
        if (us) begin
            case (st)
                S_WAIT: if (wait_us == 0) begin
                        active <= 1'b1;
                        latch <= 1'b1; clkp <= 1'b1;
                        st <= S_LATCH; t <= 5'd0;
                    end else
                        wait_us <= wait_us - 18'd1;
                S_LATCH: if (t == 5'd11) begin
                        latch <= 1'b0; st <= S_FIRST; t <= 5'd0;
                    end else t <= t + 5'd1;
                S_FIRST: if (t == 5'd5) begin
                        sh <= {~ts[1], sh[31:1]};
                        n <= 6'd1; clkp <= 1'b0; st <= S_LOW; t <= 5'd0;
                    end else t <= t + 5'd1;
                S_LOW: if (t == 5'd5) begin
                        clkp <= 1'b1; st <= S_HIGH; t <= 5'd0;
                    end else t <= t + 5'd1;
                S_HIGH: if (t == 5'd5) begin
                        sh <= {~ts[1], sh[31:1]};
                        if (n == 6'd31) begin
                            raw <= {~ts[1], sh[31:1]};
                            polls <= polls + 32'd1;
                            wait_us <= PERIOD_US[17:0] - 18'd410;
                            st <= S_WAIT;
                        end else begin
                            n <= n + 6'd1; clkp <= 1'b0; st <= S_LOW;
                        end
                        t <= 5'd0;
                    end else t <= t + 5'd1;
                default: st <= S_WAIT;
            endcase
        end
    end
endmodule
