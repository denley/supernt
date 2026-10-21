# Timing constraints for quartus/snes_sdram (notes/snes-sdram.md, "Timing").

# 74.25 MHz board clock on W16: 720p video logic and PLL reference.
create_clock -name clk -period 13.468 [get_ports clk]
derive_pll_clocks

# clk_sys (21.44196 MHz, PLL output 0), clk_mem (4 x, output 1, the SDRAM controller), clk_sd
# (output 2, source of the SDRAM clock) and clk_cap (output 3, the read-capture register) come
# from one VCO, so they are related. Phases relative to clk_sys (sdram_cfg.tcl): clk_mem
# +SDRAM_MEM_LAG_PS, clk_sd -SDRAM_CLK_LEAD_PS, clk_cap SDRAM_CAP_OFFSET_PS after clk_sd.
source sdram_cfg.tcl
set clk_sys_pin {pll|altera_pll_i|*[0].*|divclk}
set clk_mem_pin {pll|altera_pll_i|*[1].*|divclk}
set clk_sd_pin  {pll|altera_pll_i|*[2].*|divclk}
set clk_cap_pin {pll|altera_pll_i|*[3].*|divclk}
set clk_sys [get_clocks $clk_sys_pin]
set clk_mem [get_clocks $clk_mem_pin]
set mclk [get_clocks {apll|altera_pll_i|*[0].*|divclk}]

# SDRAM clock on AB11: DDIO output (0 in the high half, 1 in the low half of clk_sd), i.e. the
# inverted clk_sd. The analyser follows the DDIO clock-to-pin path as the clock's latency.
create_generated_clock -name sd_clk_out -source [get_pins -compatibility_mode $clk_sd_pin] \
    -invert [get_ports sd_clk]

set_clock_groups -asynchronous -group [get_clocks clk] \
    -group [get_clocks [list $clk_sys_pin $clk_mem_pin $clk_sd_pin $clk_cap_pin sd_clk_out]] \
    -group $mclk

# clk_sys -> clk_mem (ROM address, phase toggle, refresh hint): sdram_rom.sv expects the clk_mem
# edge right after a clk_sys edge E to see the old values and acts on them one clk_mem cycle
# later. With clk_mem late by the lag, the default analysis would latch at E + lag; this moves
# setup to E + period + lag, and the hold check (no hold multicycle) to E + lag: the edge there
# must still see the old value, i.e. every clk_sys -> clk_mem path is longer than the lag (the
# fitter pads the short ones). With no lag the defaults are already right.
if {$SDRAM_MEM_LAG_PS > 0} {
    set_multicycle_path -setup -end 2 -from $clk_sys -to $clk_mem
    # The fitter pads those paths only to ~0 slack, and paths into I/O-cell registers can end
    # slightly short; ask it for 0.15 ns more (fitter only, the timing analyser checks the real
    # requirement).
    if {$::quartus(nameofexecutable) eq "quartus_fit"} {
        set_clock_uncertainty -hold -add -from $clk_sys -to $clk_mem 0.15
    }
}
# The SNES CPU's live address (SCPU) reaches the ROM address only through SA1.vhd's
# SNES_ROM_SEL = SNES_ROM_ACCESS(SNES_A) and not WINDOW: the CPU address changes only at a
# SYSCLKF edge, where WINDOW goes to 1 in the same edge, and WINDOW goes back to 0 only at a later
# SA-1 CE edge (>= 1 clk_sys cycle on), so SNES_A -> controller paths have at least one more
# clk_mem cycle (more like 4). The SA-1's own address and the WINDOW register keep the
# one-cycle check above.
set_multicycle_path -setup -end [expr {$SDRAM_MEM_LAG_PS > 0 ? 3 : 2}] \
    -from [get_registers {snes_sdram_core:snes|main:main|SNES:SNES|SCPU:CPU|*}] \
    -to [get_registers {sdram_rom:sdram|*}]

