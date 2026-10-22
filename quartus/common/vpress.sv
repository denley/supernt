// SPDX-License-Identifier: GPL-3.0-or-later
// Virtual button presses for the SPC player's UI (hwtest v4/v5, notes/hardware-tests.md): the
// PIC reads the pad over the link (0x2000_0000 / 0x2001_0000, notes/controllers.md) in a ~32 ms
// UI loop and waits for buttons. So that one hands-free video explores the player's menus,
// this presses one button at a time in what the core answers there (OR'd with the real pad by
// the caller):
//   - wait until the PIC has read the pad registers for WAIT_US;
//   - then press the buttons in ORDER (48 presses, then round again), PRESS_US each, GAP_US
//     apart (one press every PRESS_US + GAP_US);
//   - `dump` is high for DUMP_US at the end of the wait and of every gap, ending DUMP_END
//     before the next press (the screen has settled after the press; the caller shows the captured player
//     screen then, ui_capture.sv; its page is latched per frame, so the window ends early
//     enough that no frame of it overlaps the press);
//   - pressing ends for good when the file comes: a single write run of FILE_RUN bytes
//     (link_logger's `xfer` pulse, with the run's start address) outside the blocks the UI
//     writes in big runs (0x1018, 0x1006, 0x1017), or OUT_BYTES data bytes in total outside all
//     regions the player UI writes anyway (known(): the screen 0x1018_xxxx, registers
//     0x1000_xxxx, font 0x1006_xxxx, palette 0x1001_3xxx, 0x1010_00xx, 0x111F_81xx,
//     0x1017_xxxx). The press before it is recorded. (v4b stopped after 32 KB of any writes:
//     eight 4 KB screen redraws.)
// Buttons are pad bit numbers (raw order, bit 0 first): 0 B, 1 Y, 2 SELECT, 3 START, 4 UP,
// 5 DOWN, 6 LEFT, 7 RIGHT, 8 A, 9 X, 10 L, 11 R. v4b (notes/hardware-tests.md) saw screen
// changes after START (and a volume fade), DOWN, Y, UP, SELECT (back to the first screen) and
// B; A, RIGHT, LEFT, X, L, R changed nothing on the first screens. The order tries every
// button from the first screen and from the screens START, DOWN and B lead to, with repeats
// (toggles), A after each move (select) and SELECT/B (back) in between.
module vpress #(
    parameter integer WAIT_US   = 4_000_000,
    parameter integer PRESS_US  = 500_000,
    parameter integer GAP_US    = 3_500_000,
    parameter integer DUMP_US   = 1_000_000,
    parameter integer DUMP_END  = 50_000,     // the dump window ends this long before a press
    parameter integer FILE_RUN  = 16384,      // documentation: link_logger's XFER
    parameter integer OUT_BYTES = 65536,
    // 1: instead of exploring, run the file: DOWN, DOWN, then bit 1 (RUN; hwtest v5 found the
    // browser opens in 0:/SPC with the cursor on GO BACK, then SPC README.TXT, then the chord),
    // and press nothing after that (v5's exploring went into the settings menu and toggled a
    // setting)
    parameter integer SCRIPT    = 0
) (
    input  wire        clk,             // 74.25 MHz
    input  wire [31:0] usec,            // time base (link_logger.sv)
    input  wire        ui_rd,           // pulse: the PIC read a pad register
    input  wire        wr,              // pulse: a data byte written ...
    input  wire [31:0] wr_addr,         // ... at this address
    input  wire        xfer,            // pulse: a write run reached FILE_RUN bytes ...
    input  wire [31:0] xfer_addr,       // ... starting here
    output wire [15:0] mask,            // virtual buttons held now
    output wire [1:0]  state,           // 0 no UI yet, 1 waiting, 2 pressing, 3 done (file)
    output wire [3:0]  btn,             // button of the current / last press (F = none yet)
    output reg  [7:0]  n_press = 8'd0,  // presses so far (the current one included)
    output reg         press_go = 1'b0, // pulse: a press starts (n_press, btn already new)
    output wire        dump,            // last DUMP_US of a gap
    output reg  [31:0] press_t = 32'd0, // start of the current press
    output reg  [31:0] ui_t = 32'd0,    // first pad read
    output reg  [31:0] n_out = 32'd0,   // data bytes outside the known regions while pressing
    output wire [3:0]  xfer_btn,        // last press before the file (F = none)
    output reg  [7:0]  xfer_np = 8'd0,  // its press number (1 = the first press)
    output reg  [31:0] xfer_t = 32'd0,  // time the file was detected
    output reg  [31:0] xfer_dt = 32'd0  // from the start of that press (us)
);
    // Registers with a nonzero power-up value are internal (Quartus ignores initial values in
    // ANSI port declarations, notes/quartus.md).
    reg [15:0] mask_q = 16'd0;
    reg [1:0]  state_q = 2'd0;
    reg [3:0]  btn_q = 4'hF;
    reg [3:0]  xbtn_q = 4'hF;
    assign mask = mask_q;
    assign state = state_q;
    assign btn = btn_q;
    assign xfer_btn = xbtn_q;

    localparam [3:0] B = 4'd0, Y = 4'd1, SE = 4'd2, ST = 4'd3, UP = 4'd4, DN = 4'd5, LT = 4'd6,
                     RT = 4'd7, A = 4'd8, X = 4'd9, L = 4'd10, R = 4'd11;
    function [3:0] order(input [5:0] k);
        if (SCRIPT != 0) order = k < 6'd2 ? DN : Y;
        else case (k)
            6'd0:  order = A;   6'd1:  order = ST;  6'd2:  order = ST;  6'd3:  order = A;
            6'd4:  order = DN;  6'd5:  order = DN;  6'd6:  order = A;   6'd7:  order = UP;
            6'd8:  order = A;   6'd9:  order = RT;  6'd10: order = A;   6'd11: order = LT;
            6'd12: order = Y;   6'd13: order = Y;   6'd14: order = X;   6'd15: order = X;
            6'd16: order = L;   6'd17: order = R;   6'd18: order = SE;  6'd19: order = ST;
            6'd20: order = SE;  6'd21: order = B;   6'd22: order = B;   6'd23: order = A;
            6'd24: order = DN;  6'd25: order = ST;  6'd26: order = B;   6'd27: order = RT;
            6'd28: order = RT;  6'd29: order = ST;  6'd30: order = DN;  6'd31: order = A;
            6'd32: order = ST;  6'd33: order = UP;  6'd34: order = UP;  6'd35: order = A;
            6'd36: order = ST;  6'd37: order = Y;   6'd38: order = A;   6'd39: order = SE;
            6'd40: order = X;   6'd41: order = A;   6'd42: order = L;   6'd43: order = ST;
            6'd44: order = R;   6'd45: order = ST;  6'd46: order = B;   default: order = ST;
        endcase
    endfunction

    // regions the player UI writes anyway (v3/v4 logs)
    function known(input [31:0] ad);
        known = ad[31:16] == 16'h1018 || ad[31:16] == 16'h1000 || ad[31:16] == 16'h1006 ||
                ad[31:12] == 20'h10013 || ad[31:8] == 24'h101000 || ad[31:8] == 24'h111F81 ||
                ad[31:16] == 16'h1017;
    endfunction

    // the blocks the UI writes in big runs (a 16 KB run anywhere else is the file, even in the
    // 0x1000_xxxx register space)
    function big_known(input [31:0] ad);
        big_known = ad[31:16] == 16'h1018 || ad[31:16] == 16'h1006 || ad[31:16] == 16'h1017;
    endfunction

    reg [31:0] t0 = 32'd0;              // start of the wait / of the current press / gap
    reg [5:0]  k = 6'd0;                // position in the order
    reg        on = 1'b0;               // pressing (else in the gap)
    wire [31:0] dt = usec - t0;
    assign dump = (state_q == 2'd2 && !on && dt >= GAP_US - DUMP_END - DUMP_US &&
                   dt < GAP_US - DUMP_END) ||
                  (state_q == 2'd1 && dt >= WAIT_US - DUMP_END - DUMP_US && dt < WAIT_US - DUMP_END);
    wire file_now = (xfer && !big_known(xfer_addr)) || n_out >= OUT_BYTES;
    always @(posedge clk) begin
        press_go <= 1'b0;
        case (state_q)
            2'd0: if (ui_rd) begin
                    state_q <= 2'd1;
                    ui_t <= usec;
                    t0 <= usec;
                end
            2'd1: if (dt >= WAIT_US) begin
                    state_q <= 2'd2;
                    t0 <= usec;
                    press_t <= usec;
                    k <= 6'd0;
                    btn_q <= order(6'd0);
                    mask_q <= 16'd1 << order(6'd0);
                    n_press <= 8'd1;
                    press_go <= 1'b1;
                    on <= 1'b1;
                end
            2'd2: begin
                    if (wr && !known(wr_addr)) n_out <= n_out + 32'd1;
                    if (file_now) begin
                        state_q <= 2'd3;
                        mask_q <= 16'd0;
                        xbtn_q <= btn_q;
                        xfer_np <= n_press;
                        xfer_t <= usec;
                        xfer_dt <= usec - press_t;
                    end else if (on && dt >= PRESS_US) begin
                        on <= 1'b0;
                        mask_q <= 16'd0;
                        t0 <= usec;
                    end else if (!on && dt >= GAP_US && !(SCRIPT != 0 && k >= 6'd2)) begin
                        on <= 1'b1;
                        t0 <= usec;
                        press_t <= usec;
                        k <= k == 6'd47 ? 6'd0 : k + 6'd1;
                        btn_q <= order(k == 6'd47 ? 6'd0 : k + 6'd1);
                        mask_q <= 16'd1 << order(k == 6'd47 ? 6'd0 : k + 6'd1);
                        n_press <= n_press + 8'd1;
                        press_go <= 1'b1;
                    end
                end
            default: mask_q <= 16'd0;
        endcase
    end
endmodule
