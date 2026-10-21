; =============================================================================
; sa1test.asm - SA-1 bring-up test ROM for the Super Nt SNES core (asar 1.9x)
; =============================================================================
;
; Build:  make testrom   (build/snes/sa1test.sfc + build/snes/sa1test.hex)
;   asar assembles one 8 KB block at $00:E000-$FFFF (file $6000-$7FFF, header
;   and vectors included); `rom2hex.py --mirror` then copies that block to file
;   $0000/$2000/$4000 and writes the checksum into all four copies.  The FPGA
;   keeps only 8 KB and ignores ROM address bits >= 13, so the 32 KB image is
;   4 identical 8 KB blocks and everything below lives in one block.
;
; Cartridge header ($00:FFB0-$FFFF, file $7FB0): title "SUPERNT SA1 TEST",
;   map mode $23 (SA-1), type $35 (ROM+SA-1+RAM+battery), ROM $05 (32 KB),
;   RAM $01 (2 KB BW-RAM), region $01 (NTSC), checksum fixed by --mirror.
;
; -----------------------------------------------------------------------------
; Screen (224 lines, brightness 15, black backdrop; SNES pixel coordinates,
; x 0-255, y 0-223).  BG1 mode 0 with solid 8x8 tiles, BG1VOFS = -1 so BG row y
; is screen row y; sprites are 16x16, OAM Y = screen row of the top line.
;
;   rows  16- 31, x 16-239 : SUMMARY band: green $03E0 = all tests passed,
;                            red $001F = any test failed,
;                            dark grey $294A = some test still pending
;   rows  48- 55, x 16-239 : test 0  \   each: green $03E0 = pass,
;   rows  64- 71, x 16-239 : test 1   |        red   $001F = fail,
;   rows  80- 87, x 16-239 : test 2   |        dark grey $294A = pending
;   rows  96-103, x 16-239 : test 3   |  (test k: rows 48+16k .. 55+16k;
;   rows 112-119, x 16-239 : test 4   |   the 8 rows below each band are black)
;   rows 128-135, x 16-239 : test 5   |
;   rows 144-151, x 16-239 : test 6  /
;   rows 176-191           : cyan  $7FE0 16x16 sprite, SA-1 alive:
;                            x = 16 + ((SA-1 counter bits 10-17) mod 208)
;                            (counter = 24-bit I-RAM $3048, incremented by the
;                            SA-1 forever after its tests; still if SA-1 dead)
;   rows 192-207           : white $7FFF 16x16 sprite, SNES heartbeat:
;                            x = 16 + (frame counter mod 208), +1 px per frame
;   everything else        : black $0000
;
; The BG1 tilemap is static (from ROM); band b (0 = summary, 1+k = test k) uses
; BG palette b, and its status colour is CGRAM entry 4b+1, rewritten by every
; NMI from WRAM $0020+2b.
;
; -----------------------------------------------------------------------------
; Tests (N = 7).  The SA-1 does the work and stores results in I-RAM; the SNES
; compares them with constants computed by asar (also printed at build time).
;   0 SA-1 boot: SNES clears I-RAM $3000-$307F (and reads it back), writes the
;     token $5AC3 to $3040, sets CRV/CNV/CIV and releases the SA-1 via $2200.
;     SA-1 writes "SA1!" to $3000-$3003 and token^$FFFF ($A53C) to $3004.
;   1 Multiplier ($2250=0, signed 16x16): -12345*23456 = $EEBD9960,
;     -30000*-31000 = $376EAC80 -> $3008-$300F.
;   2 Divider ($2250=1, signed/unsigned): 30123/97 = 310 r 53,
;     28000/40000 = 0 r 28000 (divisor > $7FFF must be unsigned) -> $3010-$3017.
;     Only positive dividends: for negative ones this core (truncating),
;     real hardware (floor) and Mesen2 (floor, but R=divisor when exact) differ.
;   3 Multiply-accumulate ($2250=2): 5*(-32768*-32768) + 12345*-6789
;     = $013B012863 (40 bit, bit 32 set), overflow flag $230B = $00
;     -> $3018-$301D.
;   4 BW-RAM: SA-1 writes 256 bytes v(i) = ($A7 + i*$4D) & $FF to BW-RAM offset
;     i*7 ($000-$6F9, all 11 address bits) via $40:xxxx.  SNES reads them via
;     $00:6000-$66F9 (BMAPS=0), then writes v(i)^$FF to the first 16 of them and
;     reads those back (SNES write path, SBWE).  Needs the SA-1 done marker.
;   5 SA-1 ROM reads: Fletcher-16 style sums (s1 += byte, s2 += s1, 16 bit)
;     over the 128-byte RomTable, read by the SA-1 through three views:
;     $00:RomTable (LoROM window), $C0:(RomTable-$8000) (linear bank $C0) and
;     $00:(RomTable-$6000) (the copy in the first 8 KB block)
;     -> $3020-$302B, all three must equal the asar-computed sums
;     (s1 = $42A8, s2 = $B290).
;   6 Messaging: SNES checks $2300 == $00, writes message 5 to $2200
;     (SA-1 keeps running), SA-1 sees $2301 & $0F == 5, stores it at $3031 and
;     writes $2209 = $8A (SNES IRQ flag + message $A; SIE=0 so no IRQ line).
;     SNES expects $2300 == $8A, clears the flag with $2202 = $80, then expects
;     $2300 == $0A.  Needs the SA-1 done marker.
;   A dead SA-1 is detected by a timeout of ~1 frame (TIMEOUT loop iterations)
;   while waiting for the done marker $3030 = $C3; tests 1-6 are then red
;   (test 0 too unless the SA-1 got as far as the signature).
;
; Results in SNES WRAM (for the simulator):
;   $7E:0100+k   result of test k: 0 = pending, 1 = pass, 2 = fail
;   $7E:00FF     number of tests N (7)
;   $7E:00FE     $A5 once all tests are evaluated (status colours updated; the
;                next NMI writes them to CGRAM, so the following frame shows
;                the final screen)
;   $7E:00FC-FD  16-bit frame counter (NMIs since reset; NMI is enabled a few
;                hundred cycles after reset)
;
; I-RAM layout (same addresses $3000-$37FF from SNES and SA-1):
;   $3000-$3005 test 0, $3008-$300F test 1, $3010-$3017 test 2,
;   $3018-$301D test 3, $3020-$302B test 5, $3030 done marker ($C3),
;   $3031 message seen by SA-1, $3040-$3041 SNES token, $3048-$304A SA-1 alive
;   counter, $3080-$308F SA-1 direct page scratch, $3700-$37FF SA-1 stack.
;
; Timing (Mesen2, reset at scanline 0): the SA-1 is released at line 14, the
; PPU setup (~3.3 KB of DMA, forced blank) is done at line 50, the SA-1 is done
; at line 68 and all results are final at line 125 of the first frame.  The
; first NMI (line 225) turns the display on, so the first displayed frame
; (the 2nd frame after reset) already shows the final result.  With a dead
; SA-1 the ~1 frame timeout ends in the 2nd frame and the 3rd frame shows red.
; =============================================================================

