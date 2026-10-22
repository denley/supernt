# Super Nt reverse engineering: decode and patch jailbreak cores.
# `make` fetches the jailbreak, builds the tools and the test cores.

MISTRAL  := $(HOME)/src/vendor/mistral
MODEL    := 5CEBA4F23C8
JB_ZIP   := https://raw.githubusercontent.com/SmokeMonsterPacks/Super-NT-Jailbreak/master/firmware/snt_firmware_verJB7.2.zip
SPC_COR  := firmware/jb7.2/SYSTEM/CORES/spc.cor
CXXFLAGS := -O2 -std=c++17 -I$(MISTRAL)/libmistral -I$(MISTRAL)/build/libmistral \
            -I$(MISTRAL)/build/tools -I$(MISTRAL)/build -I$(MISTRAL)/mistral-cv
LIBS     := $(MISTRAL)/build/libmistral/libmistral.a -llzma

# Open-source flow for our own cores (notes/toolchain.md): yosys + nextpnr-mistral.
# nextpnr needs an older mistral than tools/: its nextpnr-latest branch (6a97d3e); master renamed the API.
NEXTPNR_SRC     := $(HOME)/src/vendor/nextpnr
MISTRAL_NEXTPNR := $(HOME)/src/vendor/mistral-nextpnr
MISTRAL_NPR_REV := 6a97d3e
NEXTPNR         := $(NEXTPNR_SRC)/build-mistral/nextpnr-mistral
YOSYS           := yosys

TEST_CORES := out/spc-colortest.cor out/spc-invert-ch1.cor out/spc-invert-ch2.cor out/spc-invert-ch3.cor

all: $(TEST_CORES) build/spc-pinmap.txt

firmware/jb7.2.zip:
	mkdir -p firmware
	curl -sL -o $@ $(JB_ZIP)

$(SPC_COR): firmware/jb7.2.zip
	mkdir -p firmware/jb7.2
	unzip -o -q $< -d firmware/jb7.2
	touch $@

$(MISTRAL)/build/mistral-cv/mistral-cv:
	git clone --depth 1 https://github.com/Ravenslofty/mistral.git $(MISTRAL) 2>/dev/null || true
	mkdir -p $(MISTRAL)/build
	cd $(MISTRAL)/build && cmake .. -DCMAKE_BUILD_TYPE=Release && $(MAKE)

tools/mistral-cv: $(MISTRAL)/build/mistral-cv/mistral-cv
	ln -sf $< $@

tools/mistral-patch: tools/src/mistral-patch.cc tools/mistral-cv
	g++ $(CXXFLAGS) $< $(LIBS) -o $@

tools/rbfcycle: tools/src/rbfcycle.cc tools/mistral-cv
	g++ $(CXXFLAGS) $< $(LIBS) -o $@

tools/rbf2cor: tools/src/rbf2cor.cc tools/mistral-cv
	g++ $(CXXFLAGS) $< $(LIBS) -o $@

tools/fpllpins: tools/src/fpllpins.cc tools/mistral-cv
	g++ $(CXXFLAGS) $< $(LIBS) -o $@

tools/cvinfo: tools/src/cvinfo.cc tools/mistral-cv
	g++ $(CXXFLAGS) $< $(LIBS) -o $@

tools/pllinfo: tools/src/pllinfo.cc tools/mistral-cv
	g++ $(CXXFLAGS) $< $(LIBS) -o $@

$(NEXTPNR):
	git clone https://github.com/Ravenslofty/mistral.git $(MISTRAL_NEXTPNR) 2>/dev/null || true
	git -C $(MISTRAL_NEXTPNR) checkout -q $(MISTRAL_NPR_REV)
	git clone https://github.com/YosysHQ/nextpnr.git $(NEXTPNR_SRC) 2>/dev/null || true
	mkdir -p $(NEXTPNR_SRC)/build-mistral
	cd $(NEXTPNR_SRC)/build-mistral && cmake .. -DARCH=mistral -DMISTRAL_ROOT=$(MISTRAL_NEXTPNR) \
	  -DCMAKE_BUILD_TYPE=Release -DBUILD_GUI=OFF && $(MAKE) nextpnr-mistral

# .cor files are bit-reversed .rbf files.
build/spc.rbf: $(SPC_COR)
	mkdir -p build
	python3 -I tools/bitrev.py $< $@

