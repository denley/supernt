# Settings shared by every Quartus-built Super Nt core (sourced from each .qsf).
# Output format matches what the jailbreak loads: uncompressed raw .rbf (made into a .cor by
# plain bit reversal, tools/bitrev.py), JTAG user code as in spc.cor.
set_global_assignment -name GENERATE_RBF_FILE ON
set_global_assignment -name ON_CHIP_BITSTREAM_DECOMPRESSION OFF
set_global_assignment -name USE_CHECKSUM_AS_USERCODE OFF
set_global_assignment -name STRATIX_JTAG_USER_CODE 03CBD16E
set_global_assignment -name RESERVE_ALL_UNUSED_PINS_WEAK_PULLUP "AS INPUT TRI-STATED WITH WEAK PULL-UP"
set_global_assignment -name STRATIXV_CONFIGURATION_SCHEME "PASSIVE PARALLEL X8"
set_global_assignment -name CRC_ERROR_OPEN_DRAIN OFF
set_global_assignment -name ENABLE_OCT_DONE OFF
# I/O banks: spc.cor configures every pin it uses as 2.5 V with 50 ohm series termination.
set_global_assignment -name STRATIX_DEVICE_IO_STANDARD "2.5 V"
set_global_assignment -name NUM_PARALLEL_PROCESSORS 4
# Registers power up at their Verilog initial values. With Quartus' default (power-up don't
# care) synthesis may pick any power-up value for a register whose initial value it can
# "simplify" away: hwtest v2 lost first_rd = 11'h7ff (stuck at 0) and cand_locked = 0 (stuck at
# 1, so the answer never stepped); both are listed as "Stuck at" in the map report.
set_global_assignment -name ALLOW_POWER_UP_DONT_CARE OFF