asar 1.90
sa1rom

; ---- SNES WRAM variables (direct page, D = $0000) ---------------------------
!PtrA       = $00       ; CmpBlock: I-RAM address
!PtrB       = $02       ; CmpBlock: expected-table address
!Count      = $04       ; CmpBlock: byte count
!TmpV       = $06       ; scratch
!VideoReady = $10       ; NMI may update CGRAM/OAM and enable the display
!Sa1Done    = $12       ; SA-1 done marker seen
!IramOk     = $13       ; SNES I-RAM clear/readback/token write succeeded
!HbX        = $14       ; heartbeat sprite x
!Sa1X       = $15       ; SA-1 alive sprite x
!BandCol    = $20       ; 8 x BGR555: band 0 = summary, band 1+k = test k
!FrameCount = $FC       ; 16-bit
!AllDone    = $FE       ; $A5 when done
!NumTests   = $FF
!Results    = $0100     ; $0100+k

!N          = 7
!TIMEOUT    = 3600      ; wait-loop iterations of ~98 master clocks ~ 1 frame

; ---- VRAM layout (word addresses) -------------------------------------------
!VRAM_BGTILES = $0000   ; BG1 2bpp: tile 0 = blank, tile 1 = solid colour 1
!VRAM_BGMAP   = $0400   ; BG1 32x32 tilemap
!VRAM_OBJ     = $2000   ; OBJ name base: tiles 0,1,16,17 = solid colour 1

; ---- colours (BGR555) -------------------------------------------------------
!C_GREY  = $294A
!C_GREEN = $03E0
!C_RED   = $001F
!C_WHITE = $7FFF
!C_CYAN  = $7FE0

; ---- I-RAM addresses --------------------------------------------------------
!I_SIG   = $3000
!I_TOKEN = $3004
!I_MUL   = $3008
!I_DIV   = $3010
!I_MAC   = $3018
!I_SUM   = $3020
!I_DONE  = $3030
!I_MSG   = $3031
!I_SNTOK = $3040
!I_ALIVE = $3048

!TOKEN   = $5AC3
!DONE    = $C3

; ---- test operands ----------------------------------------------------------
!MUL_A0 = (-12345)
!MUL_B0 = 23456
!MUL_A1 = (-30000)
!MUL_B1 = (-31000)
!DIV_A0 = 30123
!DIV_B0 = 97
!DIV_A1 = 28000
!DIV_B1 = 40000
!MAC_A  = (-32768)      ; 5 times MAC_A*MAC_B ...
!MAC_B  = (-32768)
!MAC_C  = 12345         ; ... plus MAC_C*MAC_D
!MAC_D  = (-6789)
!MAC_SUM #= 5*(!MAC_A*!MAC_B)+(!MAC_C*!MAC_D)

