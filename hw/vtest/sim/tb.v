// Simulates vtest and dumps one video frame (sync order 0) to build/sim/vtest.ppm.
`timescale 1ns/1ps
module tb;
    reg clk = 0;
    always #6.734 clk = ~clk;
    wire pclk, s0, s1, s2;
    wire [7:0] ch1, ch2, ch3;
    top dut (.clk(clk), .pclk(pclk), .s0(s0), .s1(s1), .s2(s2), .ch1(ch1), .ch2(ch2), .ch3(ch3));
    integer f, px, line;
    initial begin
        @(posedge s1); @(negedge s1);
        f = $fopen("build/sim/vtest.ppm", "w");
        $fwrite(f, "P3\n1280 720\n255\n");
        line = 0;
        while (line < 720) begin
            @(posedge clk);
            if (s2) begin
                for (px = 0; px < 1280; px = px + 1) begin
                    // Show the proposed channel order as R, G, B.
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
