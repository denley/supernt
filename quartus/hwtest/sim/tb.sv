// Testbench for quartus/hwtest (make sim-hwtest). Plays a PIC32 on the link the way the console
// did (22 Oct 2026, notes/buslog-2026-10-22-hwtest.md): set-up writes (including a 3-byte write
// repeated five times), then the status poll (address 0x2004_0000, A=3 latch, read 2 bytes)
// until byte 0 has the bits it waits for (WANT, default 0x03 = the stock core's idle answer),
// and only then a 1 KB "file" at 0x00F0_0000, then a few more polls. Checks the bytes read back
// and the logger's merged entries. The x8 SDRAM pair is sdram_model.v with AB10 wired to its
// DQM. Renders one frame per page (hwtest-P-N.ppm, page time = 1 frame) and records the I2S
// stream (i2s.txt: "lrclk data mode" per BCLK rising edge).
// Plusargs: +want=HH (byte the PIC waits for; with a value other than 03 the candidate
// stepping must find it), +noframes (stop after the link checks).
`timescale 1ns/1ps
module tb;
    reg clk = 0, mclk = 0;
    always #6.734 clk = ~clk;          // 74.25 MHz
    always #40.690 mclk = ~mclk;       // 12.288 MHz
    wire pclk, s0, s1, s2, am, ab, al, ad;
    wire [7:0] ch1, ch2, ch3;
    reg  [2:0] la = 0;
    reg        nrd = 1, nwr = 1, drv = 0;
    reg  [7:0] dval = 0;
    wire [7:0] ld;
    assign ld = drv ? dval : 8'hzz;
    // SDRAM
    wire sclk, scs, sras, scas, swe, scke;
    wire [11:0] sa;
    wire [1:0] sba;
    tri0 [15:0] sdq;
    wire [7:0] sdqm;
    wire pp14, pj13, pk16;
    // SNES pad on port 1 holding START and A: latch (P14 high) loads the buttons, each clock
    // (J13) rise shifts; data is active low, 1s after the 16 bits (a real pad reads 0 there,
    // i.e. pressed, which gives pad_test's FFFF signature).
    reg [31:0] pad_sh = 32'hFFFFFFFF;
    reg        pj13_d = 1'b0;
    wire       pad_d = ~pad_sh[0];
    always @(posedge clk) begin
        pj13_d <= pj13;
        if (pp14) pad_sh <= 32'hFFFF_0108;          // bit 3 START, bit 8 A (1 = pressed)
        else if (pj13 && !pj13_d) pad_sh <= {1'b1, pad_sh[31:1]};
    end
    top #(.SCREEN_HEX("../hwtest/screen.hex"), .FONT_HEX("../hwtest/font.hex"),
          .SINE_HEX("../hwtest/sine.hex"), .PAGE0_FRAMES(10'd1), .PAGE_FRAMES(10'd1),
          .STEP_US(150), .SD_ROWS(12'd3)) dut (
        .clk(clk), .pclk(pclk), .s0(s0), .s1(s1), .s2(s2), .ch1(ch1), .ch2(ch2), .ch3(ch3),
        .aud_mclk(am), .aud_bclk(ab), .aud_lrclk(al), .aud_sdata(ad),
        .link_a(la), .link_nrd(nrd), .link_nwr(nwr), .link_d(ld),
        .pad_p14(pp14), .pad_j13(pj13), .pad_k16(pk16), .pad_t12(pad_d),
        .sd_clk(sclk), .sd_cs_n(scs), .sd_ras_n(sras), .sd_cas_n(scas), .sd_we_n(swe),
        .sd_a(sa), .sd_ba(sba), .sd_dq(sdq), .sd_cke(scke), .sd_dqm(sdqm));
    sdram_model mem (.clk(sclk), .cs_n(scs), .ras_n(sras), .cas_n(scas), .we_n(swe), .dqm(scke),
                     .a(sa), .ba(sba), .dq(sdq));
    defparam dut.aud.MODE_SAMPLES = 96;   // switch framing every 2 ms in simulation
    defparam dut.sdram.INIT_NOP = 16'd200;
    defparam dut.link.LOCK_BYTES = 512;
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

    integer i, j, polls = 0, bad = 0, noframes = 0;
    reg [7:0] want = 8'h03, b0, b1;
    reg [31:0] fcrc;
    reg [191:0] e;
    reg found_file, found_poll, found_rep;
    initial begin
        if (!$value$plusargs("want=%h", want)) want = 8'h03;
        if ($test$plusargs("noframes")) noframes = 1;
        #2000;
        setaddr(32'h1000_0034); wr(2, 8'h00);
        setaddr(32'h1010_0000);
        for (i = 0; i < 40; i = i + 1) wr(2, i[7:0]);              // a big run (40 bytes)
        for (j = 0; j < 5; j = j + 1) begin                        // repeated 3-byte write
            setaddr(32'h1000_9018); wr(2, 8'h00); wr(2, 8'h00); wr(2, 8'hFF);
        end
        // status poll, as the console did
        b0 = ~want;
        while (b0 != want) begin
            setaddr(32'h2004_0000); wr(3, 8'h00); rd(2); b0 = got; rd(2); b1 = got;
            polls = polls + 1;
            if (polls % 50 == 1)
                $display("poll %0d: 0x2004_0000 -> %02x %02x (candidate %0d)", polls, b0, b1,
                         dut.link.cand);
            if (polls > 4000) begin
                $display("FAIL: no answer %02x after %0d polls", want, polls);
                $finish;
            end
        end
        $display("poll %0d: 0x2004_0000 -> %02x %02x: the PIC sends the file", polls, b0, b1);
        if (want == 8'h03 && (b0 != 8'h03 || b1 != 8'h03 || polls != 1)) begin
            $display("FAIL: expected 03 03 on the first poll"); bad = bad + 1;
        end
        setaddr(32'h00F0_0000);
        fcrc = 32'hFFFFFFFF;
        for (i = 0; i < 1024; i = i + 1) begin
            wr(2, i[7:0] ^ i[9:2]);
            fcrc = crc8(fcrc, i[7:0] ^ i[9:2]);
        end
        fcrc = ~fcrc;
        for (j = 0; j < 3; j = j + 1) begin
            setaddr(32'h2004_0000); wr(3, 8'h00); rd(2); rd(2);
        end
        #1500000;                       // > 1 ms: the last run is flushed
        // log check: the file as one run, the polls merged into one entry
        found_file = 0; found_poll = 0; found_rep = 0;
        for (i = 0; i < dut.link.n_all; i = i + 1) begin
            e = dut.link.log_all[i];
            $display("log %03x: K%0d %08x %6x %02x %08x T%05x rep %0d", i, e[125:124], e[31:0],
                     e[53:32], e[123:116], e[95:64], e[115:96], e[159:128]);
            if (e[125:124] == 0 && e[31:0] == 32'h00F0_0000 && e[53:32] == 1024 && e[95:64] == fcrc)
                found_file = 1;
            if (e[125:124] == 1 && e[31:0] == 32'h2004_0000 && e[53:32] == 2 && e[159:128] > 1)
                found_poll = 1;
            if (e[125:124] == 0 && e[31:0] == 32'h1000_9018 && e[53:32] == 3 && e[159:128] == 5)
                found_rep = 1;
        end
        $display("file run %0s, poll entry merged %0s, 3-byte write x5 merged %0s; first read #%0d, candidate %0d (answer %02x, steps %0d, fixed %0d), big runs %0d",
                 found_file ? "ok" : "MISSING", found_poll ? "ok" : "MISSING",
                 found_rep ? "ok" : "MISSING", dut.link.first_rd, dut.link.cand,
                 dut.link.answer, dut.link.n_steps, dut.link.cand_locked, dut.link.n_big);
        if (!found_file || !found_poll || !found_rep || !dut.link.cand_locked || dut.link.n_big != 2)
            bad = bad + 1;
        if (bad == 0) $display("LINK PASS"); else $display("LINK FAIL");
        if (noframes) $finish;
    end

    integer f, fi, frame = 0, nbits = 0;
    reg pvs = 0;
    reg [8*32-1:0] name;
    initial fi = $test$plusargs("noframes") ? 0 : $fopen("i2s.txt", "w");
    always @(posedge clk) begin
        if (s0 && !pvs) begin
            if (frame > 0) $fclose(f);
            frame = frame + 1;
            if (frame == 10) begin
                $fclose(fi);
                $display("done, %0d I2S bits; SDRAM passes %0d; pad raw %h, held flags %h (expect FFFF0108, 108)",
                         nbits, dut.sdram.passes, dut.praw0, dut.st[23]);
                for (j = 0; j < 4; j = j + 1)
                    $display("SDRAM hyp %0d: passes %0d errors r4 %0d f4.5 %0d r3 %0d", j,
                             dut.sdram.ph[j], dut.sdram.eh[j*8+2], dut.sdram.eh[j*8+5],
                             dut.sdram.eh[j*8]);
                $finish;
            end
            $sformat(name, "hwtest-%0d-%0d.ppm", dut.page, frame);
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