!BW_SEED = $A7
!BW_STEP = $4D
!BW_STRIDE = 7          ; 255*7 = $6F9 < $800: no wrap, all 11 address bits

!SUM_LEN = 128

; -----------------------------------------------------------------------------
; macros
; -----------------------------------------------------------------------------
; DMA channel 0, A bus (bank $00) -> B bus $21<bbus>; mode | $08 = fixed source
macro Dma(mode, bbus, src, count)
    lda.b #<mode>
    sta $4300
    lda.b #<bbus>
    sta $4301
    ldx.w #<src>
    stx $4302
    stz $4304
    ldx.w #<count>
    stx $4305
    lda.b #$01
    sta $420B
endmacro

; compare <n> bytes at I-RAM <iram> with ROM <exp>, store 1/2 in result k
macro CheckBlock(k, iram, exp, n)
    ldx.w #<iram>
    stx !PtrA
    ldx.w #<exp>
    stx !PtrB
    ldy.w #<n>
    jsr CmpBlock
    sta.w !Results+<k>
endmacro

macro Inx7()
    inx
    inx
    inx
    inx
    inx
    inx
    inx
endmacro

; =============================================================================
org $00E000
; =============================================================================

; -----------------------------------------------------------------------------
; SNES reset
; -----------------------------------------------------------------------------
Reset:
    sei
    clc
    xce                         ; native mode
    rep #$38                    ; A/X/Y 16 bit, decimal off
    ldx.w #$1FFF
    txs
    lda.w #$0000
    tcd
    sep #$20                    ; A 8 bit (X/Y stay 16 bit throughout)
    phk
    plb                         ; DB = $00
    lda.b #$80
    sta $2100                   ; forced blank
    stz $4200                   ; NMI/IRQ/auto-joypad off
    stz $420B
    stz $420C                   ; no (H)DMA
    stz $420D                   ; SlowROM

    ; clear WRAM $0000-$01FF (variables + results)
    ldx.w #$0000
    stx $2181
    stz $2183
    %Dma($08, $80, Zero, $200)
    lda.b #!N
    sta !NumTests

    ; NMI on from here (only counts frames until !VideoReady is set)
    lda $4210
    lda.b #$80
    sta $4200

    ; ---- SA-1 setup (SA-1 is in reset after power-on; make sure) ----
    lda.b #$20
    sta $2200                   ; CCNT: SA-1 reset, no message
    stz $2201                   ; SIE: no SA-1 IRQs to the SNES
    lda.b #$A0
    sta $2202                   ; SIC: clear SA-1 IRQ / CC-DMA IRQ flags
    rep #$20
    lda.w #Sa1Reset
    sta $2203                   ; CRV  (SA-1 reset vector)
    lda.w #Sa1Stub
    sta $2205                   ; CNV  (SA-1 NMI vector)
    sta $2207                   ; CIV  (SA-1 IRQ vector)
    sep #$20
    stz $2220                   ; CXB = 0  (banks $C0-$CF = ROM 1st MB)
    lda.b #$01
    sta $2221                   ; DXB = 1
    inc
    sta $2222                   ; EXB = 2
    inc
    sta $2223                   ; FXB = 3
    stz $2224                   ; BMAPS: SNES $6000-$7FFF = BW-RAM $0000-$1FFF
    lda.b #$80
    sta $2226                   ; SBWE: SNES may write BW-RAM
    stz $2228                   ; BWPA: protected area = first 256 bytes only
    lda.b #$FF
    sta $2229                   ; SIWP: SNES may write all of I-RAM

    ; clear I-RAM $3000-$307F, read it back, write and read back the token
    rep #$20
    ldx.w #$007E
-   stz $3000,x
    dex
    dex
    bpl -
    ldx.w #$007E
-   lda $3000,x
    bne .iramBad
    dex
    dex
    bpl -
    lda.w #!TOKEN
    sta !I_SNTOK
    lda !I_SNTOK
    cmp.w #!TOKEN
    bne .iramBad
    sep #$20
    lda.b #$01
    sta !IramOk
.iramBad:
    sep #$20

    stz $2200                   ; release the SA-1 (starts at CRV)

    jsr SetColours              ; all bands grey (pending)

    ; ---- PPU setup (forced blank) ----
    ldx.w #$0000
-   lda.w PpuInit,x
    cmp.b #$FF
    beq +
    rep #$20
    and.w #$00FF
    tay
    sep #$20
    lda.w PpuInit+1,x
    sta $2100,y
    inx
    inx
    bra -
