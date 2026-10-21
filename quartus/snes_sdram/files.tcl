# Source files of the Super Nt SNES (SA-1) build with ROM in SDRAM, sourced from snes_sdram.qsf.
# The SNES core itself is used straight from the vendor checkout (agg23's openfpga-SNES, srg320's
# MiSTer SNES core, GPL-3.0) at ~/src/vendor/openfpga-SNES; nothing is copied into this repo.
# Only what main.v elaborates with USE_SA1 = 1 (other chips 0) is listed.
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
foreach f {SA1/SA1MULT SA1/SA1DIV SA1/SA1 SA1/SA1Map DSP/DSPn DSP/OBC1 DSP/DSP_LHRomMap SRTC RTC4513} {
    set_global_assignment -name VHDL_FILE $U/chip/$f.vhd
}
set_global_assignment -name SYSTEMVERILOG_FILE $U/cheatcodes.sv
set_global_assignment -name VERILOG_FILE $U/main.v

# Ours: snes_video.sv and audio_pll.v used unchanged from quartus/snes, the rest in
# quartus/snes_sdram and quartus/common.
set_global_assignment -name VERILOG_FILE snes_sdram_pll.v
set_global_assignment -name VERILOG_FILE ../snes/audio_pll.v
set_global_assignment -name SYSTEMVERILOG_FILE ../common/i2s_out.sv
set_global_assignment -name SYSTEMVERILOG_FILE ../common/sdram_rom.sv
set_global_assignment -name SYSTEMVERILOG_FILE snes_sdram_core.sv
set_global_assignment -name SYSTEMVERILOG_FILE ../snes/snes_video.sv
set_global_assignment -name SYSTEMVERILOG_FILE snes_sdram_top.sv
