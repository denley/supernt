// SPDX-License-Identifier: GPL-3.0-or-later
// Stand-in for spc.cor's video-PLL reconfiguration block (notes/pic-link.md, "Status
// 0x2004_0000"): a real reconfigurable fPLL like spc's FPLL.000.037 (video_pll: H16 reference,
// 74.25 MHz x 16 = 1188 MHz VCO, 148.5 / 21.6 / 148.5 MHz) behind Altera's PLL reconfiguration
// controller (altera_pll_reconfig_top, the IP the stock block was built from: its 340-clock
// self-reset plus the 64-write DPRIO init are the "~410 clocks" timer of the decode), driven by
// the PIC's link writes at the decoded addresses:
//   0x1000_00C4: D0 = reconfig controller reset (mgmt_reset), D1 = PLL reset
//   0x1000_0500-05FF: 64 x 32-bit controller registers; each byte lands in a lane register by
//     address bits 1-0, and the byte at bits 1-0 = 3 commits the word to register addr[7:2]
//     (an Avalon write, held until waitrequest drops)
// status = {locked (synchronised), waitrequest}: bits 1 and 0 of the stock 0x2xx4_xxxx read.
// Idle (locked, controller out of reset, either mode) = 2'b10 = 0x02.
// The PLL's output and reference frequencies are measured against clk (counts per 1 ms) so the
// screen shows whether H16 runs and whether the PIC reprograms the PLL.
module pll_emul (
    input  wire        clk,             // 74.25 MHz: link logic and mgmt_clk
    input  wire        refclk,          // H16
    input  wire        wr,              // a data write (A=2) from the link
    input  wire [31:0] wa,
    input  wire [7:0]  wd,
    output wire [1:0]  status,          // {locked, waitrequest}
    output reg  [7:0]  n_cmt = 8'd0,    // register commits
    output reg  [5:0]  last_reg = 6'd0,
    output reg  [31:0] last_data = 32'd0,
    output reg  [7:0]  n_c4 = 8'd0,     // writes to 0x1000_00C4
    output reg  [7:0]  c4 = 8'd0,       // last value written there
    output reg  [23:0] out_per_ms = 24'd0, // outclk0 cycles per ms (148.5 MHz: 0x024414)
    output reg  [23:0] ref_per_ms = 24'd0, // H16 cycles per ms (74.25 MHz: 0x01220A)
    output reg  [23:0] out1_per_ms = 24'd0, // outclk1 cycles per ms (21.6 MHz: 0x005460)
    output wire        busy_now,        // a committed write is still waiting
    output reg         wait_low = 1'b0, // waitrequest has been 0 at some point (v3: stuck at 1?)
    output reg  [7:0]  cmt_wlow = 8'd0  // commits accepted (waitrequest low while writing)
);
    // ------------------------------------------------------------ PIC writes -> Avalon-MM
    reg  [7:0]  lane0 = 8'd0, lane1 = 8'd0, lane2 = 8'd0;
    reg         m_wr = 1'b0;
    reg  [5:0]  m_addr = 6'd0;
    reg  [31:0] m_data = 32'd0;
    wire        m_wait;
    wire        in_win = wa[31:8] == 24'h100005;
    always @(posedge clk) begin
        if (m_wr && !m_wait) m_wr <= 1'b0;
        if (wr && wa == 32'h1000_00C4) begin
            c4   <= wd;
            n_c4 <= n_c4 + 8'd1;
        end
        if (wr && in_win) begin
            case (wa[1:0])
                2'd0: lane0 <= wd;
                2'd1: lane1 <= wd;
                2'd2: lane2 <= wd;
                2'd3: begin
                    m_wr      <= 1'b1;          // a new commit replaces one still waiting
                    m_addr    <= wa[7:2];
                    m_data    <= {wd, lane2, lane1, lane0};
                    n_cmt     <= n_cmt + 8'd1;
                    last_reg  <= wa[7:2];
                    last_data <= {wd, lane2, lane1, lane0};
                end
            endcase
        end
    end
    assign busy_now = m_wr;

    // ------------------------------------------------------------ PLL + reconfiguration IP
    wire [63:0] to_pll, from_pll;
    wire        locked;
    wire [2:0]  outclk;
    video_pll vpll (
        .refclk(refclk), .rst(c4[1]), .outclk_0(outclk[0]), .outclk_1(outclk[1]),
        .outclk_2(outclk[2]), .locked(locked), .reconfig_to_pll(to_pll),
        .reconfig_from_pll(from_pll));
    altera_pll_reconfig_top #(
        .device_family("Cyclone V"), .reconf_width(64), .ENABLE_MIF(0),
        .ENABLE_BYTEENABLE(0), .WAIT_FOR_LOCK(1)
    ) recfg (
        .mgmt_clk(clk), .mgmt_reset(c4[0]), .reconfig_to_pll(to_pll),
        .reconfig_from_pll(from_pll), .mgmt_readdata(), .mgmt_waitrequest(m_wait),
        .mgmt_address(m_addr), .mgmt_read(1'b0), .mgmt_write(m_wr), .mgmt_writedata(m_data),
        .mgmt_byteenable(4'hf));

    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg [2:0] lk_s = 3'd0;
    always @(posedge clk) begin
        lk_s <= {lk_s[1:0], locked};
        if (!m_wait) wait_low <= 1'b1;
        if (m_wr && !m_wait) cmt_wlow <= cmt_wlow + 8'd1;
    end
    assign status = {lk_s[2], m_wait};

    // ------------------------------------------------------------ frequency counters
    // Gray-coded free-running counters in the measured domains, sampled every 1 ms of clk.
    // (Counting outclk1 also makes Quartus keep it, so the VCO is spc's 1188 MHz.)
    reg [23:0] og = 24'd0, rg = 24'd0, pg = 24'd0;  // gray counters
    reg [23:0] ob = 24'd0, rb = 24'd0, pb = 24'd0;  // binary
    always @(posedge outclk[0]) begin
        ob <= ob + 24'd1;
        og <= (ob + 24'd1) ^ ((ob + 24'd1) >> 1);
    end
    always @(posedge outclk[1]) begin
        pb <= pb + 24'd1;
        pg <= (pb + 24'd1) ^ ((pb + 24'd1) >> 1);
    end
    always @(posedge refclk) begin
        rb <= rb + 24'd1;
        rg <= (rb + 24'd1) ^ ((rb + 24'd1) >> 1);
    end
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg [23:0] og1 = 24'd0, og2 = 24'd0, rg1 = 24'd0, rg2 = 24'd0, pg1 = 24'd0, pg2 = 24'd0;
    always @(posedge clk) begin
        og1 <= og; og2 <= og1;
        rg1 <= rg; rg2 <= rg1;
        pg1 <= pg; pg2 <= pg1;
    end
    function [23:0] g2b(input [23:0] g);
        integer i;
        begin
            g2b[23] = g[23];
            for (i = 22; i >= 0; i = i - 1) g2b[i] = g2b[i+1] ^ g[i];
        end
    endfunction
    reg [16:0] ms = 17'd0;
    reg [23:0] o_prev = 24'd0, r_prev = 24'd0, p_prev = 24'd0;
    always @(posedge clk) begin
        ms <= ms == 17'd74249 ? 17'd0 : ms + 17'd1;
        if (ms == 17'd0) begin
            out_per_ms <= g2b(og2) - o_prev;
            ref_per_ms <= g2b(rg2) - r_prev;
            out1_per_ms <= g2b(pg2) - p_prev;
            o_prev <= g2b(og2);
            r_prev <= g2b(rg2);
            p_prev <= g2b(pg2);
        end
    end
endmodule