+
    ; VRAM: BG1 tilemap, BG tiles, OBJ tiles
    lda.b #$80
    sta $2115                   ; VMAIN: increment after $2119
    ldx.w #!VRAM_BGMAP
    stx $2116
    %Dma($01, $18, BgMap, BgMapEnd-BgMap)
    ldx.w #!VRAM_BGTILES
    stx $2116
    %Dma($01, $18, BgTiles, 32)
    ldx.w #!VRAM_OBJ
    stx $2116
    %Dma($01, $18, ObjTiles, 64)        ; OBJ tiles 0, 1
    ldx.w #!VRAM_OBJ+$100
    stx $2116
    %Dma($01, $18, ObjTiles, 64)        ; OBJ tiles 16, 17

    ; CGRAM: all black, then the sprite colours (band colours come from NMI)
    stz $2121
    %Dma($08, $22, Zero, $200)
    lda.b #129
    sta $2121
    lda.b #!C_WHITE&$FF         ; OBJ palette 0 colour 1
    sta $2122
    lda.b #!C_WHITE>>8
    sta $2122
    lda.b #145
    sta $2121
    lda.b #!C_CYAN&$FF          ; OBJ palette 1 colour 1
    sta $2122
    lda.b #!C_CYAN>>8
    sta $2122

    ; OAM: all sprites X=Y=$E0 (off screen, 8x8), high table 0;
    ; then sprites 0 and 1 large (16x16)
    stz $2102
    stz $2103
    %Dma($08, $04, FillE0, $200)
    %Dma($08, $04, Zero, $20)
    stz $2102
    lda.b #$01
    sta $2103                   ; OAM word $100 = high table byte 0
    lda.b #$0A
    sta $2104                   ; sprites 0,1: size large, X bit 8 = 0

    lda.b #$01
    sta !VideoReady             ; next NMI writes colours/OAM, display on

    ; ---- wait for the SA-1 done marker (timeout ~1 frame) ----
    ldx.w #!TIMEOUT
-   lda !I_DONE
    cmp.b #!DONE
    beq .sa1Done
    dex
    bne -
    bra .evaluate
.sa1Done:
    lda.b #$01
    sta !Sa1Done

.evaluate:
    ; test 0: I-RAM setup ok, signature and token echo
    %CheckBlock(0, !I_SIG, Exp0, Exp0End-Exp0)
    lda !IramOk
    bne +
    lda.b #$02
    sta !Results+0
+
    %CheckBlock(1, !I_MUL, ExpMul, ExpMulEnd-ExpMul)
    %CheckBlock(2, !I_DIV, ExpDiv, ExpDivEnd-ExpDiv)
    %CheckBlock(3, !I_MAC, ExpMac, ExpMacEnd-ExpMac)
    jsr CheckBwRam
    sta !Results+4
    %CheckBlock(5, !I_SUM, ExpSum, ExpSumEnd-ExpSum)
    jsr CheckMessage
    sta !Results+6

    jsr SetColours
    lda.b #$A5
    sta !AllDone

    jsr SpcUpload               ; then a steady A major chord from the S-DSP

Forever:
    wai
    bra Forever

; -----------------------------------------------------------------------------
; SpcUpload: A8 XY16.  Sends SpcBlock to S-SMP RAM $0200 through the IPL ROM's
; $2140-$2143 protocol and starts it at $0210 (after the SA-1 tests, so their
; timing is unchanged).  The S-SMP program loads the S-DSP registers from its
; table and keys on voices 0-2: square waves at 440, 554 and 659 Hz (the same
; chord as tools/mkspc.py), so a working audio path is audible.
; -----------------------------------------------------------------------------
SpcUpload:
-   lda $2140
    cmp.b #$AA
    bne -
-   lda $2141
    cmp.b #$BB
    bne -
    stz $2142                   ; destination $0200
    lda.b #$02
    sta $2143
    lda.b #$01
    sta $2141                   ; non-zero: transfer
    lda.b #$CC
    sta $2140
-   cmp $2140
    bne -
    ldx.w #$0000
.byte:
    lda SpcBlock,x
    sta $2141
    txa
    sta $2140
-   cmp $2140
    bne -
    inx
    cpx.w #SpcBlockEnd-SpcBlock
    bne .byte
    lda.b #$10                  ; run from $0210
    sta $2142
    lda.b #$02
    sta $2143
    stz $2141                   ; zero: jump
    txa
    inc a                       ; last index + 2
    sta $2140
-   cmp $2140
    bne -
    rts

; S-SMP image for $0200 (hand-assembled SPC700).
SpcBlock:
    db $04,$02,$04,$02          ; $0200 directory: sample 0 start/loop = $0204
    db $B3,$77,$77,$77,$77,$88,$88,$88,$88 ; $0204 BRR: one looping block, square
    db $00,$00,$00              ; $020D pad
    db $CD,$00                  ; $0210 mov x,#$00
    db $F5,$30,$02              ; $0212 loop: mov a,$0230+x
    db $C4,$F2                  ;       mov $F2,a      (DSP register)
    db $3D                      ;       inc x
    db $F5,$30,$02              ;       mov a,$0230+x
    db $C4,$F3                  ;       mov $F3,a      (value)
    db $3D                      ;       inc x
    db $C8,SpcTableEnd-SpcTable ;       cmp x,#len
    db $D0,$F0                  ;       bne loop
    db $8F,$4C,$F2              ; $0222 mov $F2,#$4C   (KON)
    db $8F,$07,$F3              ;       mov $F3,#$07   (voices 0-2)
    db $2F,$FE                  ; $0228 bra *
    db $00,$00,$00,$00,$00,$00  ; $022A pad
