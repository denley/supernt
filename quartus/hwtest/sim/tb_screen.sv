// Screen views of quartus/hwtest (make sim-screen): a PIC32 stand-in on the link writes what the
// SPC player wrote on the console (hwtest v4b) in a known form, and every display page is
// rendered once (build/sim/screen-PP-FFF.png, PP = page, FFF = frame), so the views can be
// checked by eye and tools/bitdump.py can be run on the bit images:
//   - 0x1006_0000, 8 KB: 256 glyphs of 16x16 at 1 bpp (2 bytes per row, MSB left): glyph g < 128
//     = our VGA font's g doubled in width, g >= 128 = glyph g - 128 inverted. So views 05-07
//     (2-byte cells, 16x16 1 bpp) show text, the other glyph formats garbage.
//   - 0x1018_0000, 4 KB: 2-byte cells (character, attribute = the row number), 64 per 128-byte
//     row (the console's layout, v4b): row 0 a title, rows 2-26 "ROW nn ..." up to cell 59,
//     row 27 cells 52-59 an 8-cell field (the console's 0x0DE8), row 28 cells 54-57, row 31
//     codes 80-9F (drawn yellow in our font).
//   - 0x1001_3000 0x300 bytes, 0x1017_0800 0x2500 bytes, a few registers: known patterns.
// Then one UI-loop pad read starts the virtual presses (sped up: one every 60 ms); after each
// press the stand-in writes the row-27 field ("PRESS nn"; 16 bytes at 0x1018_0DE8 like the
// console) as a partial update, and after every third press redraws the whole screen with the
// press number and button in row 1. The core's views
// cycle at one frame per page; 17 ms before each press the screen's bit image shows for 17 ms.
// At the end it prints the capture CRCs (compare with the views' headers and bitdump.py) and
// checks the screen history and press table against what the stand-in did.
`timescale 1ns/1ps
module tb;
    reg clk = 0, mclk = 0, h16 = 0;    // no H16: the video-PLL model stays off (saves time)
    always #6.734 clk = ~clk;          // 74.25 MHz
    always #40.690 mclk = ~mclk;       // 12.288 MHz
    wire pclk, s0, s1, s2, am, ab, al, ad;
    wire [7:0] ch1, ch2, ch3;
    reg  [2:0] la = 0;
    reg        nrd = 0, nwr = 1, drv = 0;
    reg  [7:0] dval = 0;
    wire [7:0] ld;
    assign ld = drv ? dval : 8'hzz;
    wire sclk, scs, sras, scas, swe, scke;
    wire [11:0] sa;
    wire [1:0] sba;
    tri0 [15:0] sdq;
    wire [7:0] sdqm;
    wire [18:0] tie3;
    wire [23:0] tie_hold;
    pullup pu_tie [18:0] (tie3);
    wire pp14, pj13, pk16;
    top #(.SCREEN_HEX("../hwtest/screen.hex"), .FONT_HEX("../hwtest/font.hex"),
          .SINE_HEX("../hwtest/sine.hex"), .HALF_SEC_FRAMES(0), .SD_ROWS(12'd3),
          .VP_SCRIPT(0), .VP_WAIT_US(1000), .VP_PRESS_US(2000), .VP_GAP_US(58000), .VP_DUMP_US(17000), .VP_DUMP_END(17000),
          .QUIET_US(300)) dut (
        .clk(clk), .h16(h16), .pclk(pclk), .s0(s0), .s1(s1), .s2(s2), .ch1(ch1), .ch2(ch2), .ch3(ch3),
        .aud_mclk(am), .aud_bclk(ab), .aud_lrclk(al), .aud_sdata(ad),
        .link_a(la), .link_nrd(nrd), .link_nwr(nwr), .link_d(ld),
        .pad_p14(pp14), .pad_j13(pj13), .pad_k16(pk16), .pad_t12(1'b1),
        .sd_clk(sclk), .sd_cs_n(scs), .sd_ras_n(sras), .sd_cas_n(scas), .sd_we_n(swe),
        .sd_a(sa), .sd_ba(sba), .sd_dq(sdq), .sd_cke(scke), .sd_dqm(sdqm), .tie3(tie3),
        .tie_hold(tie_hold));

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

    // the model's own copies, for the checks
    reg [7:0] font [0:2047];
    reg [7:0] glyphs [0:8191];
    reg [7:0] scr [0:4095];
    initial $readmemh("../hwtest/font.hex", font);
    function [31:0] crc8(input [31:0] c, input [7:0] b);
        integer i;
        reg [31:0] r;
        begin
            r = c ^ {24'd0, b};
            for (i = 0; i < 8; i = i + 1) r = r[0] ? (r >> 1) ^ 32'hEDB88320 : r >> 1;
            crc8 = r;
        end
    endfunction
    function [31:0] scr_crc(input dummy);
        integer i;
        reg [31:0] c;
        begin
            c = 32'hFFFFFFFF;
            for (i = 0; i < 4096; i = i + 1) c = crc8(c, scr[i]);
            scr_crc = ~c;
        end
    endfunction

    integer i, j, k, g, rr, px, v;
    reg [7:0] fb;
    reg [8*128-1:0] line;
    task put(input integer row, input integer cx, input [8*64-1:0] text, input integer n);
        integer q;
        begin
            for (q = 0; q < n; q = q + 1) begin
                scr[row * 128 + 2 * (cx + q)] = text[8*(n-1-q) +: 8];
                scr[row * 128 + 2 * (cx + q) + 1] = row;
            end
        end
    endtask
    task putc(input integer row, input integer cx, input [7:0] c);
        begin
            scr[row * 128 + 2 * cx] = c;
            scr[row * 128 + 2 * cx + 1] = row;
        end
    endtask
    task make_screen(input integer version);
        integer q, r;
        begin
            for (r = 0; r < 32; r = r + 1)
                for (q = 0; q < 64; q = q + 1) putc(r, q, q < 60 ? 8'h20 : 8'h00);
            put(0, 1, "SUPER NT SPC PLAYER - SIMULATED, 2-BYTE CELLS", 45);
            put(1, 1, "SCREEN VERSION", 14);
            putc(1, 16, "0" + version / 10); putc(1, 17, "0" + version % 10);
            for (q = 2; q < 27; q = q + 1) begin
                put(q, 0, "ROW", 3);
                putc(q, 4, "0" + q / 10); putc(q, 5, "0" + q % 10);
                put(q, 7, "THE QUICK BROWN FOX", 19);
                put(q, 27, "jumps over 0123456789 !?", 24);
                put(q, 52, "CELL 52>", 8);
            end
            put(27, 52, "TRACK 01", 8);
            put(28, 54, "STOP", 4);
            for (q = 0; q < 32; q = q + 1) putc(31, 4 + q, 8'h80 + q);
            put(30, 0, "LAST VISIBLE CELL 59 ->", 23);
            putc(30, 59, "|");
        end
    endtask
    task press_field(input integer np);
        begin
            put(27, 52, "PRESS ", 6);
            putc(27, 58, "0" + np / 10); putc(27, 59, "0" + np % 10);
        end
    endtask
    task send_screen;
        integer q;
        begin
            setaddr(32'h1000_D129); wr(2, 8'h01);
            setaddr(32'h1018_0000);
            for (q = 0; q < 4096; q = q + 1) wr(2, scr[q]);
            setaddr(32'h1000_D129); wr(2, 8'h00);
        end
    endtask

    integer np_seen = 0, nupd_model = 0, frame = 0, f, nframes = 60;
    reg [31:0] model_crc [0:63];
    reg pvs = 0;
    reg [8*48-1:0] name;
    initial begin
        if (!$value$plusargs("frames=%d", nframes)) nframes = 60;
        // glyphs: 16x16, 1 bpp, 2 bytes per row (our 8x16 font, every pixel doubled in width)
        for (g = 0; g < 256; g = g + 1)
            for (rr = 0; rr < 16; rr = rr + 1) begin
                fb = font[(g % 128) * 16 + rr];
                if (g >= 128) fb = ~fb;
                for (j = 0; j < 2; j = j + 1) begin
                    v = 0;
                    for (px = 0; px < 4; px = px + 1)
                        v = v << 2 | (fb[7 - (4 * j + px)] ? 3 : 0);
                    glyphs[g * 32 + rr * 2 + j] = v;
                end
            end
        make_screen(0);
        #2000;
        nrd = 1;
        #2000;
        setaddr(32'h1006_0000);
        for (i = 0; i < 8192; i = i + 1) wr(2, glyphs[i]);
        setaddr(32'h1010_0000);
        for (i = 0; i < 40; i = i + 1) wr(2, 8'h03 + i);
        setaddr(32'h1001_3000);
        for (i = 0; i < 768; i = i + 1) wr(2, i % 3 == 0 ? i / 3 : i % 3 == 1 ? 255 - i / 3 : 8'h80);
        setaddr(32'h111F_8100);
        for (i = 0; i < 128; i = i + 1) wr(2, i);
        setaddr(32'h1017_0800);
        for (i = 0; i < 16'h2500; i = i + 1) wr(2, i[7:0] ^ i[15:8]);
        setaddr(32'h1000_D110); wr(2, 8'h60);
        send_screen;
        $display("%t set-up written; screen CRC %08x", $time, scr_crc(0));
        model_crc[0] = scr_crc(0);
        nupd_model = 1;
        // one UI loop: the pad read starts the virtual presses
        setaddr(32'h1000_D120); wr(2, 8'h01);
        setaddr(32'h2000_0000); wr(3, 8'h00); rd(2); rd(2);
        forever begin
            @(posedge clk);
            if (dut.vp.n_press != np_seen) begin
                np_seen = dut.vp.n_press;
                #5000;                                     // the UI reacts a little later
                press_field(np_seen);
                if (np_seen % 3 == 0) begin
                    make_screen(np_seen);
                    press_field(np_seen);
                    putc(1, 20, dut.vp.btn < 10 ? "0" + dut.vp.btn : "A" - 10 + dut.vp.btn);
                    send_screen;
                end else begin
                    setaddr(32'h1018_0DE8);
                    for (i = 0; i < 16; i = i + 1) wr(2, scr[27 * 128 + 104 + i]);
                end
                if (nupd_model < 64) model_crc[nupd_model] = scr_crc(0);
                nupd_model = nupd_model + 1;
                $display("%t press %0d (button %0d): screen CRC %08x", $time, np_seen, dut.vp.btn, scr_crc(0));
            end
        end
    end

    // frames: one PPM per frame, named by the page shown
    integer bad = 0;
    always @(posedge clk) begin
        if (s0 && !pvs) begin
            if (frame > 0) $fclose(f);
            frame = frame + 1;
            if (frame > nframes) begin
                $display("capture CRCs: blocks %08x %08x %08x %08x %08x %08x %08x %08x",
                         dut.cap.crc_blk[31:0], dut.cap.crc_blk[63:32], dut.cap.crc_blk[95:64],
                         dut.cap.crc_blk[127:96], dut.cap.crc_blk[159:128], dut.cap.crc_blk[191:160],
                         dut.cap.crc_blk[223:192], dut.cap.crc_blk[255:224]);
                $display("font %08x pal %08x 1017 %08x screen %08x (model %08x), %0d changes logged, %0d press entries",
                         dut.cap.crc_font, dut.cap.crc_pal, dut.cap.crc_x17, dut.cap.scr_crc, scr_crc(0),
                         dut.cap.n_upd, dut.cap.n_pt);
                for (k = 0; k < dut.cap.n_upd && k < 64; k = k + 1) begin
                    $display("history %0d: T %05x press %0d button %0d CRC %08x (model %08x)", k,
                             dut.cap.hist[k][63:44], dut.cap.hist[k][43:36], dut.cap.hist[k][35:32],
                             dut.cap.hist[k][31:0], model_crc[k]);
                    if (dut.cap.hist[k][31:0] !== model_crc[k]) bad = bad + 1;
                end
                for (k = 0; k < dut.cap.n_pt && k < 64; k = k + 1)
                    $display("press %0d: button %0d T %05x CRC after %08x", dut.cap.ptab[k][63:56],
                             dut.cap.ptab[k][55:52], dut.cap.ptab[k][51:32], dut.cap.ptab[k][31:0]);
                if (dut.cap.scr_crc !== scr_crc(0) || dut.cap.n_upd < 4 || dut.cap.n_pt < 3 ||
                    dut.cap.crc_x17 === 32'd0) bad = bad + 1;
                if (bad == 0) $display("SCREEN PASS"); else $display("SCREEN FAIL (%0d)", bad);
                $finish;
            end else begin
                $sformat(name, "screen-%02d-%03d.ppm", dut.dps, frame);
                f = $fopen(name, "w");
                $fwrite(f, "P3\n1280 720\n255\n");
            end
        end
        if (s1 && frame > 0 && frame <= nframes) $fwrite(f, "%0d %0d %0d\n", ch1, ch2, ch3);
        pvs = s0;
    end
endmodule