build/spc.bt: build/spc.rbf tools/mistral-cv
	tools/mistral-cv decomp $(MODEL) $< $@

build/spc-pins.txt: build/spc.bt tools/pins.py
	python3 -I tools/pins.py $< > $@

build/f23-pins.txt: tools/cvinfo
	tools/cvinfo pins $(MODEL) > $@

build/hmc-bypass.txt: tools/cvinfo
	tools/cvinfo hmc $(MODEL) > $@

build/spc-pinmap.txt: build/spc.bt build/f23-pins.txt build/hmc-bypass.txt tools/pinmap.py tools/trace.py
	python3 -I tools/pinmap.py $< build/f23-pins.txt --hmc build/hmc-bypass.txt > $@

out/spc-%.cor: patches/%.bt build/spc.rbf tools/mistral-patch tools/mkcor.py
	mkdir -p out
	tools/mistral-patch patch build/spc.rbf $< build/spc-$*.rbf
	python3 -I tools/mkcor.py $(SPC_COR) build/spc-$*.rbf $@

# Our own cores: hw/<name>/*.v (top module `top`) + hw/<name>/<name>.qsf -> out/<name>.cor.
# Optional hw/<name>/nextpnr.args holds extra nextpnr flags (e.g. --freq for the timing target).
# -nodsp: nextpnr-mistral has no DSP bels, so multipliers must stay in logic.
.SECONDEXPANSION:
build/hw/%.json: $$(wildcard hw/$$*/*.v)
	mkdir -p build/hw
	$(YOSYS) -q -l build/hw/$*-yosys.log -p 'read_verilog $(wildcard hw/$*/*.v); synth_intel_alm -top top -nodsp; write_json $@'

build/hw/%.rbf: build/hw/%.json hw/$$*/$$*.qsf $(NEXTPNR) tools/checkqsf.py
	python3 -I tools/checkqsf.py $< hw/$*/$*.qsf
	$(NEXTPNR) --device $(MODEL) --json $< --qsf hw/$*/$*.qsf --rbf $@ -l build/hw/$*-nextpnr.log -q \
	  $(shell cat hw/$*/nextpnr.args 2>/dev/null) \
	  $(if $(wildcard hw/$*/pll.cfg),--write build/hw/$*-routed.json)

# PLL clocks (notes/pll.md): with hw/<name>/pll.cfg, the placeholder clock buffers it names are
# rewired to fPLL outputs after routing, and the result is checked (decodes cleanly, differs from
# nextpnr's bitstream only in the patch, requested frequencies decoded back).
build/hw/%-pll.rbf: build/hw/%.rbf hw/$$*/pll.cfg build/spc.bt tools/pllpatch.py tools/pllinfo tools/mistral-patch
	python3 -I tools/pllpatch.py patch hw/$*/pll.cfg $< build/hw/$*-routed.json build/spc.bt build/hw/$*-pll.bt
	tools/mistral-patch patch $< build/hw/$*-pll.bt $@
	python3 -I tools/pllpatch.py check hw/$*/pll.cfg $< $@ build/hw/$*-pll.bt

build/plls-%.txt: build/%.bt tools/pllpatch.py tools/pllinfo
	python3 -I tools/pllpatch.py decode $< > $@

out/%.cor: $$(if $$(wildcard hw/$$*/pll.cfg),build/hw/$$*-pll.rbf,build/hw/$$*.rbf) build/spc.rbf tools/rbf2cor
	mkdir -p out
	tools/rbf2cor $(MODEL) $< build/spc.rbf $@

