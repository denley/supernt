# Altera's PLL reconfiguration controller (altera_pll_reconfig), straight from the Quartus
# installation (not copied into this repository): used by common/pll_emul.sv.
set pll_reconfig_ip [file normalize [file join $::quartus(quartus_rootpath) .. ip altera altera_pll_reconfig]]
set_global_assignment -name VERILOG_FILE [file join $pll_reconfig_ip altera_pll_reconfig_top.v]
set_global_assignment -name VERILOG_FILE [file join $pll_reconfig_ip altera_pll_reconfig_core.v]
set_global_assignment -name VERILOG_FILE [file join $pll_reconfig_ip altera_pll_reconfig_mif_reader.v]
