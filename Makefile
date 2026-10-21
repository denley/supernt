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

build/spc-pinmap.txt: build/spc.bt build/f23-pins.txt tools/pinmap.py tools/trace.py
	python3 -I tools/pinmap.py $< build/f23-pins.txt > $@

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

build/hw/%.rbf: build/hw/%.json hw/$$*/$$*.qsf $(NEXTPNR)
	$(NEXTPNR) --device $(MODEL) --json $< --qsf hw/$*/$*.qsf --rbf $@ -l build/hw/$*-nextpnr.log -q \
	  $(shell cat hw/$*/nextpnr.args 2>/dev/null)

out/%.cor: build/hw/%.rbf build/spc.rbf tools/rbf2cor
	mkdir -p out
	tools/rbf2cor $(MODEL) $< build/spc.rbf $@

clean:
	rm -rf build out

.PHONY: all clean
.SECONDARY:
