// Simulation stand-ins for quartus/hwtest: PLL (12.288 MHz from the testbench) and DDIO.
`timescale 1ns/1ps
module audio_pll (input wire refclk, output wire outclk_0, output wire locked);
    assign outclk_0 = tb.mclk;
    assign locked = 1'b1;
endmodule

module altddio_out #(
    parameter extend_oe_disable = "OFF", intended_device_family = "", invert_output = "OFF",
    lpm_hint = "", lpm_type = "", oe_reg = "", power_up_high = "OFF", width = 1
) (
    input  wire [width-1:0] datain_h, datain_l,
    input  wire outclock, aclr, aset, oe, outclocken, sclr, sset,
    output wire oe_out,
    output wire [width-1:0] dataout
);
    assign dataout = outclock ? datain_h : datain_l;
endmodule

// video_pll stand-in: locks 2000 reference cycles after reset (none without a reference),
// outclk_0 = 148.5 MHz while locked; reconfiguration port: [16] locked, [17] phase_done.
module video_pll (
    input  wire refclk, rst,
    output reg  outclk_0 = 1'b0,
    output wire outclk_1, outclk_2,
    output wire locked,
    input  wire [63:0] reconfig_to_pll,
    output wire [63:0] reconfig_from_pll
);
    integer n = 0;
    always @(posedge refclk or posedge rst) n <= rst ? 0 : (n < 2000 ? n + 1 : n);
    assign locked = n >= 2000;
    always #3.367 if (locked) outclk_0 = ~outclk_0;
    reg o1 = 1'b0;
    always #23.148 if (locked) o1 = ~o1;
    assign outclk_1 = o1;
    assign outclk_2 = outclk_0;
    assign reconfig_from_pll = {46'd0, 1'b1, locked, 16'd0};
endmodule

// Cyclone V LUT for altera_pll_reconfig_core's fPLL-position probe.
module cyclonev_lcell_comb #(parameter lut_mask = 64'h0, parameter dont_touch = "off")
    (input dataa, datab, datac, datad, datae, dataf, output combout);
    assign combout = lut_mask[{dataf, datae, datad, datac, datab, dataa}];
endmodule
