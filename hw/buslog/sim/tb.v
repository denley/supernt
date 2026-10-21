// Simulates buslog: feeds a few fake PIC32 transactions, then dumps one video frame as a PPM.
// Run: make sim-buslog  (writes build/sim/buslog.ppm)
`timescale 1ns/1ps
module tb;
    reg clk = 0;
    always #6.734 clk = ~clk;   // 74.25 MHz
    reg  [3:0] strobe = 4'hf;
    reg  [7:0] data = 8'h00;
    reg  [3:0] xin = 4'h5;
    wire pclk, s0, s1, s2;
    wire [7:0] ch1, ch2, ch3;
    top #(.SYNC_PERM(0)) dut (.clk(clk), .pclk(pclk), .s0(s0), .s1(s1), .s2(s2),
        .ch1(ch1), .ch2(ch2), .ch3(ch3), .strobe(strobe), .data(data), .xin(xin));

    integer i, f, px, line, frame_started;
    task write_byte(input [7:0] b);
        begin
            data = b; #100;
            strobe = 4'b1101; #120;      // pretend bit 1 is a write strobe
            strobe = 4'b1111; #200;
        end
    endtask

    initial begin
        #1000;
        for (i = 0; i < 37; i = i + 1)
            write_byte(8'ha0 + i);
        // Wait for a frame start (perm 0: s1 = vsync), then dump the active area.
        @(posedge s1); @(negedge s1);
        f = $fopen("build/sim/buslog.ppm", "w");
        $fwrite(f, "P3\n1280 720\n255\n");
        line = 0;
        while (line < 720) begin
            @(posedge clk);
            // de is s2 in perm 0
            if (s2) begin
                for (px = 0; px < 1280; px = px + 1) begin
                    $fwrite(f, "%0d %0d %0d\n", ch1, ch2, ch3);
                    @(posedge clk);
                end
                line = line + 1;
            end
        end
        $fclose(f);
        $finish;
    end
endmodule