SpcTable:                       ; $0230 (DSP register, value)
    db $6C,$20                  ; FLG: unmute, echo writes off
    db $5D,$02                  ; DIR = $0200
    db $0C,$30,$1C,$30          ; main volume
    db $2C,$00,$3C,$00          ; echo volume 0
    db $5C,$00,$3D,$00,$4D,$00,$2D,$00 ; KOF, NON, EON, PMON off
    db $00,$20,$01,$20,$02,$85,$03,$03,$04,$00,$05,$00,$07,$7F ; v0 440 Hz
    db $10,$20,$11,$20,$12,$6F,$13,$04,$14,$00,$15,$00,$17,$7F ; v1 554 Hz
    db $20,$20,$21,$20,$22,$46,$23,$05,$24,$00,$25,$00,$27,$7F ; v2 659 Hz
SpcTableEnd:
SpcBlockEnd:
assert SpcTable-SpcBlock == $30, "S-SMP table must sit at $0230"

; -----------------------------------------------------------------------------
; CmpBlock: A8 XY16.  (PtrA),y vs (PtrB),y for y < Y.  Returns A = 1 / 2.
; -----------------------------------------------------------------------------
CmpBlock:
    sty !Count
    ldy.w #$0000
-   lda (!PtrA),y
    cmp (!PtrB),y
    bne .fail
    iny
    cpy !Count
    bne -
    lda.b #$01
    rts
.fail:
    lda.b #$02
    rts

; -----------------------------------------------------------------------------
; CheckBwRam: test 4.  A8 XY16.  Returns A = 1 / 2.
; -----------------------------------------------------------------------------
CheckBwRam:
    lda !Sa1Done
    beq .fail
    ldx.w #$0000                ; BW-RAM offset i*7
    ldy.w #256
    lda.b #!BW_SEED             ; v(i)
-   cmp $6000,x
    bne .fail
    clc
    adc.b #!BW_STEP
    %Inx7()
    dey
    bne -
    ; SNES write path: v(i)^$FF = (~seed - i*step) to the first 16, read back
    ldx.w #$0000
    ldy.w #16
    lda.b #!BW_SEED^$FF
-   sta $6000,x
    cmp $6000,x
    bne .fail
    sec
    sbc.b #!BW_STEP
    %Inx7()
    dey
    bne -
    lda.b #$01
    rts
.fail:
    lda.b #$02
    rts

; -----------------------------------------------------------------------------
; CheckMessage: test 6.  A8 XY16.  Returns A = 1 / 2.
; -----------------------------------------------------------------------------
CheckMessage:
    lda !Sa1Done
    beq .fail
    lda $2300                   ; SFR: nothing sent by the SA-1 yet
    bne .fail
    lda.b #$05
    sta $2200                   ; message 5 to the SA-1 (keep it running)
    ldx.w #2000                 ; ~0.5 frame
-   lda $2300
    cmp.b #$8A                  ; IRQ flag + message $A
    beq +
    dex
    bne -
    bra .fail
+   lda.b #$80
    sta $2202                   ; SIC: clear the IRQ flag
    lda $2300
    cmp.b #$0A
    bne .fail
    lda !I_MSG
    cmp.b #$05
    bne .fail
    lda.b #$01
    rts
.fail:
    lda.b #$02
    rts

; -----------------------------------------------------------------------------
; SetColours: band status colours from the results.  A8 XY16.
; Summary: any fail -> fail, else any pending -> pending, else pass.
; -----------------------------------------------------------------------------
SetColours:
    lda.b #$01
    sta !TmpV
    ldx.w #$0000
-   lda.w !Results,x
    cmp.b #$01
    beq .next
    cmp.b #$00
    bne .failed
    stz !TmpV                   ; pending
.next:
    inx
    cpx.w #!N
    bne -
    bra .summary
.failed:
    lda.b #$02
    sta !TmpV
.summary:
    lda !TmpV
    ldx.w #$0000
    jsr SetBand
    ldx.w #$0000                ; k
-   phx
    lda.w !Results,x
    pha
    rep #$20
    txa
    inc
    asl
    tax                         ; X = 2*(k+1)
    sep #$20
    pla
    jsr SetBand
    plx
    inx
    cpx.w #!N
    bne -
    rts

; A8 = status (0 pending, 1 pass, else fail), X = 2*band
SetBand:
    rep #$20
    and.w #$00FF
    cmp.w #$0003
    bcc +
    lda.w #$0002
+   asl
    tay
    lda.w StatusCol,y
    sta !BandCol,x              ; one 16-bit store: atomic for the NMI
    sep #$20
    rts

StatusCol:
    dw !C_GREY, !C_GREEN, !C_RED

