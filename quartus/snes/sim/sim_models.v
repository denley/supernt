// SPDX-License-Identifier: GPL-3.0-or-later
// Simulation stand-ins for the Altera primitives and the parts of the core the simulation
// leaves out (quartus/snes/sim).

// PLL: the testbench drives the SNES clock (tb.clk_sys) itself.
module snes_pll (
    input  wire refclk,
    input  wire rst,
    output wire outclk_0,
    output wire locked
);
    assign outclk_0 = tb.clk_sys;
    assign locked   = 1'b1;
endmodule

// DDIO output: datain_h while outclock is high, datain_l while it is low (registered on the
// respective edges in the real cell; the difference doesn't matter here).
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

// Game Genie (cheatcodes.sv): never loaded in this build (GG_EN = 0, no codes), so it never
// overrides the bus.
module CODES #(parameter ADDR_WIDTH = 16, parameter DATA_WIDTH = 8, parameter MAX_CODES = 32) (
    input  wire                  clk, reset, enable,
    output wire                  available,
    input  wire [ADDR_WIDTH-1:0] addr_in,
    input  wire [DATA_WIDTH-1:0] data_in,
    input  wire [128:0]          code,
    output wire                  genie_ovr,
    output wire [DATA_WIDTH-1:0] genie_data
);
    assign available  = 1'b0;
    assign genie_ovr  = 1'b0;
    assign genie_data = data_in;
endmodule
