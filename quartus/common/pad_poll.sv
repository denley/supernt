// SPDX-License-Identifier: GPL-3.0-or-later
// Controller poller for quartus/snes_load (notes/controllers.md): the wiring confirmed on the
// console (PAD_CFG 0: P14 = LATCH, J13 + K16 = CLOCK, port 1 data on T12, port 2 data on D6
// (found by v3's pin scan), 1 = line low = pressed; both ports share LATCH and CLOCK, so one poll
// reads both). Two timings, picked per poll by `fast`:
//   fast = 0 (v2 default): the stock spc.cor poller's waveform as decoded (notes/controllers.md,
//     "Timing"): a poll every 16.17 ms, LATCH high 8.3 us, CLOCK idling high with 33 low pulses
//     of 0.6 us every 19.3 us, the first 16.5 us after the latch rose, T12 sampled as the clock
//     falls. In case the PIC watches the controller lines itself (the Super Nt's menu combination
//     while a game runs), it then sees exactly what the stock core makes.
//   fast = 1 (v1): a poll every 1 ms, LATCH 12 us, 32 clock pulses 6 us low / 6 us high, each bit
//     sampled as the clock falls (6 us after the previous rise).
// `raw` = the first 32 bits of the newest poll, bit 0 first: 11-0 = R L X A RIGHT LEFT DOWN UP
// START SELECT Y B, 15-12 the ID (0 on a standard pad), 31-16 all 1 on a standard pad (`std`);
// `raw2` / `is_std2` the same for port 2.
// The SNES core and the PIC both get these bits (the SNES through a virtual 4021 in the top),
// so the physical port is only ever driven by this poller.
module pad_poll #(
    parameter integer CLK_HZ   = 74250000,  // clk
    parameter integer START_US = 200000     // first poll after configuration
) (
    input  wire        clk,
    input  wire        fast,                // timing of the next poll (see above)
    output reg         p14 = 1'b0,          // LATCH (low until the first poll)
    output reg         j13k16 = 1'b0,       // CLOCK (idles high once polling)
    input  wire        t12,
    input  wire        d6,                  // port 2 data
    output reg  [31:0] raw = 32'd0,
    output wire        is_std,
    output reg  [31:0] raw2 = 32'd0,
    output wire        is_std2,
    output reg  [31:0] polls = 32'd0
);
    function integer cyc(input integer ns);      // ns (< 28 000) -> clk cycles (rounded)
        cyc = (ns * (CLK_HZ / 1000) + 500000) / 1000000;
    endfunction
    function integer cyc_us(input integer us);   // us -> clk cycles (32-bit safe below 28 ms)
        cyc_us = us * (CLK_HZ / 1000) / 1000;
    endfunction
    // stock: from the 21.477 MHz cycle counts of the decode (178, 354, 13, 414, 347351)
    localparam integer S_LAT = cyc(8288),  S_FIRST = cyc(16483), S_LOW = cyc(605),
                       S_PER = cyc(19276), S_N = 33, S_POLL = cyc_us(16173);
    localparam integer F_LAT = cyc(12000), F_FIRST = cyc(18000), F_LOW = cyc(6000),
                       F_PER = cyc(12000), F_N = 32, F_POLL = cyc_us(1000);

    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg [1:0] ts = 2'b11, ts2 = 2'b11;
    always @(posedge clk) begin ts <= {ts[0], t12}; ts2 <= {ts2[0], d6}; end

    reg [31:0] wait_c = START_US * (CLK_HZ / 1000000);
    reg        polling = 1'b0, active = 1'b0, f = 1'b0;
    reg [23:0] t = 24'd0;                   // clk cycles since the latch rose
    reg [23:0] t_ev = 24'd0;                // next clock fall
    reg [5:0]  n = 6'd0;                    // pulses done
    reg [31:0] sh = 32'd0, sh2 = 32'd0;
    assign is_std  = raw[15:12] == 4'd0 && raw[31:16] == 16'hFFFF;
    assign is_std2 = raw2[15:12] == 4'd0 && raw2[31:16] == 16'hFFFF;

    wire [23:0] lat_c   = f ? F_LAT : S_LAT;
    wire [23:0] low_c   = f ? F_LOW : S_LOW;
    wire [23:0] per_c   = f ? F_PER : S_PER;
    wire [5:0]  n_c     = f ? F_N : S_N;
    wire [31:0] poll_c  = f ? F_POLL : S_POLL;

    always @(posedge clk) begin
        if (!polling) begin
            if (wait_c == 32'd0) begin
                polling <= 1'b1; active <= 1'b1; f <= fast;
                t <= 24'd0; n <= 6'd0;
                t_ev <= fast ? F_FIRST : S_FIRST;
                p14 <= 1'b1; j13k16 <= 1'b1;
            end else
                wait_c <= wait_c - 32'd1;
        end else begin
            t <= t + 24'd1;
            if (t == lat_c) p14 <= 1'b0;
            if (t == t_ev && n != n_c) begin            // clock falls: sample the line
                if (n < 6'd32) begin
                    sh  <= {~ts[1], sh[31:1]};
                    sh2 <= {~ts2[1], sh2[31:1]};
                end
                j13k16 <= 1'b0;
            end
            if (t == t_ev + low_c && n != n_c) begin    // clock rises (the pad shifts)
                j13k16 <= 1'b1;
                n <= n + 6'd1;
                t_ev <= t_ev + per_c;
            end
            if (n == n_c && t == t_ev + low_c) begin
                // all pulses done (one period after the last rise): the 32 bits, next poll
                raw <= sh;
                raw2 <= sh2;
                polls <= polls + 32'd1;
                polling <= 1'b0;
                wait_c <= poll_c - {8'd0, t} - 32'd2;
            end
        end
    end
endmodule
