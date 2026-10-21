# Timing constraints for quartus/snes (notes/snes-quartus.md, "Clocks").

# 74.25 MHz board clock on W16. It clocks the 720p video logic directly and is the PLL reference.
create_clock -name clk -period 13.468 [get_ports clk]
derive_pll_clocks
derive_clock_uncertainty

# The SNES clock (fractional PLL output, 21.477 MHz) and the video clock are unrelated in phase:
# only a toggle synchroniser, a static mode bit and the dual-clock line buffer cross between
# them.
set clk_sys [get_clocks {pll|altera_pll_i|*[0].*|divclk}]
set_clock_groups -asynchronous -group [get_clocks clk] -group $clk_sys

# Pixel clock to the AD9889B: DDIO output (0 in the high half, 1 in the low half), i.e. the
# inverted board clock, forwarded through the same kind of I/O path as the data.
create_generated_clock -name pclk_out -source [get_ports clk] -invert [get_ports pclk]

# AD9889B input timing: data/sync setup and hold around the rising pixel-clock edge. The
# datasheet values are not at hand; 1.5 ns setup / 1.0 ns hold is assumed (conservative for a
# 165 MHz part). The data changes on the clk rising edge, half a period before pclk rises.
set video_out [get_ports {ch1[*] ch2[*] ch3[*] s0 s1 s2}]
set_output_delay -clock pclk_out -max 1.5 $video_out
set_output_delay -clock pclk_out -min -1.0 $video_out
