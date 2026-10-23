// SPDX-License-Identifier: GPL-3.0-or-later
// Controller port 2 finder, as built into quartus/snes_load v3 (notes/controllers.md, "Port 2"),
// which found port 2's data line on D6 on the console (23 Oct 2026). Not part of any build since
// v4 (which reads D6 directly); kept for finding other unknown input pins the same way. v3 fed it
// from pad_poll.sv's sample strobes (smp/idx/d1/done; pad_poll no longer has them).
// The stock spc.cor reads port 1 only (T12), so port 2's data pin was unknown. The two ports
// share LATCH and (as decoded) CLOCK, so a pad in port 2 shifts out its bits in step with port 1
// while pad_poll.sv polls. This module samples NC candidate pins (only ever read) at the poll's
// sample points and checks each one as a pad:
//   - pad-like (per polarity) = samples 12-15 not pressed and 16-31 pressed (a standard pad's ID
//     bits and the 1s after the 16 bits; "pressed" = line low for the normal polarity, as T12;
//     high for the inverted one), for 3 polls in a row;
//   - independent = once seen pad-like in a poll whose 32 bits differ from port 1's (a copy of
//     port 1's data line on another pin would never differ), sticky.
// The lowest-numbered candidate that is pad-like and independent becomes port 2 and stays so
// while it keeps answering; its bits (pressed = 1, port 1's order) are `raw2`.
// Per-candidate state for a status page (`code`, 3 bits each):
//   0 / 1 constant level 0 / 1 so far; 2 / 3 (L / H) the level changed between polls (now 0 / 1)
//   but never within one; 4 (T) toggled within a poll at least once; 5 (c) pad-like but never
//   seen to differ from port 1; 6 (P) port-2 candidate, normal polarity; 7 (Q) inverted.
module pad_scan #(
    parameter integer NC = 29
) (
    input  wire          clk,
    input  wire [NC-1:0] cand,         // candidate pins (asynchronous)
    input  wire          smp,          // the poller samples now (sample `idx`, 0-31)
    input  wire [4:0]    idx,
    input  wire          d1,           // port 1's sample (1 = pressed)
    input  wire          done,         // the poller finished a poll
    output reg  [31:0]   raw2 = 32'd0, // port 2, bit k = sample k, 1 = pressed
    output wire          std2,         // raw2 is a standard pad (and a pin is chosen)
    output reg           sel_v = 1'b0, // a pin is chosen
    output reg  [4:0]    sel = 5'd0,   // its candidate index
    output reg           sel_inv = 1'b0,
    output wire [3*NC-1:0] code
);
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg [NC-1:0] s1 = {NC{1'b1}}, s2 = {NC{1'b1}};
    always @(posedge clk) begin s1 <= cand; s2 <= s1; end

    // per-poll accumulation (sample 0 starts a poll)
    reg [NC-1:0] first = {NC{1'b1}}, tog = 0, okn = 0, oki = 0, eqn = 0, eqi = 0;
    // across polls
    reg [NC-1:0] lvl = {NC{1'b1}}, chg = 0, togs = 0, indep = 0;
    reg [1:0]    cn [0:NC-1], ci [0:NC-1];
    reg          started = 1'b0;               // one poll done: lvl is meaningful
    reg [31:0]   sh = 32'd0;
    wire [NC-1:0] lo = idx >= 5'd12 && idx < 5'd16 ? {NC{1'b1}} : 0;  // expected "not pressed"
    wire [NC-1:0] hi = idx >= 5'd16 ? {NC{1'b1}} : 0;                  // expected "pressed"
    wire [NC-1:0] pn = ~s2, pi = s2;                                   // pressed, per polarity
    wire [NC-1:0] okn_s = ~(lo & pn) & ~(hi & ~pn);
    wire [NC-1:0] oki_s = ~(lo & pi) & ~(hi & ~pi);
    wire [NC-1:0] d1v = {NC{d1}};
    wire          vsel = s2[sel];

    integer c;
    initial for (c = 0; c < NC; c = c + 1) begin cn[c] = 2'd0; ci[c] = 2'd0; end

    // eligible candidates after this poll, and the lowest one
    wire [NC-1:0] pad_n, pad_i, elig;
    genvar g;
    generate for (g = 0; g < NC; g = g + 1) begin : g_c
        assign pad_n[g] = cn[g] == 2'd3;
        assign pad_i[g] = ci[g] == 2'd3;
        assign elig[g]  = (pad_n[g] | pad_i[g]) & indep[g];
        assign code[3*g +: 3] = elig[g] ? (pad_n[g] ? 3'd6 : 3'd7) :
                                (pad_n[g] | pad_i[g]) ? 3'd5 : togs[g] ? 3'd4 :
                                chg[g] ? {2'b01, lvl[g]} : {2'b00, lvl[g]};
    end endgenerate
    reg [4:0] low;
    reg       low_v;
    always @(*) begin
        low = 5'd0; low_v = 1'b0;
        for (c = NC - 1; c >= 0; c = c - 1)
            if (elig[c]) begin low = c[4:0]; low_v = 1'b1; end
    end
    reg       chk = 1'b0;                      // one cycle after `done`: counters updated
    always @(posedge clk) begin
        chk <= done;
        if (smp) begin
            sh <= {sel_inv ? vsel : ~vsel, sh[31:1]};
            if (idx == 5'd0) begin
                first <= s2; tog <= 0;
                okn <= okn_s; oki <= oki_s;
                eqn <= ~(pn ^ d1v); eqi <= ~(pi ^ d1v);
            end else begin
                tog <= tog | (s2 ^ first);
                okn <= okn & okn_s; oki <= oki & oki_s;
                eqn <= eqn & ~(pn ^ d1v); eqi <= eqi & ~(pi ^ d1v);
            end
        end
        if (done) begin
            raw2 <= sh;
            started <= 1'b1;
            lvl <= first;
            if (started) chg <= chg | (first ^ lvl);
            togs <= togs | tog;
            indep <= indep | (okn & ~eqn) | (oki & ~eqi);
            for (c = 0; c < NC; c = c + 1) begin
                cn[c] <= !okn[c] ? 2'd0 : cn[c] == 2'd3 ? 2'd3 : cn[c] + 2'd1;
                ci[c] <= !oki[c] ? 2'd0 : ci[c] == 2'd3 ? 2'd3 : ci[c] + 2'd1;
            end
        end
        // keep the chosen pin while it answers in its polarity; else take the lowest eligible
        if (chk && !(sel_v && elig[sel] && (sel_inv ? pad_i[sel] : pad_n[sel])) && low_v) begin
            sel_v <= 1'b1; sel <= low; sel_inv <= !pad_n[low];
        end
    end
    assign std2 = sel_v && raw2[15:12] == 4'd0 && raw2[31:16] == 16'hFFFF;
endmodule
