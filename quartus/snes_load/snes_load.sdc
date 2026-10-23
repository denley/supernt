# Timing constraints for quartus/snes_load (notes/snes-load.md, "SDRAM" and "Timing"). The SDRAM
# interface constraints follow quartus/snes_sdram's (notes/snes-sdram.md); the controller runs
# at 5 x clk_sys here.

# 74.25 MHz board clock on W16: 720p video logic and PLL reference.
create_clock -name clk -period 13.468 [get_ports clk]
derive_pll_clocks

# clk_sys (21.44196 MHz, PLL output 0), clk_mem (5 x, output 1, the SDRAM controller), clk_sd
# (output 2, source of the SDRAM clock) and clk_cap (output 3, the read-capture register) come
# from one VCO (750.47 MHz), so they are related. Phases relative to clk_sys (sdram_cfg.tcl):
# clk_mem +SDRAM_MEM_LAG_PS, clk_sd -SDRAM_CLK_LEAD_PS, clk_cap SDRAM_CAP_OFFSET_PS after clk_sd.
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

# ---------------------------------------------------------------- clk_sys -> controller
# sdram_rom8.sv numbers the clk_mem edges after a clk_sys edge E as k = 0 (E itself) to 4. Only
# tog_d takes a clk_sys signal (sys_tog) at k = 1 (the default analysis: setup at the next edge,
# hold at E). Everything else the controller takes from the core (ROM address, rom_word,
# rfsh_ok) is used at k >= 2 only: no ROM read starts and no address register loads at k = 0
# and 1, and refresh slots are k = 2-4. So setup at k = 2 (-end 2) and the hold check back at
# k = 0 (-hold -end 1: the edge where the old value is still there by definition).
set mem_regs [remove_from_collection [get_registers {sdram_rom8:sdram|*}] [get_registers {sdram_rom8:sdram|tog_d}]]
set_multicycle_path -setup -end 2 -from $clk_sys -to $mem_regs
set_multicycle_path -hold -end 1 -from $clk_sys -to $mem_regs
# The SNES CPU's live address (SCPU) reaches the ROM address only through SA1.vhd's
# SNES_ROM_SEL = SNES_ROM_ACCESS(SNES_A) and not WINDOW: the CPU address changes only at a
# SYSCLKF edge, where WINDOW goes to 1 in the same edge, and WINDOW goes back to 0 only at a later
# SA-1 CE edge (>= 1 clk_sys cycle on), so SNES_A -> controller paths have at least one more
# clk_mem cycle (notes/snes-sdram.md). The SA-1's own address and WINDOW keep the check above.
set_multicycle_path -setup -end 3 -from [get_registers {snes_sdram_core:snes|main:main|SNES:SNES|SCPU:CPU|*}] -to $mem_regs
set_multicycle_path -hold -end 2 -from [get_registers {snes_sdram_core:snes|main:main|SNES:SNES|SCPU:CPU|*}] -to $mem_regs

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
# The capture register (cap, clk_cap) samples the byte launched by SDRAM edge READ + (CL - 1), at
# SDRAM_CAPTURE_HALF half cycles after the clk_cap edge that goes with the READ's clk_mem edge;
# the default analysis latches at the next clk_cap edge of the register's polarity after the
# launch, the multicycle moves that to the real capture edge (formula as quartus/snes_sdram).
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
# rom_q comes from cap: for a read whose address changed at E (ACT at k = 2, READ at k = 4) cap
# loads at k = 4 + h/2 (+ the clk_cap phase) and the core uses it at E + 10 (the SA-1 / SNES CPU
# take ROM data 2 clk_sys after the address change). The default analysis assumes a launch at the
# last clk_cap edge before a clk_sys edge (one clk cycle); -start moves it back to the real one.
# Reads delayed by a refresh land later; the core then has latched late data anyway (n_late).
# (CAPTURE_HALF 8 or 9 only: earlier, the second byte of an even read would replace byte A in cap
# before E + 10; later, the core's data path gets less than 1.5 cycles.)
set m [expr {$h % 2 == 0 ? 6 - $h / 2 : 1}]
if {$m > 1} {
    set_multicycle_path -setup -start -from $cap -to $clk_sys $m
    set_multicycle_path -hold -start -from $cap -to $clk_sys [expr {$m - 1}]
}
# The low lane's copy (cap_lo) and select (lo_sel) change at k = 3 of a read (select cleared;
# cap gets the new byte at k = 8) and at k = 10 (copy; the core took byte A at that same edge, and
# the next use is 2 clk_sys later): one clk_sys cycle more than the default.
# v2: the same holds for rom_q's high-lane hold (hold_sel, cap_hold: change at k = 2 or 3) and the
# ARAM byte (ar_q: changes at k = 1 or 3; the S-DSP takes it >= 5 clk_sys after the address).
set lo_regs [get_registers {*sdram|lo_sel *sdram|cap_lo[*] *sdram|hold_sel *sdram|cap_hold[*] *sdram|ar_q[*]}]
set_multicycle_path -setup -end 2 -from $lo_regs -to $clk_sys
set_multicycle_path -hold -end 1 -from $lo_regs -to $clk_sys
# ar_q (k = 3) -> the S-DSP/SPC700's combinational outputs -> the controller's ARAM port, which it
# samples only at k = 2 of the next clk_sys cycle (4 cycles on).
set_multicycle_path -setup -end 4 -from [get_registers {*sdram|ar_q[*]}] -to $mem_regs
set_multicycle_path -hold -end 3 -from [get_registers {*sdram|ar_q[*]}] -to $mem_regs
# AB10 (chip B's DQM) is a constant.
set_false_path -to [get_ports {sd_dqm_b}]

# Mapper settings from the loader (rom_loader.sv) change only while the core is held in reset
# (and ROM reads are off): static for timing.
set_false_path -from [get_registers {rom_loader:ld|rom_type[*] rom_loader:ld|rom_mask[*] rom_loader:ld|ram_mask[*] rom_loader:ld|sa1}]

# PIC32 link: asynchronous strobes and data, sampled through 2-FF synchronisers (link_ui.sv); the
# PIC reads the data bus long after it is driven (>= 3 link-clock cycles in the stock core).
set_false_path -from [get_ports {link_a[*] link_nrd link_nwr link_d[*]}]
set_false_path -to [get_ports {link_d[*]}]

# ---------------------------------------------------------------- video, audio, pad (as snes.sdc)
create_generated_clock -name pclk_out -source [get_ports clk] -invert [get_ports pclk]
set video_out [get_ports {ch1[*] ch2[*] ch3[*] s0 s1 s2}]
set_output_delay -clock pclk_out -max 1.5 $video_out
set_output_delay -clock pclk_out -min -1.0 $video_out
set_false_path -to [get_ports {aud_mclk aud_bclk aud_lrclk aud_sdata}]
set_false_path -to [get_ports {pad_p14 pad_j13 pad_k16}]
set_false_path -from [get_ports {pad_t12 pad_d6}]

derive_clock_uncertainty
