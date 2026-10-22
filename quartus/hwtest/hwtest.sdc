# Timing constraints for quartus/hwtest.
create_clock -name clk -period 13.468 [get_ports clk]
create_clock -name h16 -period 13.468 [get_ports h16]
derive_pll_clocks
derive_clock_uncertainty
# 50 ps of extra hold margin inside the board clock domain: v5's first build missed hold by
# 1 ps in the fast corner (a register into an M10K data input, 0.4 ns clock skew), so the
# fitter's hold fixing gets a target with some room.
set_clock_uncertainty -add -hold -enable_same_physical_edge -from [get_clocks clk] -to [get_clocks clk] 0.05

# The audio clock (12.288 MHz PLL), H16 and the video-PLL stand-in's outputs only exchange slow
# status bits (synchronisers, Gray-coded counters) with the board clock domain.
set mclk [get_clocks {apll|altera_pll_i|*[0].*|divclk}]
set vclk [get_clocks {emu|vpll|altera_pll_i|*|divclk}]
set_clock_groups -asynchronous -group [get_clocks clk] -group $mclk -group [get_clocks h16] -group $vclk

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
# Controller port: microsecond-scale signals.
set_false_path -to [get_ports {pad_p14 pad_j13 pad_k16}]
set_false_path -from [get_ports {pad_t12}]
# SDRAM test: the read-capture point is chosen on hardware (sdram_test.sv tries eight), so the
# SDRAM interface is not timed here; commands and write data change half a clock before the
# chips sample them (inverted clock on AB11).
set_false_path -to [get_ports {sd_cs_n sd_ras_n sd_cas_n sd_we_n sd_a[*] sd_ba[*] sd_dq[*] sd_cke sd_dqm[*] sd_clk}]
set_false_path -from [get_ports {sd_dq[*]}]
# spc.cor's constant pins (static levels, switched once per SDRAM pass).
set_false_path -to [get_ports {tie3[*] tie_hold[*]}]
