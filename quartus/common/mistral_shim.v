// Pass-through stand-in for nextpnr's MISTRAL_CLKBUF so open-flow designs can be timing-checked
// in Quartus (the real PLL clock is patched in after nextpnr; see notes/pll.md).
module MISTRAL_CLKBUF (input wire A, output wire Q);
    assign Q = A;
endmodule
