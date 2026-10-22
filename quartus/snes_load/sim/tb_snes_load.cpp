// SPDX-License-Identifier: GPL-3.0-or-later
// Verilator testbench for quartus/snes_load (make sim-snes-load), end to end: a PIC32 stand-in
// plays the SPC player's part on the link as the console did (notes/pic-link.md,
// notes/hardware-tests.md), a 4021 shift register stands in for the pad, the SDRAM is the cycle
// model with chip B's 512-column pages, and every 720p output frame is written as a PPM.
//
// The PIC32 stand-in (times are simulated time; waits shortened):
//   0-250 us   /RD held low (as the PIC does until it sets up its port);
//   set-up     register writes, a 0x200-byte block at 0x0000_0000 (below the file window),
//              0x80 bytes at 0x111F_8100, 0 to 0x1000_0500;
//   poll       0x2004_0000, A=3, two reads, until both are 02 (counts the polls);
//   set-up 2   25 writes to 0x1000_05xx, 0x1000_00C4, 0x200 bytes at 0x1006_0000, 0x40 at
//              0x1001_3000, the browser screen (4 KB at 0x1018_0000: 64 x 32 cells {character,
//              attribute}, the layout and footer bytes of the screen captured on the console,
//              cursor = attribute 0x60 on its row; files: the wrapped ROM first);
//   UI loop    every 8 ms: 01 -> 0x1000_D120, read 0x2000/0x2001 twice each; DOWN (pad bit 5)
//              moves the cursor and redraws the 4 KB screen, RUN (bit 1, "Y") on a file sends
//              it: link address 0xFF00 + offset, runs of 0x3000 bytes, 150 ns /WR pulses (3.3
//              MB/s in a run) with gaps for 1.7 MB/s on average (TB_FAST=1: no gaps); after the
//              file a few writes to 0x1000_D110/D114 (stand-ins for whatever the PIC does
//              then) and the UI loop goes on.
// The "user" (pad): DOWN at 30-60 ms, RUN (Y) at 75-105 ms, after the game started: L+R+SELECT
// for 30 ms twice (diagnostics page on and off; the PIC must read no buttons meanwhile).
// 180 ms after the boot the PIC sends the file again by itself (as an auto-advancing player
// might): the core must ignore it (the browser isn't open) and the game must go on.
//
// Usage: tb_snes_load <frames> <out-prefix> [file.spc]  (default build/snes_load/sa1test.spc)
// Environment: TB_FAST=1 (no gaps between runs), TB_GAME=1 (any ROM: don't check the SA-1
// test results, check the mapper against TB_TYPE/TB_MASK hex), TB_WIN=lo,hi (the SDRAM model's
// read window, default 8,8), TB_DEBUG=1.
// Exit status 0 = PASS (last line).
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <cstring>
#include <deque>
#include <functional>
#include <memory>
#include <string>
#include <vector>
#include "Vtb.h"
#include "Vtb___024root.h"
#include "verilated.h"

static uint32_t crc32(const uint8_t *p, size_t n) {
    uint32_t c = 0xFFFFFFFF;
    for (size_t i = 0; i < n; i++) {
        c ^= p[i];
        for (int k = 0; k < 8; k++) c = c & 1 ? (c >> 1) ^ 0xEDB88320 : c >> 1;
    }
    return ~c;
}

// ------------------------------------------------------------------------- PIC32 stand-in
struct Op {
    enum Kind { WR, RD, WAIT, CALL } kind;
    int a = 0;            // register select (A2..A0)
    uint8_t d = 0;        // write data
    double ns = 0;        // WAIT
    std::function<void(uint8_t)> rd;   // RD: called with the byte read
    std::function<void()> fn;           // CALL
};

struct Pic {
    std::deque<Op> q;
    double t_op = 0;      // start of the current op (ns)
    int step = -1;        // -1 none, 0 strobe low, 1 strobe high
    // pins
    int a = 0, nrd = 0, nwr = 1, drive = 0;
    uint8_t dout = 0;
    double pulse = 150;   // strobe low and high times (ns)

    void wr(int reg, uint8_t d) { Op o; o.kind = Op::WR; o.a = reg; o.d = d; q.push_back(o); }
    void addr(uint32_t ad) { wr(0, ad); wr(1, ad >> 8); wr(4, ad >> 16); wr(5, ad >> 24); }
    void block(uint32_t ad, const uint8_t *p, size_t n) { addr(ad); for (size_t i = 0; i < n; i++) wr(2, p[i]); }
    void byte(uint32_t ad, uint8_t d) { addr(ad); wr(2, d); }
    void read(uint32_t ad, int n, std::function<void(uint8_t)> f) {
        addr(ad); wr(3, 0);
        for (int i = 0; i < n; i++) { Op o; o.kind = Op::RD; o.a = 0; o.rd = f; q.push_back(o); }
    }
    void wait(double ns) { Op o; o.kind = Op::WAIT; o.ns = ns; q.push_back(o); }
    void call(std::function<void()> f) { Op o; o.kind = Op::CALL; o.fn = f; q.push_back(o); }

    // advance to time t (ns); din = the bus as the PIC sees it
    void tick(double t, uint8_t din) {
        for (;;) {
            if (q.empty()) return;
            Op &o = q.front();
            if (step < 0) { step = 0; t_op = t; }
            if (o.kind == Op::CALL) { auto f = o.fn; q.pop_front(); step = -1; f(); continue; }
            if (o.kind == Op::WAIT) {
                if (t - t_op < o.ns) return;
                q.pop_front(); step = -1; continue;
            }
            if (step == 0) {
                a = o.a;
                if (o.kind == Op::WR) { dout = o.d; drive = 1; nwr = 0; }
                else { drive = 0; nrd = 0; }
                if (t - t_op < pulse) return;
                if (o.kind == Op::RD) o.rd(din);
                nwr = 1; nrd = 1;
                step = 1; t_op = t;
                return;
            }
            if (t - t_op < pulse) return;
            drive = 0;
            q.pop_front(); step = -1;
        }
    }
};

int main(int argc, char **argv) {
    const int nframes = argc > 1 ? atoi(argv[1]) : 22;
    const std::string prefix = argc > 2 ? argv[2] : "frame";
    const std::string fname = argc > 3 ? argv[3] : "build/snes_load/sa1test.spc";
    const bool fast = getenv("TB_FAST") != nullptr, game = getenv("TB_GAME") != nullptr;
    std::vector<uint8_t> file;
    {
        FILE *f = fopen(fname.c_str(), "rb");
        if (!f) { perror(fname.c_str()); return 1; }
        uint8_t buf[65536];
        size_t n;
        while ((n = fread(buf, 1, sizeof buf, f)) > 0) file.insert(file.end(), buf, buf + n);
        fclose(f);
    }
    const uint32_t info_size = file[0x10188] | file[0x10189] << 8 | file[0x1018A] << 16 | (uint32_t)file[0x1018B] << 24;
    const uint32_t info_crc = file[0x1018C] | file[0x1018D] << 8 | file[0x1018E] << 16 | (uint32_t)file[0x1018F] << 24;
    printf("file %s: %zu bytes, CRC-32 %08X; ROM %u bytes, CRC-32 %08X (info block)\n", fname.c_str(),
           file.size(), crc32(file.data(), file.size()), info_size, info_crc);

    auto ctx = std::make_unique<VerilatedContext>();
    auto tb = std::make_unique<Vtb>(ctx.get());
    auto *r = tb->rootp;
    if (const char *w = getenv("TB_WIN")) {         // SDRAM model read window (half cycles)
        unsigned lo, hi;
        if (sscanf(w, "%u,%u", &lo, &hi) == 2) {
            r->tb__DOT__sdram__DOT__wlo = lo;
            r->tb__DOT__sdram__DOT__whi = hi;
            printf("SDRAM model read window: half cycles %u-%u after the READ edge\n", lo, hi);
        }
    }

    // ---------------------------------------------------------------- the player's screen
    std::string base = fname.substr(fname.find_last_of('/') + 1);
    std::string shown;
    for (char c : base) shown += toupper(c);
    // file list as the browser shows it (upper case, sorted case-sensitively: our files first)
    std::vector<std::string> files = {shown, "SPC README.TXT", "SUPER NT TEST CHORD.SPC",
                                      "SPC2_FILE_SPECIFICATION_V1.TXT"};
    int cursor = 0;      // 0 = GO BACK, k = files[k - 1]
    auto screen = [&](std::vector<uint8_t> &s) {
        s.assign(4096, 0);
        auto put = [&](int row, int col, uint8_t c, uint8_t at) { s[row * 128 + col * 2] = c; s[row * 128 + col * 2 + 1] = at; };
        auto text = [&](int row, int col, const std::string &t, uint8_t at) {
            for (size_t i = 0; i < t.size(); i++) put(row, col + i, t[i], at);
        };
        uint8_t hl = cursor == 0 ? 0x60 : 0;
        put(1, 1, 0xB2, hl); text(1, 2, "GO BACK", hl);
        for (size_t k = 0; k < files.size(); k++) text(2 + k, 1, files[k], cursor == (int)k + 1 ? 0x60 : 0);
        text(27, 1, "0:/SPC", 0);
        // footer bytes as captured from the console (hwtest v5, CRC 7E0ECAAA)
        put(28, 1, 0x8A, 0x08); text(28, 2, "NAVIGATE", 0); put(28, 13, 0x89, 0x08); text(28, 14, "PAGE", 0);
        put(29, 1, 0x83, 0x09); text(29, 2, "RUN", 0);
        for (int i = 0; i < 6; i++) put(29, 8 + i, 0x9E + i, 0x08);
        text(29, 14, "MENU", 0);
        put(30, 1, 0x81, 0x08); text(30, 2, "BACK", 0);
        for (int i = 0; i < 6; i++) put(30, 8 + i, 0xA4 + i, 0x08);
        text(30, 14, "BACK TO GAME", 0);
    };

    // ---------------------------------------------------------------- the PIC's script
    Pic pic;
    double now_ns = 0;
    int polls = 0, poll_ok_at = -1, ui_loops = 0, ui_after_boot = 0, presses_down = 0, runs = 0;
    int pad_nonzero_in_game = 0, pad_reads_in_game = 0;
    double t_file0 = -1, t_file1 = -1;
    uint8_t s0b = 0, s1b = 0, pad_prev = 0, pad_now = 0;
    bool sending = false, sent = false, booted = false, resent = false;
    std::function<void()> ui_loop, poll;
    std::vector<uint8_t> scr;
    auto send_screen = [&]() { screen(scr); pic.block(0x10180000, scr.data(), scr.size()); };
    poll = [&]() {
        pic.read(0x20040000, 2, [&](uint8_t v) { (polls & 1 ? s1b : s0b) = v; polls++; });
        pic.call([&]() {
            if (s0b == 0x02 && s1b == 0x02) {
                poll_ok_at = polls / 2;
                std::vector<uint8_t> blk(0x200);
                for (int i = 0; i < 25; i++) { pic.byte(0x10000500 + 4 * (i % 8), i); pic.wr(2, 0); pic.wr(2, 0); pic.wr(2, 0); }
                pic.byte(0x100000C4, 0x02); pic.byte(0x100000C4, 0x00);
                for (int i = 0; i < 0x200; i++) blk[i] = i * 13;
                pic.block(0x10060000, blk.data(), 0x200);
                pic.block(0x10013000, blk.data(), 0x40);
                send_screen();
                pic.call(ui_loop);
            } else {
                poll();
            }
        });
    };
    auto send_file = [&]() {
        sending = true;
        t_file0 = now_ns;
        for (size_t off = 0; off < file.size(); off += 0x3000) {
            size_t n = std::min<size_t>(0x3000, file.size() - off);
            pic.block(0xFF00 + off, file.data() + off, n);
            if (!fast) pic.wait(n * 1e9 / 1.7e6 - n * 2 * pic.pulse);   // 1.7 MB/s on average
        }
        pic.call([&]() {
            sending = false; sent = true; t_file1 = now_ns;
            for (int i = 4; i >= 0; i--) { pic.byte(0x1000D110, i); pic.byte(0x1000D114, 2 * i); }
            pic.call(ui_loop);
        });
    };
    ui_loop = [&]() {
        pic.byte(0x1000D120, 0x01);
        for (int k = 0; k < 2; k++) {
            pic.read(0x20000000, 2, [&](uint8_t v) { pad_now = v; });
            pic.read(0x20010000, 2, [&](uint8_t v) { (void)v; });
        }
        pic.call([&]() {
            ui_loops++;
            if (booted) {
                ui_after_boot++;
                pad_reads_in_game++;
                if (pad_now) pad_nonzero_in_game++;
            }
            uint8_t pressed = pad_now & ~pad_prev;
            pad_prev = pad_now;
            if (booted && !resent && now_ns / 1e6 > r->tb__DOT__dut__DOT__t_boot + 180.0) {
                resent = true;
                send_file();
                return;
            }
            if (pressed & 0x20 && !sent && cursor < (int)files.size()) { cursor++; presses_down++; send_screen(); }
            if (pressed & 0x02 && cursor == 1 && !sent && !sending) { runs++; send_file(); return; }
            pic.wait(8e6);
            pic.call(ui_loop);
        });
    };
    pic.nrd = 0;                       // /RD low until the port is set up
    pic.wait(250e3);
    pic.call([&]() {
        pic.nrd = 1;
        std::vector<uint8_t> blk(0x200);
        for (int i = 0; i < 0x200; i++) blk[i] = i ^ 0x5A;
        pic.byte(0x10000000 | 0x00C4, 0x00);
        pic.byte(0x10100034, 0x10);
        pic.block(0x00000000, blk.data(), 0x200);        // below 0xFF00: not the file
        pic.block(0x111F8100, blk.data(), 0x80);
        pic.addr(0x10000500); for (int i = 0; i < 4; i++) pic.wr(2, 0);
        poll();
    });

    // ---------------------------------------------------------------- the pad (4021 + user)
    int pad_idx = 0, prev_clk = 1, prev_latch = 0;
    auto buttons = [&](double ms) -> uint16_t {          // bit k = serial bit k, 1 = pressed
        uint16_t b = 0;
        if (ms >= 30 && ms < 60) b |= 1 << 5;                         // DOWN
        if (ms >= 75 && ms < 105) b |= 1 << 1;                        // Y = RUN
        const double tb0 = r->tb__DOT__dut__DOT__t_boot;              // ms (the core's clock)
        if (booted && ((ms >= tb0 + 60 && ms < tb0 + 90) || (ms >= tb0 + 130 && ms < tb0 + 160)))
            b |= 1 << 10 | 1 << 11 | 1 << 2;                          // L+R+SELECT
        return b;
    };

    // ---------------------------------------------------------------- clocks and frames
    const double h74 = 1e6 / 74.25 / 2, hsys = 1e6 / 21.44196 / 2, hmem = hsys / 5;   // ps (clk_mem = 5 x)
    double t74 = h74, tmem = hmem * 0.37;
    long long mem_edges = 0;
    tb->clk = 0; tb->clk_sys = 0; tb->clk_mem = 0;
    tb->pad_t12 = 1;
    tb->pic_nrd = 0; tb->pic_nwr = 1; tb->pic_a = 0; tb->pic_drive = 0;
    tb->eval();

    const int W = 1280, H = 720;
    std::vector<unsigned char> img(W * H * 3, 0);
    int frame = -1, line = -1, x = 0, lines_total = 0, conflicts = 0;
    bool ok_lock = true, ok_ring = true, ok_pix = false, ok_wram = false, ok_browser = false,
         ok_cursor = false, ok_diag = false;
    int boot_frame = -1, diag_frames = 0;
    int prev_vs = 0, prev_hs = 0, prev_de = 0;
    auto &wram = r->tb__DOT__dut__DOT__snes__DOT__wram__DOT__mem;
    auto px = [&](int yy, int xx) -> uint32_t { const unsigned char *p = &img[(yy * W + xx) * 3]; return p[0] << 16 | p[1] << 8 | p[2]; };
    int mode_seen = 0;

    auto finish_frame = [&]() {
        if (frame >= 0) {
            char name[512];
            snprintf(name, sizeof name, "%s%02d.ppm", prefix.c_str(), frame);
            FILE *f = fopen(name, "wb");
            fprintf(f, "P6\n%d %d\n255\n", W, H);
            fwrite(img.data(), 1, img.size(), f);
            fclose(f);
            const char *mname[] = {"game", "browser", "diagnostics", "?"};
            printf("frame %2d (%6.1f ms): %3d lines, view %s, loader state %d, file bytes %u, SNES %s,"
                   " WRAM done=%02x results:", frame, now_ns / 1e6, lines_total, mname[mode_seen & 3],
                   r->tb__DOT__dut__DOT__ld_state, r->tb__DOT__dut__DOT__n_file,
                   r->tb__DOT__dut__DOT__core_reset ? "reset" : "running", wram[0xfe]);
            for (int k = 0; k < 7; k++) printf(" %d", wram[0x100 + k]);
            printf("\n          link: status polls %d (02 02 at poll %d), UI loops %d (%d since boot), PIC saw DOWN %d RUN %d;"
                   " SDRAM reads %u, late %u, forced REF %u, model errors %d\n",
                   polls / 2, poll_ok_at, ui_loops, ui_after_boot, presses_down, runs,
                   r->tb__DOT__dut__DOT__sd_reads, (unsigned)r->tb__DOT__dut__DOT__sd_late,
                   (unsigned)r->tb__DOT__dut__DOT__sd_forced, r->tb__DOT__sdram__DOT__errors);
            // browser: cursor bar (0x2050B0) behind GO BACK before DOWN, behind the first file after
            if (mode_seen == 1) {
                uint32_t bar1 = px(8 + 22 * 1, 128 + 16 * 3), bar2 = px(8 + 22 * 2, 128 + 16 * 3);
                if (presses_down == 0 && bar1 == 0x2050B0 && bar2 == 0) ok_browser = true;
                if (presses_down == 1 && bar2 == 0x2050B0 && bar1 == 0) ok_cursor = true;
            }
            if (mode_seen == 2 && boot_frame >= 0 && frame > boot_frame) diag_frames++;
            if (boot_frame >= 0 && frame >= boot_frame + 3) {
                ok_lock &= lines_total == 750;
                ok_ring &= conflicts == 0;
            }
            if (boot_frame >= 0 && mode_seen == 0) {
                ok_wram = wram[0xfe] == 0xa5 && wram[0xff] > 0;
                for (int k = 0; k < wram[0xff]; k++) ok_wram &= wram[0x100 + k] == 1;
                const unsigned char *p = &img[(96 * W + 640) * 3];
                ok_pix = p[0] == 0 && p[1] == 255 && p[2] == 0;
            }
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
            now_ns = t74 / 1000;
            t74 += h74;
            tb->eval();
            if (!tb->clk) continue;
            // PIC and pad act on the 74.25 MHz grid
            pic.tick(now_ns, tb->pic_din);
            tb->pic_a = pic.a; tb->pic_nrd = pic.nrd; tb->pic_nwr = pic.nwr;
            tb->pic_dout = pic.dout; tb->pic_drive = pic.drive;
            if (tb->link_oe && pic.drive) { printf("BUS CONFLICT on the link at %.0f ns\n", now_ns); return 1; }
            int latch = tb->pad_p14, pclk_ = tb->pad_j13;
            uint16_t bt = buttons(now_ns / 1e6);
            if (latch) pad_idx = 0;
            else if (pclk_ && !prev_clk) pad_idx++;
            prev_clk = pclk_; prev_latch = latch;
            tb->pad_t12 = pad_idx < 12 ? !(bt >> pad_idx & 1) : pad_idx < 16 ? 1 : 0;
            if (!booted && !r->tb__DOT__dut__DOT__core_reset) { booted = true; boot_frame = frame; }
            // video
            int hs = tb->s0, vs = tb->s1, de = tb->s2;
            if (vs && !prev_vs) finish_frame();
            if (hs && !prev_hs) lines_total++;
            if (de && !prev_de) { line++; x = 0; mode_seen = r->tb__DOT__dut__DOT__mode; }
            if (de && frame >= 0 && line >= 0 && line < H && x < W) {
                unsigned char *p = &img[(line * W + x) * 3];
                p[0] = tb->ch1; p[1] = tb->ch2; p[2] = tb->ch3;
            }
            if (de) x++;
            prev_vs = vs; prev_hs = hs; prev_de = de;
            unsigned hx = r->tb__DOT__dut__DOT__video__DOT__hx;
            if (r->tb__DOT__dut__DOT__video__DOT__vpic && hx >= 256 && hx < 256 + 768 &&
                r->tb__DOT__dut__DOT__video__DOT__hde_d && r->tb__DOT__dut__DOT__video__DOT__vde_d &&
                r->tb__DOT__dut__DOT__video__DOT__wslot == (r->tb__DOT__dut__DOT__video__DOT__sy & 15))
                conflicts++;
        } else {
            ctx->timeInc(1);
            tb->clk_mem = !tb->clk_mem;
            bool sys_edge = mem_edges % 5 == 0;
            if (sys_edge) tb->clk_sys = !tb->clk_sys;
            mem_edges++;
            tmem += hmem;
            tb->eval();
        }
    }
    tb->final();
    if (getenv("TB_DEBUG")) {                         // SDRAM model contents vs the ROM
        auto &sd = r->tb__DOT__sdram__DOT__mem;
        int bad = 0;
        for (uint32_t k = 0; k < info_size && k < (1u << 23); k++) {
            uint8_t got = sd[k] >> 8, want = file[0x10200 + k];
            if (got != want && ++bad <= 10) printf("SDRAM byte %06X = %02X, ROM %02X\n", k, got, want);
        }
        printf("SDRAM vs ROM: %d bytes differ\n", bad);
    }

    // ---------------------------------------------------------------- verdict
    const unsigned st = r->tb__DOT__dut__DOT__ld_state;
    const unsigned rt = r->tb__DOT__dut__DOT__rom_type, rm = r->tb__DOT__dut__DOT__rom_mask;
    printf("loader: state %u, file %u bytes (CRC-32 %08X, expected %08X), ROM %u bytes, transfer CRC %08X,"
           " read-back CRC %08X, info CRC %08X, ok_info %d, order errors %u, dropped %u\n",
           st, r->tb__DOT__dut__DOT__n_file, r->tb__DOT__dut__DOT__crc_file, crc32(file.data(), file.size()),
           r->tb__DOT__dut__DOT__rom_size, r->tb__DOT__dut__DOT__crc_rom, r->tb__DOT__dut__DOT__crc_sd,
           r->tb__DOT__dut__DOT__info_crc, r->tb__DOT__dut__DOT__ok_info, r->tb__DOT__dut__DOT__n_order,
           r->tb__DOT__dut__DOT__n_drop);
    printf("        header %08X, scores %03X, kind %u, ROM_TYPE %02X, ROM mask %06X, RAM mask %06X;"
           " transfer %.1f-%.1f ms (%.2f MB/s), core: load T %u-%u ms, boot T %u ms; log runs %u\n",
           r->tb__DOT__dut__DOT__hdr_w0, r->tb__DOT__dut__DOT__scores, r->tb__DOT__dut__DOT__ld_kind, rt, rm,
           r->tb__DOT__dut__DOT__ram_mask, t_file0 / 1e6, t_file1 / 1e6,
           file.size() / ((t_file1 - t_file0) / 1e9) / 1e6, r->tb__DOT__dut__DOT__t_start,
           r->tb__DOT__dut__DOT__t_end, r->tb__DOT__dut__DOT__t_boot, r->tb__DOT__dut__DOT__n_log);
    bool ok_link = poll_ok_at == 1 && presses_down == 1 && runs == 1 && ui_after_boot > 0 &&
                   pad_nonzero_in_game == 0;
    // the second transfer (while the game ran) ignored: every byte counted, no reload
    bool ok_guard = game || (resent && r->tb__DOT__dut__DOT__n_ign == file.size());
    printf("second transfer while the game ran: %s, %u bytes ignored\n", resent ? "sent" : "NOT SENT",
           r->tb__DOT__dut__DOT__n_ign);
    ok_link &= ok_guard;
    bool ok_load = st == 5 && r->tb__DOT__dut__DOT__ok_info && r->tb__DOT__dut__DOT__crc_sd == info_crc &&
                   r->tb__DOT__dut__DOT__crc_file == crc32(file.data(), file.size()) &&
                   r->tb__DOT__dut__DOT__n_order == 0 && r->tb__DOT__dut__DOT__n_drop == 0;
    bool ok_map = true;
    if (getenv("TB_TYPE")) ok_map &= rt == strtoul(getenv("TB_TYPE"), nullptr, 16);
    if (getenv("TB_MASK")) ok_map &= rm == strtoul(getenv("TB_MASK"), nullptr, 16);
    ok_diag = diag_frames > 0;
    bool ok_sd = r->tb__DOT__sdram__DOT__errors == 0 && r->tb__DOT__dut__DOT__sd_late == 0 &&
                 r->tb__DOT__dut__DOT__sd_stall == 0 && r->tb__DOT__sdram__DOT__max_ref_gap <= 1673;
    bool ok = ok_link && ok_browser && ok_cursor && ok_load && ok_map && ok_sd &&
              (game || (ok_wram && ok_pix && ok_lock && ok_ring && ok_diag));
    printf("%s: link %s, browser %s, cursor %s, load+verify %s, mapper %s, SDRAM %s", ok ? "PASS" : "FAIL",
           ok_link ? "ok" : "BAD", ok_browser ? "ok" : "BAD", ok_cursor ? "ok" : "BAD", ok_load ? "ok" : "BAD",
           ok_map ? "ok" : "BAD", ok_sd ? "ok" : "BAD");
    if (!game)
        printf(", SA-1 tests %s, summary band %s, frame lock %s, line buffer %s, diagnostics over the game %s",
               ok_wram ? "all pass" : "BAD", ok_pix ? "green" : "NOT green", ok_lock ? "ok" : "BAD",
               ok_ring ? "ok" : "BAD", ok_diag ? "ok" : "BAD");
    printf("\n");
    return ok ? 0 : 1;
}
