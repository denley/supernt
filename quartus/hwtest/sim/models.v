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