; -----------------------------------------------------------------------------
; SNES NMI: frame counter; once video is ready: band colours, sprites, display
; -----------------------------------------------------------------------------
Nmi:
    rep #$30
    pha
    phx
    phy
    phb
    phd
    lda.w #$0000
    tcd
    sep #$20
    phk
    plb
    lda $4210                   ; acknowledge NMI
    rep #$20
    inc !FrameCount
    sep #$20
    lda !VideoReady
    bne +
    jmp .exit
+
    ; heartbeat: x = 16 + frame mod 208 (hardware divider, 16 cycles)
    rep #$20
    lda !FrameCount
    sta $4204
    sep #$20
    lda.b #208
    sta $4206
    ; SA-1 alive: x = 16 + (counter bits 10-17) mod 208
    rep #$20
    lda !I_ALIVE+1              ; counter bits 8-23
    lsr
    lsr
    sep #$20
    cmp.b #208
    bcc +
    sbc.b #208
+   clc
    adc.b #16
    sta !Sa1X
    lda $4216                   ; remainder (>= 16 cycles after $4206)
    clc
    adc.b #16
    sta !HbX
    ; band colours: CGRAM 4b+1 = BandCol[b]
    ldx.w #$0000                ; 2*b
-   txa
    asl
    inc
    sta $2121
    lda !BandCol,x
    sta $2122
    lda !BandCol+1,x
    sta $2122
    inx
    inx
    cpx.w #16
    bne -
    ; OAM sprites 0 (SA-1 alive, palette 1) and 1 (heartbeat, palette 0)
    stz $2102
    stz $2103
    lda !Sa1X
    sta $2104
    lda.b #176
    sta $2104
    stz $2104                   ; tile 0
    lda.b #$32                  ; priority 3, palette 1
    sta $2104
    lda !HbX
    sta $2104
    lda.b #192
    sta $2104
    stz $2104
    lda.b #$30                  ; priority 3, palette 0
    sta $2104
    lda.b #$0F
    sta $2100                   ; display on, brightness 15
.exit:
    rep #$30
    pld
    plb
    ply
    plx
    pla
Stub:
    rti

; =============================================================================
; SA-1 program (starts in emulation mode at CRV)
; =============================================================================
Sa1Stub:
    rti

Sa1Reset:
    sei
    clc
    xce                         ; native
    rep #$18                    ; X/Y 16 bit, decimal off (A stays 8 bit)
    lda.b #$FF
    sta $222A                   ; CIWP: SA-1 may write all I-RAM (reset clears it)
    lda.b #$80
    sta $2227                   ; CBWE: SA-1 may write BW-RAM
    stz $2225                   ; BMAP: $6000-$7FFF = BW-RAM block 0
    stz $220A                   ; CIE: no SA-1 interrupts
    stz $2210                   ; TMC: timer off
    stz $2230                   ; DCNT: SA-1 DMA off
    stz $223F                   ; BBF
    ldx.w #$37FF
    txs                         ; stack at the top of I-RAM
    rep #$20
    lda.w #$3000
    tcd                         ; direct page = I-RAM $3000
    phk
    plb                         ; DB = $00

    ; ---- test 0: signature + token echo ----
    lda.w #$4153                ; "SA"
    sta !I_SIG
    lda.w #$2131                ; "1!"
    sta !I_SIG+2
    lda !I_SNTOK
    eor.w #$FFFF
    sta !I_TOKEN

    ; ---- test 1: signed multiply ----
    sep #$20
    stz $2250                   ; MCNT = 0: multiplication
    rep #$20
    lda.w #(!MUL_A0)&$FFFF
    sta $2251                   ; MA
    lda.w #(!MUL_B0)&$FFFF
    sta $2253                   ; MB (writing $2254 starts the operation)
    jsr MathWait
    lda $2306
    sta !I_MUL
    lda $2308
    sta !I_MUL+2
    lda.w #(!MUL_A1)&$FFFF
    sta $2251
    lda.w #(!MUL_B1)&$FFFF
    sta $2253
    jsr MathWait
    lda $2306
    sta !I_MUL+4
    lda $2308
    sta !I_MUL+6

    ; ---- test 2: signed / unsigned divide ----
    sep #$20
    lda.b #$01
    sta $2250                   ; MCNT = 1: division
    rep #$20
    lda.w #!DIV_A0
    sta $2251
    lda.w #!DIV_B0
    sta $2253
    jsr MathWait
    lda $2306                   ; quotient
    sta !I_DIV
    lda $2308                   ; remainder
    sta !I_DIV+2
    lda.w #!DIV_A1
    sta $2251
    lda.w #!DIV_B1
    sta $2253
    jsr MathWait
    lda $2306
    sta !I_DIV+4
    lda $2308
    sta !I_DIV+6

    ; ---- test 3: multiply-accumulate ----
    sep #$20
    lda.b #$02
    sta $2250                   ; MCNT = 2: cumulative sum (clears the sum)
    rep #$20
    ldx.w #5