# ---------------------------------------------------------------- SDRAM (IS42S81600F-6)
# Board traces are not known; equal clock and data traces (0.5 ns each) are assumed.
set sd_trace 0.5
# Commands, address and write data: tIS 1.5 ns setup, tIH 0.8 ns hold at the chips. Launched on
# a clk_mem rising edge, sampled by the next sd_clk_out rising edge (half a cycle minus the
# controller lag and the SDRAM clock lead).
set sd_out [get_ports {sd_cs_n sd_ras_n sd_cas_n sd_we_n sd_a[*] sd_ba[*] sd_dq[*]}]
set_output_delay -clock sd_clk_out -max 1.5 $sd_out
set_output_delay -clock sd_clk_out -min -0.8 $sd_out
# Read data: valid from tAC (5.4 ns) after an SDRAM clock edge until tOH (2.7 ns) after the next
# one, plus the clock trace out and the data trace back.
set_input_delay -clock sd_clk_out -max [expr {5.4 + 2 * $sd_trace}] [get_ports {sd_dq[*]}]
set_input_delay -clock sd_clk_out -min [expr {2.7 + 2 * $sd_trace}] [get_ports {sd_dq[*]}]
# The capture register (clk_cap) samples the word launched by SDRAM edge READ + (CL - 1), at
# CAPTURE_HALF half cycles after the clk_cap edge that goes with the READ's clk_mem edge; the
# launch is 2.5 cycles minus SDRAM_CAP_OFFSET_PS after that clk_cap edge. The default analysis
# latches at the next clk_cap edge of the register's polarity after the launch; the multicycle
# moves that to the real capture edge. The data changes every
# cycle, so the hold check moves along (no hold multicycle): the next word must not reach the
# register before the capture edge.
set h $SDRAM_CAPTURE_HALF
if {$h % 2 == 0} {
    set n [expr {($h - 4) / 2}]
} elseif {$SDRAM_CAP_OFFSET_PS > 0} {
    set n [expr {($h - 3) / 2}]
} else {
    set n [expr {($h - 5) / 2}]
}
set cap [get_registers {*sdram|cap[*]}]
if {$n != 1} {
    set_multicycle_path -setup -from [get_clocks sd_clk_out] -to $cap $n
}
# rom_q comes straight from the capture register. For a read that starts right after the
# address change at clk_sys edge E (every latency-critical one) the register loads at
# E + (3 + h/2) cycles + the clk_cap phase and the core uses the data at E + 8 cycles. The default
# analysis assumes the nearest clk_sys edge (half a cycle after a falling-edge register, one
# cycle after a rising-edge one); the multicycle (in clk_mem cycles, -start) moves the launch
# back to the real one. Reads delayed by a refresh or a pending read land at other phases; the
# SA-1 has already latched (late data, counted in n_late) and the SNES CPU waits longer. The
# register holds its word for >= 6 cycles, so the hold check stays at the default edge.
if {$h % 2 == 1} { set m [expr {(11 - $h) / 2}] } else { set m [expr {(10 - $h) / 2}] }
if {$m > 1} {
    set_multicycle_path -setup -start -from $cap -to $clk_sys $m
    set_multicycle_path -hold -start -from $cap -to $clk_sys [expr {$m - 1}]
}
# CKE and the DQM candidates are constants.
set_false_path -to [get_ports {sd_cke sd_dqm[*]}]

# ---------------------------------------------------------------- video, audio, pad (as snes.sdc)
create_generated_clock -name pclk_out -source [get_ports clk] -invert [get_ports pclk]
set video_out [get_ports {ch1[*] ch2[*] ch3[*] s0 s1 s2}]
set_output_delay -clock pclk_out -max 1.5 $video_out
set_output_delay -clock pclk_out -min -1.0 $video_out
set_false_path -to [get_ports {aud_mclk aud_bclk aud_lrclk aud_sdata}]
set_false_path -to [get_ports {pad_p14 pad_j13 pad_k16}]
set_false_path -from [get_ports {pad_t12}]

derive_clock_uncertainty
