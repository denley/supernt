// Behavioural x16 SDRAM (two x8 chips in parallel) for simulating sdram_test.sv: CL3,
// full-page bursts, BURST TERMINATE, small array (bank, 2 row bits, 10 column bits). Read data
// goes invalid tOH = 2.7 ns after a clock edge and valid tAC = 5.4 ns after it.
`timescale 1ns/1ps
module sdram_model (
    input  wire        clk, cs_n, ras_n, cas_n, we_n,
    input  wire [11:0] a,
    input  wire [1:0]  ba,
    inout  wire [15:0] dq
);
    reg [15:0] mem [0:16383];
    reg [11:0] row [0:3];
    reg [15:0] dq_drv = 16'hzzzz;
    reg        drive = 1'b0;
    assign dq = drive ? dq_drv : 16'hzzzz;
    reg        wr = 0, rd = 0;
    reg [1:0]  bk;
    reg [9:0]  col;
    reg [15:0] pipe [0:2];
    reg [2:0]  pv = 0;
    integer    i, errs = 0;
    wire [3:0] c = {cs_n, ras_n, cas_n, we_n};
    initial for (i = 0; i < 16384; i = i + 1) mem[i] = 16'h0000;
    always @(posedge clk) begin
        // read pipeline (CL3): word pushed at edge n leaves at edge n+2 (counting the READ edge
        // as the first push, its data is valid after edge READ+3)
        if (pv[2]) begin
            dq_drv <= #2.7 16'hxxxx;
            dq_drv <= #5.4 pipe[2];
            drive  <= #2.0 1'b1;
        end else
            drive <= #2.7 1'b0;
        pipe[2] <= pipe[1]; pipe[1] <= pipe[0];
        pv <= {pv[1:0], 1'b0};
        case (c)
            4'b0011: row[ba] <= a;                                   // ACT
            4'b0100: begin wr <= 1; rd <= 0; bk <= ba; col <= 1;     // WRITE (first word now)
                     mem[{ba, row[ba][1:0], 10'd0}] <= dq; end
            4'b0101: begin rd <= 1; wr <= 0; bk <= ba; col <= 1;     // READ
                     pipe[0] <= mem[{ba, row[ba][1:0], 10'd0}]; pv[0] <= 1; end
            4'b0110, 4'b0010, 4'b0001, 4'b0000: begin wr <= 0; rd <= 0; end   // BST PRE REF MRS
            default: begin                                           // NOP / deselect: burst goes on
                if (wr) begin mem[{bk, row[bk][1:0], col}] <= dq; col <= col + 1; end
                if (rd) begin pipe[0] <= mem[{bk, row[bk][1:0], col}]; pv[0] <= 1; col <= col + 1; end
            end
        endcase
    end
endmodule
