# Source files of quartus/snes_load (SNES + SA-1, ROM loaded over the PIC32 link into SDRAM),
# sourced from snes_load.qsf. The SNES core is used straight from the vendor checkout (agg23's
# openfpga-SNES, srg320's MiSTer SNES core, GPL-3.0) at ~/src/vendor/openfpga-SNES; only what
# main.v elaborates with USE_SA1 = 1 (and the Lo/HiROM mapper) is listed.
set U ../../../vendor/openfpga-SNES/rtl/upstream

foreach f {P65816_pkg AddrGen BCDAdder AddSubBCD ALU MCode P65C816} {
    set_global_assignment -name VHDL_FILE $U/65C816/$f.vhd
}
foreach f {SPC700_pkg AddrGen AddSub ALU BCDAdj MCode MulDiv SPC700} {
    set_global_assignment -name VHDL_FILE $U/SPC700/$f.vhd
}
foreach f {bram mlab CEGen DSP_PKG DSP SMP PPU_PKG PPU CPU SWRAM SNES} {
    set_global_assignment -name VHDL_FILE $U/$f.vhd
}
foreach f {SA1/SA1MULT SA1/SA1DIV SA1/SA1Map DSP/DSPn DSP/OBC1 DSP/DSP_LHRomMap SRTC RTC4513} {
    set_global_assignment -name VHDL_FILE $U/chip/$f.vhd
}
# SA1.vhd with quartus/snes_load/sa1_vbp.patch (made by `make`: build/snes_load/SA1.vhd)
set_global_assignment -name VHDL_FILE ../../build/snes_load/SA1.vhd
# The GSU from build/snes_load (all three files, so Quartus never reads the vendor directory's
# unpatched GSU.vhd): GSU.vhd with quartus/snes_load/gsu_rom_hold.patch, GSU_PKG and GSUMap copied
set_global_assignment -name VHDL_FILE ../../build/snes_load/GSU_PKG.vhd
set_global_assignment -name VHDL_FILE ../../build/snes_load/GSU.vhd
set_global_assignment -name VHDL_FILE ../../build/snes_load/GSUMap.vhd
set_global_assignment -name SYSTEMVERILOG_FILE $U/cheatcodes.sv
set_global_assignment -name VERILOG_FILE $U/main.v

# Ours: the core wrapper from quartus/snes_sdram, video and audio PLL from quartus/snes.
set_global_assignment -name VERILOG_FILE ../snes_load/snes_load_pll.v
set_global_assignment -name VERILOG_FILE ../snes/audio_pll.v
set_global_assignment -name SYSTEMVERILOG_FILE ../common/i2s_out.sv
set_global_assignment -name SYSTEMVERILOG_FILE ../common/sdram_rom8.sv
set_global_assignment -name SYSTEMVERILOG_FILE ../common/link_ui.sv
set_global_assignment -name SYSTEMVERILOG_FILE ../common/rom_loader.sv
set_global_assignment -name SYSTEMVERILOG_FILE ../common/pad_poll.sv
set_global_assignment -name SYSTEMVERILOG_FILE ../common/overlay.sv
set_global_assignment -name SYSTEMVERILOG_FILE ../snes_sdram/snes_sdram_core.sv
set_global_assignment -name SYSTEMVERILOG_FILE ../snes/snes_video.sv
set_global_assignment -name SYSTEMVERILOG_FILE ../snes_load/snes_load_top.sv
