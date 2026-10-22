# Sourced from snes_load.qsf: top-level parameters from sdram_cfg.tcl (the .qsf itself doesn't
# expand Tcl variables, sourced files do). PLL phases as strings, relative to clk_sys, in
# [0, period).
source sdram_cfg.tcl
set_parameter -name CAPTURE_HALF $SDRAM_CAPTURE_HALF
set sd_period_ps 9327
set_parameter -name MEM_PHASE "$SDRAM_MEM_LAG_PS ps"
set_parameter -name SD_PHASE "[expr {($sd_period_ps - $SDRAM_CLK_LEAD_PS) % $sd_period_ps}] ps"
set_parameter -name CAP_PHASE "[expr {($SDRAM_CAP_OFFSET_PS - $SDRAM_CLK_LEAD_PS + $sd_period_ps) % $sd_period_ps}] ps"
