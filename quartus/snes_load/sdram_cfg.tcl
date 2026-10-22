# SDRAM interface settings for quartus/snes_load, sourced by sdram_params.tcl (top-level
# parameters for the .qsf) and snes_load.sdc (timing), so this is the one place to change them.
# Controller at 107.21 MHz = 5 x clk_sys (notes/snes-load.md, "SDRAM"). Don't edit while Quartus
# is running: it rereads the .qsf and rewrites it, flattened.
#
# Read-capture point (quartus/common/sdram_rom8.sv CAPTURE_HALF), in half cycles after the edge
# that goes with the READ (hwtest's terms: rise n = 2n, fall n.5 = 2n + 1). 8 = rise 4: with
# the capture clock 0.83 ns behind the SDRAM clock source it takes the byte for board delays
# D = 2.8-9.4 ns (datasheet tAC/tOH at CL3); hwtest v2/v3 found chip B clean at fall 3.5 and
# rise 4 at 74.25 MHz, i.e. D = 4.0-8.1 ns. The SA-1 takes the byte 2 cycles later.
set SDRAM_CAPTURE_HALF 8
# Clock phases, in ps, multiples of VCO period/8 = 166.6 ps: controller clock aligned with
# clk_sys (the address has two cycles), SDRAM clock source one step ahead (only so that Quartus
# keeps it a separate PLL output: with equal phases it merges it with the controller clock and
# the SDC's clock names go away; the commands have half a cycle to the chips), capture clock
# behind the SDRAM clock source (positions the read window).
set SDRAM_MEM_LAG_PS 0
set SDRAM_CLK_LEAD_PS 167
set SDRAM_CAP_OFFSET_PS 833
