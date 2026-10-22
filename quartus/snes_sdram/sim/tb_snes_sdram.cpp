// SPDX-License-Identifier: GPL-3.0-or-later
// Verilator testbench for the Super Nt SNES core with ROM in SDRAM (quartus/snes_sdram), from
// quartus/snes/sim/tb_snes.cpp: runs the whole top (boot copy of the test ROM into the SDRAM
// model, then the SNES from SDRAM), writes each 720p output frame as a PPM and prints a
// per-frame report:
// - output frame length in lines (750 once aligned),
// - line-buffer conflicts (output reading a ring slot while the SNES side writes it),
// - the test ROM's result bytes in WRAM ($7E:00FE done flag, $7E:0100+k results),
// - SDRAM: reads/writes/refreshes, longest refresh gap, the controller's forced/stalled
//   refreshes and late reads, the model's protocol errors.
// clk_mem = 4 x clk_sys with aligned rising edges (both from one PLL VCO in hardware).
// Usage: tb_snes_sdram <frames> <out-prefix>   -> <out-prefix>NN.ppm
// Environment:
//   TB_ROM=<hex>        another 8 KB boot ROM image ($readmemh format)
//   TB_SFC=<file>       preload the SDRAM model with this ROM image instead of the boot copy
//                       (boot_len = 0); TB_MASK=<hex> sets the core's ROM mask (default 7FFF),
//                       TB_TYPE=<hex> its ROM_TYPE (default 60 = SA-1; 00 LoROM)
//   TB_WIN=lo,hi        read-data window of the SDRAM model in half cycles after the READ edge
//                       (default 7,8; the controller captures at CAPTURE_HALF)
//   TB_DEBUG=1          ring-buffer details
#include <cstdio>
#include <cstdlib>
#include <memory>
#include <string>
#include <vector>
#include "Vtb.h"
#include "Vtb___024root.h"
#include "verilated.h"