-   lda.w #(!MAC_A)&$FFFF
    sta $2251
    lda.w #(!MAC_B)&$FFFF
    sta $2253
    jsr MathWait
    dex
    bne -
    lda.w #(!MAC_C)&$FFFF
    sta $2251
    lda.w #(!MAC_D)&$FFFF
    sta $2253
    jsr MathWait
    lda $2306
    sta !I_MAC
    lda $2308
    sta !I_MAC+2
    sep #$20
    lda $230A
    sta !I_MAC+4
    lda $230B                   ; overflow flag (bit 7)
    sta !I_MAC+5

    ; ---- test 4: BW-RAM pattern v(i) at offset i*7 ----
    ldx.w #$0000
    ldy.w #256
    lda.b #!BW_SEED
-   sta.l $400000,x
    clc
    adc.b #!BW_STEP
    %Inx7()
    dey
    bne -

    ; ---- test 5: ROM checksums through three address views ----
    ldx.w #RomTable
    lda.b #$00
    ldy.w #!I_SUM
    jsr Fletcher
    ldx.w #RomTable-$8000
    lda.b #$C0
    ldy.w #!I_SUM+4
    jsr Fletcher
    ldx.w #RomTable-$6000
    lda.b #$00
    ldy.w #!I_SUM+8
    jsr Fletcher

    ; ---- all done ----
    lda.b #!DONE
    sta !I_DONE

    ; ---- forever: alive counter + answer message 5 once ----
Sa1Alive:
    rep #$20
    inc !I_ALIVE
    bne +
    inc !I_ALIVE+2
+   sep #$20
    lda !I_MSG
    bne Sa1Alive
    lda $2301                   ; CFR: message from the SNES in bits 0-3
    and.b #$0F
    cmp.b #$05
    bne Sa1Alive
    sta !I_MSG
    lda.b #$8A
    sta $2209                   ; SCNT: SNES IRQ flag + message $A
    bra Sa1Alive

; >= 16 SA-1 cycles from the $2254 write to the next math register access
; (multiply/divide need 5 cycles, cumulative sum 6)
MathWait:
    nop
    nop
    rts

; Fletcher-style sum over RomTable.  In: X = address, A8 = bank,
; Y = I-RAM destination for s1, s2 (4 bytes).  A8 XY16 on entry and exit.
Fletcher:
    stx $80
    sta $82
    sty $8A
    rep #$20
    stz $84
    stz $86
    ldy.w #$0000
-   lda [$80],y
    and.w #$00FF
    clc
    adc $84
    sta $84
    clc
    adc $86
    sta $86
    iny
    cpy.w #!SUM_LEN
    bne -
    ldy.w #$0000
    lda $84
    sta ($8A),y
    ldy.w #$0002
    lda $86
    sta ($8A),y
    sep #$20
    rts

; =============================================================================
; data
; =============================================================================
Zero:
    dw $0000
FillE0:
    db $E0

; register (low byte of $21xx), value; $FF ends.  Scroll regs written twice.
PpuInit:
    db $01,$01                  ; OBSEL: 8x8/16x16, name base word $2000
    db $05,$00                  ; BGMODE: mode 0, 8x8 tiles
    db $06,$00                  ; MOSAIC off
    db $07,(!VRAM_BGMAP>>10)<<2 ; BG1SC: tilemap word $0400, 32x32
    db $08,$00,$09,$00,$0A,$00
    db $0B,$00,$0C,$00          ; BG chr base word $0000
    db $0D,$00,$0D,$00          ; BG1HOFS = 0
    db $0E,$FF,$0E,$03          ; BG1VOFS = $3FF (-1): BG row y on screen row y
    db $0F,$00,$0F,$00,$10,$00,$10,$00
    db $11,$00,$11,$00,$12,$00,$12,$00
    db $13,$00,$13,$00,$14,$00,$14,$00
    db $15,$80                  ; VMAIN
    db $1A,$00
    db $23,$00,$24,$00,$25,$00  ; windows off
    db $26,$00,$27,$00,$28,$00,$29,$00,$2A,$00,$2B,$00
    db $2C,$11                  ; TM: BG1 + OBJ
    db $2D,$00                  ; TS: none
    db $2E,$00,$2F,$00
    db $30,$00                  ; CGWSEL
    db $31,$00                  ; CGADSUB: no colour math
    db $32,$E0                  ; COLDATA = 0
    db $33,$00                  ; SETINI: 224 lines, no interlace
    db $FF

; BG1 2bpp tiles: 0 = colour 0, 1 = colour 1
BgTiles:
    fillbyte $00 : fill 16
    db $FF,$00,$FF,$00,$FF,$00,$FF,$00,$FF,$00,$FF,$00,$FF,$00,$FF,$00
; OBJ 4bpp tiles: two solid colour-1 tiles
ObjTiles:
    db $FF,$00,$FF,$00,$FF,$00,$FF,$00,$FF,$00,$FF,$00,$FF,$00,$FF,$00
    fill 16
    db $FF,$00,$FF,$00,$FF,$00,$FF,$00,$FF,$00,$FF,$00,$FF,$00,$FF,$00
    fill 16

