// SPDX-License-Identifier: GPL-3.0-or-later
// altddio_out stand-in for simulation (iverilog and Verilator): datain_h while outclock is high,
// datain_l while it is low. With datain_h = 0, datain_l = 1 that is the inverted clock.
module altddio_out #(
    parameter extend_oe_disable = "OFF", parameter intended_device_family = "Cyclone V",
    parameter invert_output = "OFF", parameter lpm_hint = "UNUSED",
    parameter lpm_type = "altddio_out", parameter oe_reg = "UNREGISTERED",
    parameter power_up_high = "OFF", parameter width = 1
) (
    input  wire [width-1:0] datain_h, datain_l,
    input  wire             outclock, outclocken, aclr, aset, sclr, sset, oe,
    output wire [width-1:0] dataout,
    output wire             oe_out
);
    assign dataout = outclock ? datain_h : datain_l;
    assign oe_out  = oe;
endmodule
