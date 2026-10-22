// SPDX-License-Identifier: GPL-3.0-or-later
// Controller port test (notes/controllers.md). spc.cor polls port 1 itself: P14 (likely
// LATCH), J13 + K16 (the same signal, likely CLOCK for ports 1 and 2), data in on T12. Which
// output is latch and whether the board inverts them is not certain, so polls rotate through
// four configurations, one per poll (~60 polls/s):
//   cfg bit 0: invert both outputs        cfg bit 1: swap roles (latch on J13/K16, clock on P14)
// Each poll: latch high 12 us, then 32 bits, each sampled 6 us after the previous clock rise,
// clock low 6 us / high 6 us (standard SNES timing). raw[cfg] = the 32 bits as read, bit 0
// first, inverted so 1 = line low (= pressed on a standard pad). The first poll waits ~200 ms
// after configuration (as spc.cor does); outputs stay low until then. FIXED_CFG >= 0 polls
// only that configuration (cfg 0 is confirmed on the console, notes/controllers.md).
module pad_test #(
    parameter integer FIXED_CFG = -1,
    parameter integer START_US  = 200000   // first poll after configuration (simulation: less)
) (
    input  wire        clk,             // 74.25 MHz
    output reg         p14 = 1'b0,
    output reg         j13k16 = 1'b0,
    input  wire        t12,
    output reg  [31:0] raw0 = 0, raw1 = 0, raw2 = 0, raw3 = 0,
    output wire        t12_now,
    output reg  [15:0] polls = 16'd0
);
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg [1:0] ts = 2'b11;
    always @(posedge clk) ts <= {ts[0], t12};
    assign t12_now = ts[1];

    reg [6:0]  udiv = 7'd0;
    wire       us = udiv == 7'd73;      // 1 us tick
    always @(posedge clk) udiv <= us ? 7'd0 : udiv + 7'd1;

    reg [17:0] wait_us = START_US[17:0];    // start-up delay, then the gap between polls
    reg [1:0]  cfg = FIXED_CFG >= 0 ? FIXED_CFG[1:0] : 2'd0;
    reg [2:0]  st = 3'd0;
    reg [4:0]  t = 5'd0;                // us within a phase
    reg [5:0]  n = 6'd0;                // bit
    reg [31:0] sh = 32'd0;
    reg        latch = 1'b0, clkp = 1'b1, active = 1'b0;
    localparam S_WAIT = 3'd0, S_LATCH = 3'd1, S_FIRST = 3'd2, S_LOW = 3'd3, S_HIGH = 3'd4;

    always @(posedge clk) begin
        // outputs: roles and polarity from cfg (both low until the first poll)
        if (active) begin
            p14    <= (cfg[1] ? clkp : latch) ^ cfg[0];
            j13k16 <= (cfg[1] ? latch : clkp) ^ cfg[0];
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
                S_FIRST: if (t == 5'd5) begin          // bit 0 valid after the latch
                        sh <= {~ts[1], sh[31:1]};
                        n <= 6'd1; clkp <= 1'b0; st <= S_LOW; t <= 5'd0;
                    end else t <= t + 5'd1;
                S_LOW: if (t == 5'd5) begin
                        clkp <= 1'b1; st <= S_HIGH; t <= 5'd0;
                    end else t <= t + 5'd1;
                S_HIGH: if (t == 5'd5) begin
                        sh <= {~ts[1], sh[31:1]};
                        if (n == 6'd31) begin
                            case (cfg)
                                2'd0: raw0 <= {~ts[1], sh[31:1]};
                                2'd1: raw1 <= {~ts[1], sh[31:1]};
                                2'd2: raw2 <= {~ts[1], sh[31:1]};
                                default: raw3 <= {~ts[1], sh[31:1]};
                            endcase
                            polls <= polls + 16'd1;
                            cfg <= FIXED_CFG >= 0 ? FIXED_CFG[1:0] : cfg + 2'd1;
                            wait_us <= 18'd16000;
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