; BG1 tilemap 32x32: tile rows 2-3 = summary (palette 0), tile row 6+2k =
; test k (palette 1+k), columns 2-29 (x 16-239); everything else tile 0.
BgMap:
for r = 0..32
    !pal #= -1
    if !r == 2 || !r == 3
        !pal #= 0
    elseif !r >= 6 && !r <= 4+2*!N && (!r&1) == 0
        !pal #= (!r-6)/2+1
    endif
    if !pal >= 0
        dw $0000, $0000
        for c = 0..28
            dw $0001|(!pal<<10)
        endfor
        dw $0000, $0000
    else
        for c = 0..32
            dw $0000
        endfor
    endif
endfor
BgMapEnd:

; expected results
Exp0:
    db $53,$41,$31,$21          ; "SA1!"
    dw (!TOKEN)^$FFFF
Exp0End:
ExpMul:
    dd (!MUL_A0*!MUL_B0)&$FFFFFFFF
    dd (!MUL_A1*!MUL_B1)&$FFFFFFFF
ExpMulEnd:
ExpDiv:
    dw floor(!DIV_A0/!DIV_B0), !DIV_A0-floor(!DIV_A0/!DIV_B0)*!DIV_B0
    dw floor(!DIV_A1/!DIV_B1), !DIV_A1-floor(!DIV_A1/!DIV_B1)*!DIV_B1
ExpDivEnd:
ExpMac:
    dd !MAC_SUM&$FFFFFFFF
    db (!MAC_SUM>>32)&$FF
    db $00                      ; overflow flag
ExpMacEnd:

; table for test 5, t(i) = ((7i^2 + 13i + $35) ^ (i^3 >> 5)) & $FF, + sums
RomTable:
!S1 = 0
!S2 = 0
for i = 0..!SUM_LEN
    !V #= ((!i*!i*7+!i*13+$35)^((!i*!i*!i)>>5))&$FF
    db !V
    !S1 #= (!S1+!V)&$FFFF
    !S2 #= (!S2+!S1)&$FFFF
endfor
    db $00                      ; 16-bit reads of the last byte read one more
ExpSum:
    dw !S1, !S2
    dw !S1, !S2
    dw !S1, !S2
ExpSumEnd:

print "code+data end:   $", hex(pc())
print "MUL0 = $", hex((!MUL_A0*!MUL_B0)&$FFFFFFFF, 8), "  MUL1 = $", hex((!MUL_A1*!MUL_B1)&$FFFFFFFF, 8)
print "DIV0 = ", dec(floor(!DIV_A0/!DIV_B0)), " r ", dec(!DIV_A0-floor(!DIV_A0/!DIV_B0)*!DIV_B0), "  DIV1 = ", dec(floor(!DIV_A1/!DIV_B1)), " r ", dec(!DIV_A1-floor(!DIV_A1/!DIV_B1)*!DIV_B1)
print "MAC  = $", hex(!MAC_SUM, 10)
print "SUM  = s1 $", hex(!S1, 4), " s2 $", hex(!S2, 4)
assert pc() <= $00FFB0, "code/data overlaps the header"

; =============================================================================
; cartridge header + vectors
; =============================================================================
org $00FFB0
    db "SN"                     ; $FFB0 maker code
    db "SA1T"                   ; $FFB2 game code
    db $00,$00,$00,$00,$00,$00,$00 ; $FFB6 reserved
    db $00                      ; $FFBD expansion RAM size
    db $00                      ; $FFBE special version
    db $00                      ; $FFBF cartridge sub-type
    db "SUPERNT SA1 TEST     "  ; $FFC0 title (21 bytes)
    db $23                      ; $FFD5 map mode: SA-1
    db $35                      ; $FFD6 ROM + SA-1 + RAM + battery
    db $05                      ; $FFD7 ROM size: 32 KB
    db $01                      ; $FFD8 RAM size: 2 KB
    db $01                      ; $FFD9 region: NTSC (North America)
    db $33                      ; $FFDA developer: extended header
    db $00                      ; $FFDB version
    dw $FFFF, $0000             ; $FFDC complement, checksum (set by --mirror)
    ; native vectors
    dw $0000, $0000             ; $FFE0
    dw Stub                     ; $FFE4 COP
    dw Stub                     ; $FFE6 BRK
    dw Stub                     ; $FFE8 ABORT
    dw Nmi                      ; $FFEA NMI
    dw $0000                    ; $FFEC
    dw Stub                     ; $FFEE IRQ
    ; emulation vectors
    dw $0000, $0000             ; $FFF0
    dw Stub                     ; $FFF4 COP
    dw $0000                    ; $FFF6
    dw Stub                     ; $FFF8 ABORT
    dw Stub                     ; $FFFA NMI
    dw Reset                    ; $FFFC RESET
    dw Stub                     ; $FFFE IRQ/BRK
