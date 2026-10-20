# Super Nt reverse engineering: decode and patch jailbreak cores.
# `make` fetches the jailbreak, builds the tools and the test cores.

MISTRAL  := $(HOME)/src/vendor/mistral
MODEL    := 5CEBA4F23C8
JB_ZIP   := https://raw.githubusercontent.com/SmokeMonsterPacks/Super-NT-Jailbreak/master/firmware/snt_firmware_verJB7.2.zip
SPC_COR  := firmware/jb7.2/SYSTEM/CORES/spc.cor
CXXFLAGS := -O2 -std=c++17 -I$(MISTRAL)/libmistral -I$(MISTRAL)/build/libmistral \
            -I$(MISTRAL)/build/tools -I$(MISTRAL)/build -I$(MISTRAL)/mistral-cv
LIBS     := $(MISTRAL)/build/libmistral/libmistral.a -llzma

all: out/spc-colortest.cor build/spc-pins.txt

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

# .cor files are bit-reversed .rbf files.
build/spc.rbf: $(SPC_COR)
	mkdir -p build
	python3 -I tools/bitrev.py $< $@

build/spc.bt: build/spc.rbf tools/mistral-cv
	tools/mistral-cv decomp $(MODEL) $< $@

build/spc-pins.txt: build/spc.bt tools/pins.py
	python3 -I tools/pins.py $< > $@

out/spc-%.cor: patches/%.bt build/spc.rbf tools/mistral-patch tools/mkcor.py
	mkdir -p out
	tools/mistral-patch patch build/spc.rbf $< build/spc-$*.rbf
	python3 -I tools/mkcor.py $(SPC_COR) build/spc-$*.rbf $@

clean:
	rm -rf build out

.PHONY: all clean
.SECONDARY:
