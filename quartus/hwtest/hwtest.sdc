# Timing constraints for quartus/hwtest.
create_clock -name clk -period 13.468 [get_ports clk]
derive_pll_clocks
derive_clock_uncertainty

# The audio clock (12.288 MHz PLL) and the board clock only exchange slow status bits through
# synchronisers.
set mclk [get_clocks {apll|altera_pll_i|*[0].*|divclk}]
set_clock_groups -asynchronous -group [get_clocks clk] -group $mclk

# Video out to the AD9889B, as quartus/snes/snes.sdc.
create_generated_clock -name pclk_out -source [get_ports clk] -invert [get_ports pclk]
set video_out [get_ports {ch1[*] ch2[*] ch3[*] s0 s1 s2}]
set_output_delay -clock pclk_out -max 1.5 $video_out
set_output_delay -clock pclk_out -min -1.0 $video_out
# Audio outputs: BCLK/LRCLK/data are plain registered outputs sampled by the AD9889B on BCLK,
# hundreds of ns of margin; MCLK is a DDIO copy of the PLL clock.
set_false_path -to [get_ports {aud_bclk aud_lrclk aud_sdata aud_mclk}]
# PIC32 link: asynchronous strobes and data through synchronisers; the data outputs are driven
# for the whole /RD low time (>= 100 ns), so no output timing applies.
set_false_path -from [get_ports {link_a[*] link_nrd link_nwr link_d[*]}]
set_false_path -to [get_ports {link_d[*]}]
