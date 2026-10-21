# SDRAM interface settings for quartus/snes_sdram, sourced by sdram_params.tcl (top-level
# parameters for the .qsf) and snes_sdram.sdc (timing), so this is the one place to change them.
# How to pick them from the hwtest console result: notes/snes-sdram.md, "Capture point".
# Don't edit while Quartus is running: it rereads the .qsf and rewrites it, flattened.
#
# Read-capture point (quartus/common/sdram_rom.sv CAPTURE_HALF), in half cycles after the edge
# that goes with the READ, hwtest's terms: rise n = 2n, fall n.5 = 2n + 1. SA-1 timing allows
# <= 7 (fall 3.5).
set SDRAM_CAPTURE_HALF 7
# Clock phases, in ps, multiples of VCO period/8 = 208.2 ps (notes/snes-sdram.md, "Clocks"):
# controller clock behind clk_sys (the ROM address path needs it), SDRAM clock source ahead of
# clk_sys (moves the read earlier; the command setup at the chips limits it), capture clock
# behind the SDRAM clock source (this offset is what positions the read window; 0 in hwtest).
# All 0 = hwtest's arrangement.
set SDRAM_MEM_LAG_PS 1250
set SDRAM_CLK_LEAD_PS 1041
set SDRAM_CAP_OFFSET_PS 1666
