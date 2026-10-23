# Timing constraints for quartus/memtest.
create_clock -name clk -period 13.468 [get_ports clk]
derive_clock_uncertainty
set_clock_uncertainty -add -hold -enable_same_physical_edge -from [get_clocks clk] -to [get_clocks clk] 0.05

# Video out to the AD9889B, as quartus/hwtest.
create_generated_clock -name pclk_out -source [get_ports clk] -invert [get_ports pclk]
set video_out [get_ports {ch1[*] ch2[*] ch3[*] s0 s1 s2}]
set_output_delay -clock pclk_out -max 1.5 $video_out
set_output_delay -clock pclk_out -min -1.0 $video_out
# SDRAM tests: both read-capture at four points chosen on hardware (sdram_test.sv,
# mem2_test.sv), so the SDRAM interfaces are not timed here; commands and write data change half
# a clock before the chips sample them (inverted clock on AB11 / H8).
set_false_path -to [get_ports {sd_cs_n sd_ras_n sd_cas_n sd_we_n sd_a[*] sd_ba[*] sd_dq[*] sd_cke sd_clk}]
set_false_path -from [get_ports {sd_dq[*]}]
set_false_path -to [get_ports {m_clk m_a[*] m_a11 m_ba[*] g1_cs_n g1_ras_n g1_cas_n g1_we_n g1_a10}]
set_false_path -to [get_ports {g2_cs_n g2_ras_n g2_cas_n g2_we_n g2_a10 g1_dq[*] g2_dq[*]}]
set_false_path -from [get_ports {g1_dq[*] g2_dq[*]}]
# static levels
set_false_path -to [get_ports {tie3[*] tie_hold[*] m_c13 m_c15}]
set_false_path -from [get_ports {m_c13 m_c15}]