# Simulate hw/<name> with Icarus Verilog (hw/<name>/sim/tb.v); writes build/sim/<name>.ppm (one
# video frame) and a PNG of it.
sim-%: hw/%/sim/tb.v $$(wildcard hw/$$*/*.v)
	mkdir -p build/sim
	iverilog -g2012 -o build/sim/$*.vvp $^
	vvp -n build/sim/$*.vvp
	convert build/sim/$*.ppm build/sim/$*.png

# Quartus builds (notes/quartus.md): quartus/<name>/<name>.qsf -> out/q-<name>.cor. The .cor is a
# plain bit reversal of Quartus' uncompressed .rbf; Quartus output is never decoded with mistral
# (licence rule 1 in notes/quartus.md).
.PRECIOUS: quartus/%.rbf
quartus/%.rbf: FORCE
	cd $(dir $@) && ../../tools/quartus quartus_sh --flow compile $(notdir $*) > build.log 2>&1 \
	  || { tail -20 build.log; exit 1; }
	@grep -q 'Timing requirements not met' $(dir $@)build.log && echo 'WARNING: timing not met' || true

out/q-%.cor: quartus/$$*/$$*.rbf tools/checkpins.py
	python3 -I tools/checkpins.py quartus/$*/$*.pin quartus/$*/pins.tcl
	mkdir -p out
	python3 -I tools/bitrev.py $< $@

# Hardware test core (quartus/hwtest): status screen template, font (from the VGA 8x16 console
# font) and audio sine table.
quartus/hwtest/hwtest.rbf: build/hwtest/screen.hex build/hwtest/font.hex build/hwtest/sine.hex
build/hwtest/screen.hex: quartus/hwtest/screen.txt tools/mkscreen.py
	mkdir -p build/hwtest
	python3 -I tools/mkscreen.py $< $@
build/hwtest/font.hex: tools/psf2hex.py
	mkdir -p build/hwtest
	python3 -I tools/psf2hex.py /usr/share/consolefonts/Lat15-VGA16.psf.gz $@
build/hwtest/sine.hex: tools/mksine.py
	mkdir -p build/hwtest
	python3 -I tools/mksine.py $@

# Simulation of quartus/hwtest: a PIC32 stand-in on the link that polls the status like the
# console and only then sends a file (once with the stock answer, once waiting for 0x00 so the
# candidate stepping has to find it), the SDRAM model, one 720p frame per screen page
# (build/sim/hwtest-P-N.png), the I2S stream decoded in both framings (quartus/hwtest/sim).
sim-hwtest: build/hwtest/screen.hex build/hwtest/font.hex build/hwtest/sine.hex
	mkdir -p build/sim
	iverilog -g2012 -o build/sim/hwtest.vvp -s tb quartus/hwtest/sim/tb.sv quartus/hwtest/sim/models.v \
	  quartus/hwtest/sim/sdram_model.v quartus/hwtest/hwtest_top.sv quartus/common/textmode.sv quartus/common/i2s_test.sv \
	  quartus/common/link_logger.sv quartus/common/pad_test.sv quartus/common/sdram_test.sv
	rm -f build/sim/hwtest-*.png
	cd build/sim && vvp -n hwtest.vvp > hwtest.log && grep -v '^log ' hwtest.log | tail -12
	grep -q '^LINK PASS' build/sim/hwtest.log
	cd build/sim && vvp -n hwtest.vvp +want=00 +noframes > hwtest-want00.log && grep -v '^log ' hwtest-want00.log | tail -4
	grep -q '^LINK PASS' build/sim/hwtest-want00.log
	python3 -I quartus/hwtest/sim/check.py build/sim

# Unit simulation of quartus/common/sdram_test.sv (quartus/hwtest/sim/tb_sdram.sv).
sim-sdram:
	mkdir -p build/sim
	iverilog -g2012 -s tb_sdram -o build/sim/sdram_test.vvp quartus/hwtest/sim/tb_sdram.sv \
	  quartus/hwtest/sim/sdram_model.v quartus/hwtest/sim/models.v quartus/common/sdram_test.sv
	vvp -n build/sim/sdram_test.vvp | tee build/sim/sdram_test.log | grep -v '^VCD'
	grep -q '^PASS' build/sim/sdram_test.log

# SNES + SA-1 core (quartus/snes, notes/snes-quartus.md): the test ROM is built into block RAM,
# so the Quartus build depends on it.
quartus/snes/snes.rbf: build/snes/sa1test.hex

# SA-1 test ROM (quartus/snes/testrom/sa1test.asm, layout and tests in its header). asar builds
# one 8 KB block at $00:E000-$FFFF into a fresh file (asar patches existing files);
# rom2hex.py --mirror copies it to all four 8 KB slots of the 32 KB image (the FPGA keeps 8 KB
# and ignores the higher ROM address bits) and sets the checksum. The .hex is that 8 KB as
# 16-bit little-endian words for $readmemh.
ASAR := $(HOME)/src/vendor/asar/build/asar/bin/asar

build/snes/sa1test.sfc: quartus/snes/testrom/sa1test.asm quartus/snes/testrom/rom2hex.py
	mkdir -p build/snes
	rm -f build/snes/sa1test-raw.sfc
	$(ASAR) --fix-checksum=off $< build/snes/sa1test-raw.sfc
	python3 -I quartus/snes/testrom/rom2hex.py --mirror build/snes/sa1test-raw.sfc $@

build/snes/sa1test.hex: build/snes/sa1test.sfc quartus/snes/testrom/rom2hex.py
	python3 -I quartus/snes/testrom/rom2hex.py $< $@ 8192

testrom: build/snes/sa1test.sfc build/snes/sa1test.hex
.PHONY: testrom

# Simulation of the whole quartus/snes top (notes/snes-quartus.md, "Simulation"): the core's
# VHDL goes through `ghdl synth` to Verilog, then Verilator. Work files (~1 GB of objects) go to
# SNES_SIM; the rendered 720p frames end up in build/sim/snes-NN.png, the report in
# build/sim/snes.log (last line PASS/FAIL: frame lock, line buffer, test results, picture).
SNES_SIM    ?= $(HOME)/scratch/snes-quartus/sim
SNES_UP     := $(HOME)/src/vendor/openfpga-SNES/rtl/upstream
SNES_FRAMES ?= 6
SNES_VHDL_SIM := quartus/snes/sim/bram_sim.vhd quartus/snes/sim/mlab_sim.vhd \
  $(addprefix $(SNES_SIM)/upstream/,65C816/P65816_pkg.vhd 65C816/BCDAdder.vhd 65C816/AddSubBCD.vhd \
  65C816/ALU.vhd 65C816/AddrGen.vhd 65C816/MCode.vhd 65C816/P65C816.vhd SPC700/SPC700_pkg.vhd \
  SPC700/AddSub.vhd SPC700/BCDAdj.vhd SPC700/ALU.vhd SPC700/AddrGen.vhd SPC700/MCode.vhd \
  SPC700/MulDiv.vhd SPC700/SPC700.vhd CEGen.vhd DSP_PKG.vhd PPU_PKG.vhd CPU.vhd SWRAM.vhd PPU.vhd \
  SMP.vhd DSP.vhd SNES.vhd chip/SRTC.vhd chip/RTC4513.vhd chip/DSP/DSPn.vhd chip/DSP/OBC1.vhd \
  chip/DSP/DSP_LHRomMap.vhd) quartus/snes/sim/sa1mult_sim.vhd \
  $(addprefix $(SNES_SIM)/upstream/,chip/SA1/SA1DIV.vhd chip/SA1/SA1.vhd chip/SA1/SA1Map.vhd)
SNES_GHDL := ghdl
SNES_GA   := --std=08 -fsynopsys -frelaxed -fexplicit -Wno-shared -Wno-hide -Wno-binding
SNES_SV   := quartus/snes/sim/tb.sv quartus/snes/snes_top.sv quartus/snes/snes_core.sv \
  quartus/snes/snes_video.sv quartus/common/i2s_out.sv quartus/snes/sim/sim_models.v $(SNES_UP)/main.v

# Vendor VHDL copied to the work dir with the GHDL fixes of quartus/snes/sim/ghdl.patch.
$(SNES_SIM)/upstream/.stamp: quartus/snes/sim/ghdl.patch
	rm -rf $(SNES_SIM)/upstream && mkdir -p $(SNES_SIM)/upstream
	cd $(SNES_UP) && cp --parents 65C816/*.vhd SPC700/*.vhd *.vhd chip/*.vhd chip/DSP/*.vhd \
	  chip/SA1/*.vhd $(SNES_SIM)/upstream/
	cd $(SNES_SIM) && patch -s -p0 < $(CURDIR)/quartus/snes/sim/ghdl.patch
	touch $@

$(SNES_SIM)/vlog/.stamp: $(SNES_SIM)/upstream/.stamp quartus/snes/sim/bram_sim.vhd \
    quartus/snes/sim/mlab_sim.vhd quartus/snes/sim/sa1mult_sim.vhd quartus/snes/sim/ghdl_fix.py
	rm -rf $(SNES_SIM)/work $(SNES_SIM)/vlog && mkdir -p $(SNES_SIM)/work $(SNES_SIM)/vlog
	cd $(SNES_SIM)/work && $(SNES_GHDL) -a $(SNES_GA) $(abspath $(SNES_VHDL_SIM))
	cd $(SNES_SIM)/work && for t in SNES SA1Map DSP_LHRomMap; do \
	  $(SNES_GHDL) synth $(SNES_GA) --latches $$( [ $$t = DSP_LHRomMap ] && echo "-gUSE_DSPn='0'" ) \
	    --out=verilog $$t > ../vlog/$$t.v 2> ../vlog/$$t.log || { tail ../vlog/$$t.log; exit 1; }; \
	  python3 -I $(CURDIR)/quartus/snes/sim/ghdl_fix.py ../vlog/$$t.v $${t}_ $$t $(SNES_UP)/main.v; done
	touch $@

$(SNES_SIM)/obj/Vtb: $(SNES_SIM)/vlog/.stamp $(SNES_SV) quartus/snes/sim/tb_snes.cpp
	verilator --cc --exe --build -j 4 -O2 --top-module tb +1364-2005ext+v -Wno-fatal -Wno-lint -Wno-style \
	  -Wno-MULTIDRIVEN -Wno-UNOPTFLAT -Wno-COMBDLY --x-assign fast --x-initial fast \
	  -CFLAGS -O1 -Mdir $(SNES_SIM)/obj -o Vtb \
	  -GROM_HEX='"$(CURDIR)/build/snes/sa1test.hex"' \
	  $(SNES_SV) $(SNES_SIM)/vlog/SNES.v $(SNES_SIM)/vlog/SA1Map.v \
	  $(SNES_SIM)/vlog/DSP_LHRomMap.v $(abspath quartus/snes/sim/tb_snes.cpp) \
	  > $(SNES_SIM)/verilator.log 2>&1 || { tail -30 $(SNES_SIM)/verilator.log; exit 1; }

sim-snes: $(SNES_SIM)/obj/Vtb build/snes/sa1test.hex
	mkdir -p build/sim
	rm -f build/sim/snes-*.p?m
	$(SNES_SIM)/obj/Vtb $(SNES_FRAMES) build/sim/snes- > build/sim/snes.log; s=$$?; \
	  cat build/sim/snes.log; \
	  for f in build/sim/snes-*.ppm; do convert $$f $${f%.ppm}.png && rm $$f; done; exit $$s

# SNES + SA-1 core with the cartridge ROM in SDRAM (quartus/snes_sdram, notes/snes-sdram.md):
# the boot ROM it copies into SDRAM is the same test ROM.
quartus/snes_sdram/snes_sdram.rbf: build/snes/sa1test.hex

# Unit simulations (iverilog): the SDRAM controller against the timed model
# (h:expect-fail:D_CLK:D_OUT): the default capture point and a neighbouring one (pass), two wrong
# ones (must fail), and the default with the clock phases snes_sdram is built with
# (sdram_cfg.tcl: relative to the capture clock, SDRAM clock 1.67 ns early, commands 0.63 ns
# late); the PIC32 link loader.
SDROM_SIM := quartus/snes_sdram/sim/tb_sdram_rom.sv quartus/snes_sdram/sim/sdram_model.v \
  quartus/snes_sdram/sim/ddio_model.v quartus/common/sdram_rom.sv
sim-sdram-rom: $(SDROM_SIM)
	mkdir -p build/sim
	@set -e; for c in 7:0:3.5:3.5 8:0:3.5:3.5 6:1:3.5:3.5 9:1:3.5:3.5 7:0:1.83:4.13; do \
	  set -- $$(echo $$c | tr : ' '); h=$$1; x=$$2; d=$$3; o=$$4; n=$$h-$$d; \
	  iverilog -g2012 -s tb_sdram_rom -P tb_sdram_rom.CAPTURE_HALF=$$h -P tb_sdram_rom.EXPECT_FAIL=$$x \
	    -P tb_sdram_rom.D_CLK=$$d -P tb_sdram_rom.D_OUT=$$o -o build/sim/sdram_rom_$$n.vvp $(SDROM_SIM); \
	  vvp -n build/sim/sdram_rom_$$n.vvp > build/sim/sdram_rom_$$n.log; \
	  grep -E '^ *[0-9]+ (init|wrote|phase)|^model' build/sim/sdram_rom_$$n.log | sed 's/^ *[0-9]* /  /'; \
	  grep -E '^(PASS|FAIL)' build/sim/sdram_rom_$$n.log; grep -q '^PASS' build/sim/sdram_rom_$$n.log; done

LINK_LD_SIM := quartus/snes_sdram/sim/tb_link_loader.sv quartus/snes_sdram/sim/sdram_model.v \
  quartus/snes_sdram/sim/ddio_model.v quartus/common/sdram_rom.sv quartus/common/link_loader.sv
sim-link-loader: $(LINK_LD_SIM)
	mkdir -p build/sim
	iverilog -g2012 -s tb_link_loader -o build/sim/link_loader.vvp $(LINK_LD_SIM)
	vvp -n build/sim/link_loader.vvp > build/sim/link_loader.log; tail -3 build/sim/link_loader.log | head -2
	grep -q '^PASS' build/sim/link_loader.log

# Simulation of the whole quartus/snes_sdram top (notes/snes-sdram.md, "Simulation"), like
# sim-snes (same GHDL netlists) with the cycle-based SDRAM model: boot copy into SDRAM, then the
# test ROM from SDRAM. Work files in SNES_SDRAM_SIM; frames build/sim/snes_sdram-NN.png, report
# build/sim/snes_sdram.log (last line PASS/FAIL). SNES_SDRAM_CAP builds with another
# CAPTURE_HALF (separate object directory).
SNES_SDRAM_SIM ?= $(HOME)/scratch/sdramrom/sim
SNES_SDRAM_CAP ?= 7
SNES_SDRAM_OBJ := $(SNES_SDRAM_SIM)/obj$(SNES_SDRAM_CAP)
SNES_SDRAM_SV := quartus/snes_sdram/sim/tb.sv quartus/snes_sdram/snes_sdram_top.sv \
  quartus/snes_sdram/snes_sdram_core.sv quartus/snes/snes_video.sv quartus/common/i2s_out.sv \
  quartus/common/sdram_rom.sv quartus/snes_sdram/sim/sim_models.v quartus/snes_sdram/sim/ddio_model.v \
  quartus/snes_sdram/sim/sdram_cyc.v $(SNES_UP)/main.v

$(SNES_SDRAM_OBJ)/Vtb: $(SNES_SIM)/vlog/.stamp $(SNES_SDRAM_SV) quartus/snes_sdram/sim/tb_snes_sdram.cpp
	mkdir -p $(SNES_SDRAM_SIM)
	verilator --cc --exe --build -j 4 -O2 --top-module tb +1364-2005ext+v -Wno-fatal -Wno-lint -Wno-style \
	  -Wno-MULTIDRIVEN -Wno-UNOPTFLAT -Wno-COMBDLY --x-assign fast --x-initial fast \
	  -CFLAGS -O1 -Mdir $(SNES_SDRAM_OBJ) -o Vtb \
	  -GROM_HEX='"$(CURDIR)/build/snes/sa1test.hex"' -GCAPTURE_HALF=$(SNES_SDRAM_CAP) \
	  $(SNES_SDRAM_SV) $(SNES_SIM)/vlog/SNES.v $(SNES_SIM)/vlog/SA1Map.v \
	  $(SNES_SIM)/vlog/DSP_LHRomMap.v $(abspath quartus/snes_sdram/sim/tb_snes_sdram.cpp) \
	  > $(SNES_SDRAM_OBJ).log 2>&1 || { tail -30 $(SNES_SDRAM_OBJ).log; exit 1; }

sim-snes-sdram: $(SNES_SDRAM_OBJ)/Vtb build/snes/sa1test.hex
	mkdir -p build/sim
	rm -f build/sim/snes_sdram-*.p?m
	$(SNES_SDRAM_OBJ)/Vtb $(SNES_FRAMES) build/sim/snes_sdram- > build/sim/snes_sdram.log; s=$$?; \
	  cat build/sim/snes_sdram.log; \
	  for f in build/sim/snes_sdram-*.ppm; do convert $$f $${f%.ppm}.png && rm $$f; done; exit $$s

FORCE:

clean:
	rm -rf build out

.PHONY: all clean FORCE sim-snes sim-hwtest sim-sdram sim-sdram-rom sim-snes-sdram sim-link-loader
.SECONDARY:
