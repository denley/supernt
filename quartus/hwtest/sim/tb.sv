// Testbench for quartus/hwtest (make sim-hwtest). Plays a PIC32 on the link the way the console
// did (notes/buslog-2026-10-22-hwtest.md, hwtest v2 run): /RD low at power-up until the PIC
// sets up its port, set-up writes (including a 3-byte write repeated five times), 4 bytes of 0
// to 0x1000_0500 (mode register of the video-PLL reconfiguration block), then the status poll
// (address 0x2004_0000, A=3 latch, read 2 bytes) until both bytes are what it waits for (WANT,
// default 0x02: locked, waitrequest low, which the real reconfiguration IP in pll_emul answers
// once its reset counter has run out), then the SPC player's UI loop as on the console (hwtest
// v3: write 01 to 0x1000_D120, read 2 bytes at 0x2000_0000 and at 0x2001_0000, twice) until a
// button shows up there (START, 0x2000 bit 3: the core's virtual presses go A, START, ...), and
// only then a 1 KB "file" at 0x00F0_0000, a few more UI loops, 1100 distinct one-byte writes
// (the log wraps into its ring) and a 64-byte run at the end. Checks the bytes read back, the
// candidate that got fixed, the virtual press that preceded the file and the logger's merged
// entries (the UI loop must take one entry, the oldest and the newest entries survive the wrap).
// The core runs with its hwtest defaults (first candidate 1 = 02, I2S only, tone 24 dB down)
// unless +cand0 starts the answer at candidate 0 (the emulated PLL). As on the console with
// v4/v4b (Quartus dropped the port declaration's initial value), the candidate register is 0
// right after configuration; the core's post-configuration init must load FIRST_CAND.
// The file counts once a 1 KB run (FILE_RUN) goes outside the UI's blocks. The x8 SDRAM pair is sdram_model.v with chip B's DQM on AB10 and chip A's on the
// constant pin tie3[5]. Renders one frame per page (hwtest-P-N.ppm, page time = 1 frame) and
// records the I2S stream (i2s.txt: "lrclk data mode" per BCLK rising edge). Only the first 4
// pages are rendered here (iverilog is slow); make sim-screen renders every page.
// Plusargs: +want=HH (byte the PIC waits for; with a value candidate 1 doesn't give, the
// candidate stepping must find it), +cand0 (start at candidate 0, the emulated PLL), +noh16 (no
// clock on H16: the PLL never locks, the emulated status says 01 and the stepping must move on
// to 02), +noframes (stop after the link checks).
`timescale 1ns/1ps
module tb;
    reg clk = 0, mclk = 0, h16 = 0, h16_on = 1;
    always #6.734 clk = ~clk;          // 74.25 MHz
    always #6.734 if (h16_on) h16 = ~h16;
    always #40.690 mclk = ~mclk;       // 12.288 MHz
    wire pclk, s0, s1, s2, am, ab, al, ad;
    wire [7:0] ch1, ch2, ch3;
    reg  [2:0] la = 0;
    reg        nrd = 0, nwr = 1, drv = 0;  // /RD low until the PIC sets up its port
    reg  [7:0] dval = 0;
    wire [7:0] ld;
    assign ld = drv ? dval : 8'hzz;
    // SDRAM
    wire sclk, scs, sras, scas, swe, scke;
    wire [11:0] sa;
    wire [1:0] sba;
    tri0 [15:0] sdq;
    wire [7:0] sdqm;
    wire [18:0] tie3;
    wire [23:0] tie_hold;
    pullup pu_tie [18:0] (tie3);       // released constant pins: weak pull-up
    wire pp14, pj13, pk16;
    // SNES pad on port 1 holding Y and R: latch (P14 high) loads the buttons, each clock
    // (J13) rise shifts; data is active low, 1s after the 16 bits (a real pad reads 0 there,
    // i.e. pressed, which gives pad_test's FFFF signature).
    reg [31:0] pad_sh = 32'hFFFFFFFF;
    reg        pj13_d = 1'b0;
    wire       pad_d = ~pad_sh[0];
    always @(posedge clk) begin
        pj13_d <= pj13;
        if (pp14) pad_sh <= 32'hFFFF_0802;          // bit 1 Y, bit 11 R (1 = pressed)
        else if (pj13 && !pj13_d) pad_sh <= {1'b1, pad_sh[31:1]};
    end
    top #(.SCREEN_HEX("../hwtest/screen.hex"), .FONT_HEX("../hwtest/font.hex"),
          .SINE_HEX("../hwtest/sine.hex"), .HALF_SEC_FRAMES(0),
          .STEP_US(150), .SD_ROWS(12'd3), .VP_SCRIPT(0), .VP_WAIT_US(300), .VP_PRESS_US(100), .VP_GAP_US(1000),
          .VP_DUMP_US(50), .VP_DUMP_END(20), .QUIET_US(200), .FILE_RUN(1024)) dut (
        .clk(clk), .h16(h16), .pclk(pclk), .s0(s0), .s1(s1), .s2(s2), .ch1(ch1), .ch2(ch2), .ch3(ch3),
        .aud_mclk(am), .aud_bclk(ab), .aud_lrclk(al), .aud_sdata(ad),
        .link_a(la), .link_nrd(nrd), .link_nwr(nwr), .link_d(ld),
        .pad_p14(pp14), .pad_j13(pj13), .pad_k16(pk16), .pad_t12(pad_d),
        .sd_clk(sclk), .sd_cs_n(scs), .sd_ras_n(sras), .sd_cas_n(scas), .sd_we_n(swe),
        .sd_a(sa), .sd_ba(sba), .sd_dq(sdq), .sd_cke(scke), .sd_dqm(sdqm), .tie3(tie3),
        .tie_hold(tie_hold));
    sdram_model mem (.clk(sclk), .cs_n(scs), .ras_n(sras), .cas_n(scas), .we_n(swe),
                     .dqm_a(tie3[5]), .dqm_b(scke), .a(sa), .ba(sba), .dq(sdq));
    defparam dut.aud.MODE_SAMPLES = 96;   // switch framing every 2 ms in simulation
    defparam dut.sdram.INIT_NOP = 16'd200;
    defparam dut.link.LOCK_BYTES = 512;
    defparam dut.link.POLL_READS = 20;
    defparam dut.pads.START_US = 1000;

    task wr(input [2:0] a, input [7:0] d);
        begin
            la = a; dval = d; drv = 1; #40;
            nwr = 0; #120; nwr = 1; #40;
            drv = 0; #60;
        end
    endtask
    reg [7:0] got;
    task rd(input [2:0] a);
        begin
            la = a; #40;
            nrd = 0; #150; got = ld; nrd = 1; #100;
        end
    endtask
    task setaddr(input [31:0] x);
        begin
            wr(0, x[7:0]); wr(1, x[15:8]); wr(4, x[23:16]); wr(5, x[31:24]);
        end
    endtask

    // CRC-32 (zlib) of the file, for the log check
    function [31:0] crc8(input [31:0] c, input [7:0] b);
        integer i;
        reg [31:0] r;
        begin
            r = c ^ {24'd0, b};
            for (i = 0; i < 8; i = i + 1) r = r[0] ? (r >> 1) ^ 32'hEDB88320 : r >> 1;
            crc8 = r;
        end
    endfunction

    integer i, j, k, polls = 0, bad = 0, noframes = 0, loops = 0, nlog, npoll;
    reg [7:0] want = 8'h02, b0, b1, p0, p1, q0, q1, last0 = 8'hxx, last1 = 8'hxx;
    reg [31:0] fcrc, L;
    reg [191:0] e;
    reg found_file, found_poll, found_rep, found_ui, found_end, start_seen;
    // the player's UI loop: write 01 to 0x1000_D120, read 0x2000 and 0x2001 (2 bytes each), twice
    task ui_loop;
        begin
            setaddr(32'h1000_D120); wr(2, 8'h01);
            for (k = 0; k < 2; k = k + 1) begin
                setaddr(32'h2000_0000); wr(3, 8'h00); rd(2); p0 = got; rd(2); q0 = got;
                setaddr(32'h2001_0000); wr(3, 8'h00); rd(2); p1 = got; rd(2); q1 = got;
                if (p0 != q0 || p1 != q1) begin
                    $display("FAIL: pad bytes differ within a read: %02x %02x / %02x %02x", p0, q0, p1, q1);
                    bad = bad + 1;
                end
                if (p0 !== last0 || p1 !== last1)
                    $display("%t UI loop %0d: 0x2000 -> %02x, 0x2001 -> %02x (virtual press %0d: button %0d)",
                             $time, loops, p0, p1, dut.vp.n_press, dut.vp.btn);
                last0 = p0; last1 = p1;
            end
            loops = loops + 1;
            #15000;
        end
    endtask
    initial begin
        if (!$value$plusargs("want=%h", want)) want = 8'h02;
        if ($test$plusargs("noframes")) noframes = 1;
        if ($test$plusargs("noh16")) h16_on = 0;
        #1 dut.link.cand_q = 4'd0;                                 // v4/v4b's power-up value
        if ($test$plusargs("cand0")) begin wait (dut.link.por_done); #1 dut.link.cand_q = 4'd0; end
        #2000;
        nrd = 1;                                                   // PIC port set up
        #2000;
        setaddr(32'h1000_0034); wr(2, 8'h00);
        setaddr(32'h1010_0000);
        for (i = 0; i < 40; i = i + 1) wr(2, i[7:0]);              // a big run (40 bytes)
        for (j = 0; j < 5; j = j + 1) begin                        // repeated 3-byte write
            setaddr(32'h1000_9018); wr(2, 8'h00); wr(2, 8'h00); wr(2, 8'hFF);
        end
        setaddr(32'h1000_0500); wr(2, 8'h00); wr(2, 8'h00); wr(2, 8'h00); wr(2, 8'h00);
        // status poll, as the console did
        b0 = ~want;
        b1 = ~want;
        while (b0 != want || b1 != want) begin
            setaddr(32'h2004_0000); wr(3, 8'h00); rd(2); b0 = got; rd(2); b1 = got;
            polls = polls + 1;
            if (polls % 50 == 1)
                $display("poll %0d: 0x2004_0000 -> %02x %02x (candidate %0d)", polls, b0, b1,
                         dut.link.cand);
            if (polls > 6000) begin
                $display("FAIL: no answer %02x after %0d polls", want, polls);
                $finish;
            end
        end
        $display("poll %0d: 0x2004_0000 -> %02x %02x: the PIC sends the file", polls, b0, b1);
        if (want == 8'h02 && !$test$plusargs("noh16") && dut.link.cand != ($test$plusargs("cand0") ? 0 : 1)) begin
            $display("FAIL: expected the first candidate to answer 02 02"); bad = bad + 1;
        end
        // set-up blocks after the poll, as on the console (0x2000 bytes at 0x1006_0000 there):
        // they fix the answer (LOCK_BYTES = 512 here) before the UI loop starts
        setaddr(32'h1006_0000);
        for (i = 0; i < 600; i = i + 1) wr(2, i[7:0]);
        // the UI: wait for START (the real pad holds Y and R; the core presses A first, then START)
        wait (dut.ppolls != 0);         // the real pad read once (the first poll is at 1 ms)
        start_seen = 0;
        while (!start_seen) begin
            ui_loop;
            start_seen = p0[3];
            if (loops > 400) begin
                $display("FAIL: no START after %0d UI loops", loops); bad = bad + 1;
                start_seen = 1;
            end
        end
        if (p0 != 8'h0A || p1 != 8'h08) begin
            $display("FAIL: with START expected 0x2000 0A, 0x2001 08, got %02x %02x", p0, p1); bad = bad + 1;
        end
        $display("%t START seen after %0d UI loops: the PIC sends the file", $time, loops);
        setaddr(32'h00F0_0000);
        fcrc = 32'hFFFFFFFF;
        for (i = 0; i < 1024; i = i + 1) begin
            wr(2, i[7:0] ^ i[9:2]);
            fcrc = crc8(fcrc, i[7:0] ^ i[9:2]);
        end
        fcrc = ~fcrc;
        for (j = 0; j < 3; j = j + 1) ui_loop;
        // 1100 distinct entries: the log fills and wraps into its ring
        for (i = 0; i < 1100; i = i + 1) begin
            setaddr(32'h3000_0000 + 2 * i); wr(2, i[7:0]);
        end
        setaddr(32'h0400_0000);
        for (i = 0; i < 64; i = i + 1) wr(2, 8'h5A);
        #1500000;                       // > 1 ms: the last run is flushed
        // log check: the file as one run, the polls and the UI loop merged into one entry each,
        // the oldest 512 and the newest 512 entries readable
        found_file = 0; found_poll = 0; found_rep = 0; found_ui = 0; found_end = 0; nlog = 0; npoll = 0;
        for (L = 0; L < dut.link.n_all; L = L + 1) if (L < 512 || dut.link.n_all - L <= 512) begin
            e = dut.link.log_all[L < 512 ? L : 512 + L[8:0]];
            if (L < 40 || dut.link.n_all - L <= 3)
                $display("log %05x: K%0d %08x %6x %02x %08x T%05x rep %0d", L, e[125:124], e[31:0],
                         e[53:32], e[123:116], e[95:64], e[115:96], e[159:128]);
            if (e[125:124] == 0 && e[31:0] == 32'h00F0_0000 && e[53:32] == 1024 && e[95:64] == fcrc)
                found_file = 1;
            if (e[125:124] == 1 && e[31:0] == 32'h2004_0000 && e[53:32] == 2)
                npoll = npoll + e[159:128];
            if (e[125:124] == 0 && e[31:0] == 32'h1000_9018 && e[53:32] == 3 && e[159:128] == 5)
                found_rep = 1;
            if (e[125:124] == 0 && e[31:0] == 32'h1000_D120 && e[53:32] == 1 && e[159:128] >= loops - 3)
                found_ui = 1;
            if (L == dut.link.n_all - 1 && e[31:0] == 32'h0400_0000 && e[53:32] == 64)
                found_end = 1;
            nlog = nlog + 1;
        end
        found_poll = npoll == polls;
        $display("log: %0d entries logged, %0d readable; UI loops %0d, pad reads not logged %0d; virtual presses %0d, state %0d, file after press %0d = button %0d, %0d us after it",
                 dut.link.n_all, nlog, loops, dut.link.n_nolog, dut.vp.n_press, dut.vp.state,
                 dut.vp.xfer_np, dut.vp.xfer_btn, dut.vp.xfer_dt);
        if (!found_ui || !found_end || nlog != 1024 || dut.link.n_all < 1100 || dut.vp.state != 3 ||
            dut.vp.xfer_btn != 3 || dut.vp.xfer_np != 2 || dut.link.n_nolog != 8 * loops) begin
            $display("FAIL: UI entry %0d, newest entry %0d, virtual press record or pad read count wrong",
                     found_ui, found_end);
            bad = bad + 1;
        end
        $display("file run %0s, poll entry merged %0s, 3-byte write x5 merged %0s; first read #%0d (have %0d), candidate %0d (answer %02x, steps %0d, fixed %0d with %0d), big runs %0d, status reads %0d, writes after the poll %0d; reconfig commits %0d (last reg %0d = %08x), emulated status %b",
                 found_file ? "ok" : "MISSING", found_poll ? "ok" : "MISSING",
                 found_rep ? "ok" : "MISSING", dut.link.first_rd, dut.link.have_rd, dut.link.cand,
                 dut.link.answer, dut.link.n_steps, dut.link.cand_locked, dut.link.fix_cand,
                 dut.link.n_big, dut.link.n_stat, dut.link.n_wr_after, dut.emu.n_cmt,
                 dut.emu.last_reg, dut.emu.last_data, dut.emu.status);
        if (!found_file || !found_poll || !found_rep || !dut.link.cand_locked || dut.link.n_big != 4 ||
            !dut.link.have_rd || dut.emu.n_cmt != 1 || dut.link.fix_cand != dut.link.cand)
            bad = bad + 1;
        // the candidate that got fixed: the first one that gives WANT
        if (dut.link.fix_cand != (want == 8'h00 ? 4 : want == 8'h03 ? 2 :
                                  $test$plusargs("cand0") && !$test$plusargs("noh16") ? 0 : 1)) begin
            $display("FAIL: fixed with candidate %0d", dut.link.fix_cand); bad = bad + 1;
        end
        // the first read run must be the status poll (the power-up /RD low is ignored)
        e = dut.link.log_all[dut.link.first_rd];   // < 512: kept
        if (e[31:0] != 32'h2004_0000) begin
            $display("FAIL: first read run at %08x", e[31:0]); bad = bad + 1;
        end
        if (bad == 0) $display("LINK PASS"); else $display("LINK FAIL");
        if (noframes) $finish;
    end

    // +trace: changes of the emulated PLL status and of the answer candidate
    always @(dut.emu.status or dut.link.cand)
        if ($test$plusargs("trace"))
            $display("%t emulated status %b (locked, waitrequest), candidate %0d", $time,
                     dut.emu.status, dut.link.cand);
    integer f, fi, frame = 0, nbits = 0;
    reg pvs = 0;
    reg [8*32-1:0] name;
    initial fi = $test$plusargs("noframes") ? 0 : $fopen("i2s.txt", "w");
    always @(posedge clk) begin
        if (s0 && !pvs) begin
            if (frame > 0) $fclose(f);
            frame = frame + 1;
            if (frame == 5) begin
                $fclose(fi);
                $display("done, %0d I2S bits; SDRAM passes %0d; pad raw %h, held flags %h (expect FFFF0802, 802)",
                         nbits, dut.sdram.passes, dut.praw0, dut.st[23]);
                for (j = 0; j < 16; j = j + 1)
                    $display("SDRAM hyp %0d: passes %0d errors A r4 %0d f4.5 %0d, B r4 %0d f4.5 %0d", j,
                             dut.sdram.ph[j], dut.sdram.err_mem[j][47:24], dut.sdram.err_mem[j][71:48],
                             dut.sdram.err_mem[j][143:120], dut.sdram.err_mem[j][167:144]);
                $display("video PLL stand-in: H16 per ms %0d, out per ms %0d", dut.emu.ref_per_ms,
                         dut.emu.out_per_ms);
                $finish;
            end
            $sformat(name, "hwtest-%0d-%0d.ppm", dut.dps, frame);
            f = $fopen(name, "w");
            $fwrite(f, "P3\n1280 720\n255\n");
        end
        if (s1 && frame > 0) $fwrite(f, "%0d %0d %0d\n", ch1, ch2, ch3);
        pvs = s0;
    end
    always @(posedge ab) if (fi) begin
        $fwrite(fi, "%0d %0d %0d\n", al, ad, dut.aud.mode);
        nbits = nbits + 1;
    end
endmodule
