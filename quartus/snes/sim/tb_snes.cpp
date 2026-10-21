// SPDX-License-Identifier: GPL-3.0-or-later
// Verilator testbench for the Super Nt SNES core (quartus/snes): runs the whole top with the
// test ROM, writes each 720p output frame as a PPM and prints a per-frame report:
// - output frame length in lines (frame lock: 748/749 once locked, 750 free-running),
// - line-buffer conflicts (output reading a ring slot while the SNES side writes it),
// - the test ROM's result bytes in WRAM ($7E:00FE done flag, $7E:0100+k results).
// Usage: tb_snes <frames> <out-prefix>   -> <out-prefix>NN.ppm
// Environment: TB_ROM=<hex> loads another ROM image, TB_DEBUG=1 prints ring-buffer details.
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

    // Half periods in ps: 74.25 MHz and 21.477272 MHz.
    const double h74 = 1e6 / 74.25 / 2, hsys = 1e6 / 21.477272 / 2;
    double t74 = h74, tsys = hsys * 0.37;
    tb->clk = 0; tb->clk_sys = 0; tb->eval();
    // TB_ROM=<file.hex> replaces the ROM loaded by $readmemh (to try ROM variants without
    // rebuilding the model).
    if (const char *rom = getenv("TB_ROM")) {
        FILE *f = fopen(rom, "r");
        if (!f) { perror(rom); return 1; }
        unsigned w, i = 0;
        auto &mem = r->tb__DOT__dut__DOT__snes__DOT__rom;
        while (i < 4096 && fscanf(f, "%x", &w) == 1) mem[i++] = w;
        fclose(f);
        printf("ROM: %u words from %s\n", i, rom);
    }

    const int W = 1280, H = 720;
    std::vector<unsigned char> img(W * H * 3, 0);
    int frame = -1, line = -1, x = 0, lines_total = 0, conflicts = 0;
    long long sys_cycles = 0;
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
            printf("\n");
            // Frames 0-1 come before/at the first lock. From frame 2 on: locked frame lengths,
            // no ring-buffer conflicts. Last frame: test results and the picture.
            if (frame >= 2) {
                ok_lock &= lines_total == 748 || lines_total == 749;
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
        if (t74 <= tsys) {
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
            ctx->timeInc(1);
            tb->clk_sys = !tb->clk_sys;
            tsys += hsys;
            tb->eval();
            if (tb->clk_sys) sys_cycles++;
        }
    }
    tb->final();
    bool ok = ok_lock && ok_ring && ok_pix && ok_wram;
    printf("%s: frame lock %s, line buffer %s, WRAM results %s, summary band %s\n",
           ok ? "PASS" : "FAIL", ok_lock ? "ok" : "BAD", ok_ring ? "ok" : "BAD",
           ok_wram ? "all pass" : "BAD", ok_pix ? "green" : "NOT green");
    return ok ? 0 : 1;
}
