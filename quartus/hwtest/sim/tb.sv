// Testbench for quartus/hwtest (make sim-hwtest). Plays a PIC32 on the link (address set-up,
// a 300-byte burst, a status read), renders one frame per page (hwtest-P.ppm, page time = 1
// frame) and records the I2S stream (i2s.txt: "lrclk data mode" per BCLK rising edge).
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
    top #(.SCREEN_HEX("../hwtest/screen.hex"), .FONT_HEX("../hwtest/font.hex"),
          .SINE_HEX("../hwtest/sine.hex"), .PAGE0_FRAMES(10'd1), .PAGE_FRAMES(10'd1)) dut (
        .clk(clk), .pclk(pclk), .s0(s0), .s1(s1), .s2(s2), .ch1(ch1), .ch2(ch2), .ch3(ch3),
        .aud_mclk(am), .aud_bclk(ab), .aud_lrclk(al), .aud_sdata(ad),
        .link_a(la), .link_nrd(nrd), .link_nwr(nwr), .link_d(ld));
    defparam dut.aud.MODE_SAMPLES = 96;   // switch framing every 2 ms in simulation

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
    integer i;
    initial begin
        #2000;
        wr(0, 8'h00); wr(1, 8'h81); wr(4, 8'h1F); wr(5, 8'h11);   // 0x111F8100
        for (i = 0; i < 300; i = i + 1) wr(2, i[7:0]);
        wr(0, 8'h00); wr(1, 8'h00); wr(4, 8'h09); wr(5, 8'h20);   // 0x20090000
        wr(3, 8'h00);
        rd(2);
        $display("read 0x20090000 -> %02x (expect 64)", got);
        wr(0, 8'h18); wr(1, 8'h90); wr(4, 8'h00); wr(5, 8'h10);
        wr(2, 8'hEE);
    end

    integer f, fi, frame = 0, nbits = 0;
    reg pvs = 0;
    reg [8*32-1:0] name;
    initial fi = $fopen("i2s.txt", "w");
    always @(posedge clk) begin
        if (s0 && !pvs) begin
            if (frame > 0) $fclose(f);
            frame = frame + 1;
            if (frame == 10) begin
                $fclose(fi);
                $display("done, %0d I2S bits; big log entry 0: %h", nbits, dut.link.log_big[0]);
                $finish;
            end
            $sformat(name, "hwtest-%0d.ppm", dut.page);
            f = $fopen(name, "w");
            $fwrite(f, "P3\n1280 720\n255\n");
        end
        if (s1 && frame > 0) $fwrite(f, "%0d %0d %0d\n", ch1, ch2, ch3);
        pvs = s0;
    end
    always @(posedge ab) begin
        $fwrite(fi, "%0d %0d %0d\n", al, ad, dut.aud.mode);
        nbits = nbits + 1;
    end
endmodule