int main(int argc, char **argv) {
    const int nframes = argc > 1 ? atoi(argv[1]) : 6;
    const std::string prefix = argc > 2 ? argv[2] : "frame";
    auto ctx = std::make_unique<VerilatedContext>();
    auto tb = std::make_unique<Vtb>(ctx.get());
    auto *r = tb->rootp;

    // Half periods in ps: 74.25 MHz, the SNES clock (21.44196 MHz) and the memory clock (4 x).
    const double h74 = 1e6 / 74.25 / 2, hsys = 1e6 / 21.44196 / 2, hmem = hsys / 4;
    double t74 = h74, tmem = hmem * 0.37;
    long long mem_edges = 0;
    tb->clk = 0; tb->clk_sys = 0; tb->clk_mem = 0;
    tb->pad_t12 = getenv("TB_PAD") ? 0 : 1;   // TB_PAD=1: data line low = every button held
    tb->eval();
    // TB_ROM=<file.hex> replaces the ROM loaded by $readmemh (to try ROM variants without
    // rebuilding the model).
    if (const char *rom = getenv("TB_ROM")) {
        FILE *f = fopen(rom, "r");
        if (!f) { perror(rom); return 1; }
        unsigned w, i = 0;
        auto &mem = r->tb__DOT__dut__DOT__boot_rom;
        while (i < 4096 && fscanf(f, "%x", &w) == 1) mem[i++] = w;
        fclose(f);
        printf("ROM: %u words from %s\n", i, rom);
    }
    if (const char *sfc = getenv("TB_SFC")) {
        FILE *f = fopen(sfc, "rb");
        if (!f) { perror(sfc); return 1; }
        auto &sd = r->tb__DOT__sdram__DOT__mem;
        unsigned char b[2];
        unsigned n = 0;
        while (n < (1u << 23) && fread(b, 1, 2, f) == 2) sd[n++] = b[0] | b[1] << 8;
        fclose(f);
        r->tb__DOT__dut__DOT__boot_len = 0;
        unsigned mask = getenv("TB_MASK") ? strtoul(getenv("TB_MASK"), nullptr, 16) : 0x7fff;
        r->tb__DOT__dut__DOT__rom_mask = mask;
        if (getenv("TB_TYPE")) r->tb__DOT__dut__DOT__rom_type = strtoul(getenv("TB_TYPE"), nullptr, 16);
        printf("SDRAM preloaded: %u words from %s, boot copy skipped, ROM mask %06x\n", n, sfc, mask);
    }
    if (const char *w = getenv("TB_WIN")) {
        unsigned lo, hi;
        if (sscanf(w, "%u,%u", &lo, &hi) == 2) {
            r->tb__DOT__sdram__DOT__wlo = lo;
            r->tb__DOT__sdram__DOT__whi = hi;
            printf("SDRAM model read window: half cycles %u-%u after the READ edge\n", lo, hi);
        }
    }

    const int W = 1280, H = 720;
    std::vector<unsigned char> img(W * H * 3, 0);
    int frame = -1, line = -1, x = 0, lines_total = 0, conflicts = 0;
    long long sys_cycles = 0;
    int audio_peak = 0;   // max |audio_l| in the current output frame (S-DSP output)
    bool ok_lock = true, ok_ring = true, ok_pix = false, ok_wram = false;
    int prev_vs = 0, prev_hs = 0, prev_de = 0;
    auto &wram = r->tb__DOT__dut__DOT__snes__DOT__wram__DOT__mem;

    auto finish_frame = [&]() {
        if (frame >= 0) {
            char name[512];
            snprintf(name, sizeof name, "%s%02d.ppm", prefix.c_str(), frame);
            FILE *f = fopen(name, "wb");
            fprintf(f, "P6\n%d %d\n255\n", W, H);
            fwrite(img.data(), 1, img.size(), f);
            fclose(f);
            printf("frame %2d: %3d lines (%3d with DE), %d line-buffer conflicts, SNES cycles %lld,"
                   " WRAM done=%02x n=%d frame=%d results:",
                   frame, lines_total, line + 1, conflicts, sys_cycles, wram[0xfe], wram[0xff],
                   wram[0xfc] | wram[0xfd] << 8);
            for (int k = 0; k < 8; k++) printf(" %d", wram[0x100 + k]);
            printf(" audio peak %d\n", audio_peak);
            printf("          SDRAM: %d reads, %d words written, %d REF, longest REF gap %d cycles;"
                   " controller: forced REF %u, stalled REF %u, late reads %u, max REF interval %u;"
                   " model errors %d\n",
                   r->tb__DOT__sdram__DOT__n_rd, r->tb__DOT__sdram__DOT__n_wr,
                   r->tb__DOT__sdram__DOT__n_ref, r->tb__DOT__sdram__DOT__max_ref_gap,
                   (unsigned)r->tb__DOT__dut__DOT__sd_forced, (unsigned)r->tb__DOT__dut__DOT__sd_stall,
                   (unsigned)r->tb__DOT__dut__DOT__sd_late, (unsigned)r->tb__DOT__dut__DOT__sd_rfmax,
                   r->tb__DOT__sdram__DOT__errors);
            audio_peak = 0;
            // Frames 0-1 come before/at the alignment jump. From frame 2 on: standard 750-line
            // frames, no ring-buffer conflicts. Last frame: test results and the picture.
            if (frame >= 2) {
                ok_lock &= lines_total == 750;
                ok_ring &= conflicts == 0;
            }
            ok_wram = wram[0xfe] == 0xa5 && wram[0xff] > 0;
            for (int k = 0; k < wram[0xff]; k++) ok_wram &= wram[0x100 + k] == 1;
            // Summary band: SNES rows 16-31, x 16-239 -> output y 72-119 (224-line mode),
            // x 304-975. Pure green = all tests passed.
            const unsigned char *p = &img[(96 * W + 640) * 3];
            ok_pix = p[0] == 0 && p[1] == 255 && p[2] == 0;
            fflush(stdout);
        }
        frame++;
        line = -1; lines_total = 0; conflicts = 0;
        std::fill(img.begin(), img.end(), 0);
    };

    while (frame < nframes) {
        if (t74 <= tmem) {
            ctx->timeInc(1);
            tb->clk = !tb->clk;
            t74 += h74;
            tb->eval();
            if (!tb->clk) continue;
            // Rising edge of the video clock: sample the registered outputs.
            int hs = tb->s0, vs = tb->s1, de = tb->s2;
            if (vs && !prev_vs) finish_frame();
            if (hs && !prev_hs) lines_total++;
            if (de && !prev_de) { line++; x = 0; }
            if (de && frame >= 0 && line >= 0 && line < H && x < W) {
                unsigned char *p = &img[(line * W + x) * 3];
                p[0] = tb->ch1; p[1] = tb->ch2; p[2] = tb->ch3;   // proposed ch1/2/3 = R/G/B
            }
            if (de) x++;
            prev_vs = vs; prev_hs = hs; prev_de = de;
            // Ring-buffer check: the output shows ring slot sy[3:0] while the capture side is
            // writing a line into the same slot.
            unsigned hx = r->tb__DOT__dut__DOT__video__DOT__hx;
            static int prev_ws = 0;
            int ws = r->tb__DOT__dut__DOT__video__DOT__wslot;
            if (getenv("TB_DEBUG") && ws == 1 && prev_ws == 0)
                printf("  SNES line 0 written at output line %d, x %u\n",
                       (int)r->tb__DOT__dut__DOT__video__DOT__vy, hx);
            prev_ws = ws;
            if (r->tb__DOT__dut__DOT__video__DOT__vpic && hx >= 256 && hx < 256 + 768 &&
                r->tb__DOT__dut__DOT__video__DOT__hde_d && r->tb__DOT__dut__DOT__video__DOT__vde_d &&
                r->tb__DOT__dut__DOT__video__DOT__wslot == (r->tb__DOT__dut__DOT__video__DOT__sy & 15)) {
                if (!conflicts && getenv("TB_DEBUG"))
                    printf("  first conflict: output line %d, x %u, showing SNES line %d\n",
                           (int)r->tb__DOT__dut__DOT__video__DOT__vy, hx,
                           (int)r->tb__DOT__dut__DOT__video__DOT__sy);
                conflicts++;
            }
        } else {
            // memory clock edge; every 4th one (rising) also toggles clk_sys, in the same eval
            ctx->timeInc(1);
            tb->clk_mem = !tb->clk_mem;
            bool sys_edge = mem_edges % 4 == 0;
            if (sys_edge) tb->clk_sys = !tb->clk_sys;
            mem_edges++;
            tmem += hmem;
            tb->eval();
            if (sys_edge && tb->clk_sys) {
                sys_cycles++;
                int a = (int16_t)r->tb__DOT__dut__DOT__audio_l;
                if (a < 0) a = -a;
                if (a > audio_peak) audio_peak = a;
            }
        }
    }
    tb->final();
    bool ok_sd = r->tb__DOT__sdram__DOT__errors == 0 && r->tb__DOT__dut__DOT__sd_late == 0 &&
                 r->tb__DOT__dut__DOT__sd_stall == 0 && r->tb__DOT__sdram__DOT__max_ref_gap <= 1339;
    bool ok = ok_lock && ok_ring && ok_pix && ok_wram && ok_sd;
    printf("%s: frame lock %s, line buffer %s, WRAM results %s, summary band %s, SDRAM %s\n",
           ok ? "PASS" : "FAIL", ok_lock ? "ok" : "BAD", ok_ring ? "ok" : "BAD",
           ok_wram ? "all pass" : "BAD", ok_pix ? "green" : "NOT green",
           ok_sd ? "ok (no protocol errors, no late reads, refresh <= 15.6 us)" : "BAD");
    return ok ? 0 : 1;
}
