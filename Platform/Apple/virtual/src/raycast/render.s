
codeBeg = *

    .pc02 ; Enable 65c02 ops

; This code is written bottom-up. That is,
; simple routines first, then routines that
; call those to build complexity. The main
; code is at the very end. We jump to it now.
    jmp test

; Conditional assembly flags
DOUBLE_BUFFER = 0 ; whether to double-buffer
DEBUG = 0 ; turn on verbose logging

; Constants
TOP_LINE     = $2180 ; 24 lines down from top
NLINES       = 126
SKY_COLOR    = $11 ; blue
GROUND_COLOR = $2 ; orange / black
TEX_SIZE     = 5460

; My zero page
lineCt     = $3  ; len 1
txNum      = $4  ; len 1
txColNum   = $5  ; len 1
pLine      = $6  ; len 2
pDst       = $8  ; len 2
pTex       = $A  ; len 2
pixNum     = $C  ; len 1
byteNum    = $D  ; len 1
pTmp       = $E  ; len 2
tmp        = $10 ; len 2
bacKBuf    = $12 ; len 1 (value 0 or 1)
frontBuf   = $13 ; len 1 (value 0 or 1)
pRayData   = $14 ; len 2
playerX    = $16 ; len 2 (hi=integer, lo=fraction)
playerY    = $18 ; len 2 (hi=integer, lo=fraction)
playerDir  = $19 ; len 1
rayDirX    = $1A ; len 1
rayDirY    = $1B ; len 1
stepX      = $1C ; len 1
stepY      = $1D ; len 1
mapX       = $1E ; len 1
mapY       = $1F ; len 1
sideDistX  = $50 ; len 1
sideDistY  = $51 ; len 1
deltaDistX = $52 ; len 1
deltaDistY = $53 ; len 1
pMap       = $54 ; len 2
dist       = $56 ; len 2
diff       = $58 ; len 2

; Other monitor locations
resetVec = $3F2

; Place to stick ProDOS names temporarily
nameBuf = $280

; Tables and buffers
shiftA01 = $1000
shiftA23 = $1100
shiftA45 = $1200
shiftA56 = $1300
shiftA57 = $1400
shiftB01 = $1500
shiftB23 = $1600
shiftB45 = $1700
shiftB56 = $1800
shiftB57 = $1900
blitIndexLo = $1A00 ; size $80
blitIndexHi = $1A80 ; size $80
dcmIndexLo = $1B00 ; size $40 (one entry per two lines)
dcmIndexHi = $1B40 ; size $40
X1B80 = $1B80 ; unused
decimRoll = $1C00 ; size 11*(126/2) = 693 = $2B5, plus 1 for rts
clrBlitRoll = $1F00 ; size 3*(126/2) = 189 = $BD, plus 2 for tya & rts

prodosBuf = $1000 ; temporary, before tbls built
screen = $2000

textures = $4000 ; size $5550 (5460 bytes x 4 textures)
tex0 = textures
tex1 = tex0+TEX_SIZE
tex2 = tex1+TEX_SIZE
tex3 = tex2+TEX_SIZE
UN9550 = $9550 ; unused
blitRoll = $A000 ; size 29*126 = 3654 = $E80, plus 1 for rts
bumps = $AF00 ; len 64*64 = $1000
globalPage = $BF00 ; ProDOS global page
MLI = globalPage ; also the call point for ProDOS MLI
memMap = $BF58

; I/O locations
kbd = $C000
clrAuxRd = $C002
setAuxRd = $C003
clrAuxWr = $C004
setAuxWr = $C005
clrAuxZP = $C008
setAuxZP = $C009
kbdStrobe = $C010
clrText = $C050
setText = $C051
clrMixed = $C052
setMixed = $C053
page1 = $C054
page2 = $C055
clrHires = $C056
setHires = $C057

; ROM routines
prntAX = $F941
rdKey = $FD0C
crout = $FD8E
prByte = $FDDA
cout = $FDED
prErr = $FF2D
monitor = $FF69

; Pixel offsets for even and odd blit lines
blitOffsetEven: .byte 5,8,11,1,17,20,24
blitOffsetOdd: .byte 34,37,40,30,46,49,53
; texture addresses
texAddrLo: .byte <tex0,<tex1,<tex2,<tex3
texAddrHi: .byte >tex0,>tex1,>tex2,>tex3

;-------------------------------------------------------------------------------
; Multiply two bytes, quickly but somewhat inaccurately, using logarithms.
; Utilizes tbl_log2_b_b and tbl_pow2_b_b, which translate to and from 3+5 bit
; fixed precision base 2 logarithms.
;
; Input : unsigned bytes in X and Y
; Output: unsigned byte in A
;
umul_bb_b:
    cpx #4
    bcc @x_lt_4
    cpy #4
    bcc @y_lt_4
    lda tbl_log2_b_b,x  ; log2(x)
    clc
    adc tbl_log2_b_b,y  ; plus log2(y)
    tax
    lda tbl_pow2_b_b,x  ; 2 ^ (log2(x) + log2(y))  =  x * y
    rts
; handle cases less than 4 handle directly. This halved the size of
; the tables (or made them more accurate, depending on your point of view)
@x_lt_4:
    lda #0
    dex
    bmi @done   ; x=0
    tya
    dex
    bmi @done   ; x=1
    asl
    dey
    bmi @done   ; x=2
    sty @add+1  ; x=3
@add:
    adc #0
@done:
    rts
@y_lt_4:
    lda #0
    dey
    bmi @done   ; y=0
    txa
    dey
    bmi @done   ; y=1
    asl
    dey
    bmi @done   ; y=2
    stx @add+1  ; y=3
    bra @add

;-------------------------------------------------------------------------------
; Calculate log2 of a 16-bit number.
; Input: 16-bit unsigned int in A(lo)/X(hi)
; Output: fixed point 8+8 bit log2 in A(lo)/X(hi)
;
log2_w_w:
    cpx #0
    beq log2_b_w        ; hi-byte zero? only consider low byte
    stx tmp
    ldx #8              ; start with exponent=8
    lsr tmp             ; shift down
    beq @gotMant        ; until high byte is exactly 1
@highLup:
    ror                 ; save the bit we shifted out
    inx                 ; bump the exponent
    lsr tmp             ; shift next bit
    bne @highLup        ; loop again
@gotMant:
    ; mantissa now in A, exponent in X. Translate mantissa to log using table, and we're done
    tay
    lda tbl_log2_w_w,y
    rts

; Same as above but with with 8-bit input instead of 16. Same output though.
log2_b_w:
@low:                   ; we know high byte is zero
    ldx #7              ; start with exponent=7
    asl                 ; shift up
    bcs @gotMant        ; until high byte would be exactly 1
@lowLup:
    dex                 ; bump exponent down
    asl                 ; shift next bit
    bcc @lowLup         ; loop again
@gotMant:
    ; mantissa now in A, exponent in X. Translate mantissa to log using table, and we're done
    tay
    lda tbl_log2_w_w,y
    rts

;-------------------------------------------------------------------------------
; Calculate 2^n for a fixed-point n
; Input:  8.8 fixed precision number in Y(lo)/X(hi)
; Output: 16 bit unsigned int in A(lo)/X(hi)
;
pow2_w_w:
    lda tbl_pow2_w_w,y  ; table gives us log(2) -> mantissa in A
    cpx #8              ; check the exponent
    bcc @lo             ; less than 8? high byte will be zero.
    beq @mid            ; equal to 8? high byte will be one.
@hi:                    ; greater than 8: need to compute high byte
    ldy #1              ; start with one
    sty tmp
@hiLup:
    asl                 ; shift up
    rol tmp             ; including high byte
    dex                 ; count down exponent
    cpx #8              ; until we reach 8
    bne @hiLup
    ldx tmp             ; load computed high byte; proper low byte is already in A.
    rts
@lo:
    sec                 ; so we shift a 1 into the high bit of the low byte
@loLup:
    ror                 ; shift down
    inx                 ; count up exponent...
    cpx #8              ; ...until we hit 8
    bcc @loLup          ; handy because we need carry to be clear the next go-round
    ldx #0
    rts
@mid:                   ; exponent exactly 8 when we get here
    ldx #1              ; that means high byte should be 1
    rts

;-------------------------------------------------------------------------------
; Cast a ray
castRay:
    ; First, grab the precalculated ray data from the table.
    ldy #0              ; ray data has 4 bytes:
    ldx #1              ; default X step: forward one column of the map
    lda (pRayData),y    ; rayDirX
    bpl :+              ; if positive, don't negate
    eor #$FF            ; negate
    ldx #$FF            ; x step: back one column of the map
:   asl                 ; mul by 2 now that we've stripped the sign
    sta rayDirX         ; store x direction
    stx stepX           ; and x increment

    iny
    ldx #1              ; default y step: forward one row of the map
    lda (pRayData),y    ; rayDirY
    bpl :+              ; if positive, don't negate
    eor #$FF            ; negate
    ldx #$FF            ; y step: back one row of map
:   asl                 ; mul by 2 now that we've stripped the sign
    sta rayDirY         ; store y direction
    stx stepY           ; and y increment

    iny
    lda (pRayData),y    ; distance moved in X direction
    sta deltaDistX      ; for each step

    iny
    lda (pRayData),y    ; distance moved in Y direction
    sta deltaDistY      ; for each step

    ; Start at the player's position
    lda playerX+1
    sta mapX
    lda playerY+1
    sta mapY

    ; Next we need to calculate the initial distance on each side
    ; Start with the X side
    lda playerX         ; fractional byte of player distance
    bit stepX           ; if stepping in reverse...
    bpl :+
    eor #$FF            ; invert initial dist
:   tax
    ldy deltaDistX      ; calculate fraction of delta
    jsr umul_bb_b
    sta sideDistX       ; to form initial side dist
    ; Now the Y side
    lda playerY         ; fractional byte of player distance
    bit stepY           ; if stepping in reverse...
    bpl :+
    eor #$FF            ; invert initial dist
:   tax
    ldy deltaDistY      ; calculate fraction of delta
    jsr umul_bb_b
    sta sideDistY       ; to form initial side dist

    ; We're going to use the Y register to index the map. Initialize it.
    lda mapY
    asl                 ; assume map is 16 tiles wide...
    asl
    asl                 ; ...multiplying by 16
    asl
    adc mapX            ; then add X to get...
    tay                 ; ...starting index into the map

    ; the DDA algorithm
@DDA_step:
    lda sideDistX
    cmp sideDistY       ; decide whether it's closer to step in X dir or Y dir
    bcs @takeStepY
    ; taking a step in the X direction
@takeStepX:
    lda sideDistY       ; adjust side dist in Y dir
    sec
    sbc sideDistX
    sta sideDistY
    lda deltaDistX      ; re-init X distance
    sta sideDistX
    lda stepX           ; advance mapX in the correct direction
    bmi @negX
    inc mapX
    iny                 ; also the Y reg which indexes the map
    bra @checkX
@negX:
    dec mapX
    dey
@checkX:
    lda (pMap),y        ; check map at current X/Y position
    beq @DDA_step       ; nothing there? do another step.
    ; We hit something!
@hitX:
    sta txNum           ; store the texture number we hit
    lda #0
    sec
    sbc playerX         ; inverse of low byte of player coord
    sta dist            ; is fractional byte of dist.
    lda mapX            ; map X is the integer byte
    sbc #0
    bit stepX
    bmi :+
    ina                 ; if stepping forward, add one to dist
:   sta dist+1
    ldx rayDirX         ; parameters for wall calculation
    ldy rayDirY
    lda stepY
    jsr @wallCalc       ; centralized code for wall calculation
    ; adjust wall X
    lda playerY         ; fractional player pos
    clc
    adc txColNum
    bit stepY           ; if stepping forward in X...
    bmi :+
    eor #$FF            ; ...invert the texture coord
:   sta txColNum
    rts
    ; taking a step in the Y direction
@takeStepY:
    lda sideDistX       ; adjust side dist in Y dir
    sec
    sbc sideDistY
    sta sideDistX
    lda deltaDistY      ; re-init Y distance
    sta sideDistY
    tya                 ; get ready to adjust Y by a whole line
    bit stepY           ; advance mapY in the correct direction
    bmi @negY
    inc mapY
    clc
    adc #16             ; next row in the map
    bra @checkY
@negY:
    dec mapY
    sec
    sbc #16
@checkY:
    tay                 ; row number to Y so we can index the map
    lda (pMap),y        ; check map at current X/Y position
    beq @DDA_step       ; nothing there? do another step.
    ; We hit something!
@hitY:
    sta txNum           ; store the texture number we hit
    lda #0
    sec
    sbc playerY         ; inverse of low byte of player coord
    sta dist            ; is fractional byte of dist.
    lda mapY            ; map X is the integer byte
    sbc #0
    bit stepY
    bpl :+
    ina                 ; if stepping backward, add one to dist
:   sta dist+1
    ldx rayDirY         ; parameters for wall calculation
    ldy rayDirX
    lda stepX
    jsr @wallCalc       ; centralized code for wall calculation
    ; adjust wall X
    lda playerX         ; fractional player pos
    clc
    adc txColNum
    bit stepY           ; if stepping backward in Y
    bpl :+
    eor #$FF            ; ...invert the texture coord
:   sta txColNum
    rts

    ; wall calculation: X=dir1, Y=dir2, A=dir2step
@wallCalc:
    pha                 ; save step
    phy                 ; save dir2
    txa
    jsr log2_b_w        ; calc log2(dir1)
    sta @sub1+1         ; save it for later subtraction
    stx @sub2+1
    lda dist            ; calc abs(dist)
    ldx dist+1          ; dist currently in A(lo)/X(hi)
    bpl :+
    lda #0
    sbc dist
    tay
    lda #0
    sbc dist+1
    tax                 ; get inverted dist into A(lo)/X(hi)
    tya
:   jsr log2_w_w        ; calculate log2(abs(dist))
    sec
@sub1:
    sbc #0              ; subtract log2(dir1)
    sta diff
    txa
@sub2:
    sbc #0
    sta diff+1
    ; Calculate texture coordinate
    pla                 ; get dir2 back
    jsr log2_b_w        ; calculate log2(dir2)
    clc
    adc diff            ; sum = diff + log2(dir2)
    tay
    txa
    adc diff+1
    tax
    jsr pow2_w_w        ; calculate 2 ^ sum
    ; fractional part (A-reg) of result is texture coord
    ply                 ; retrieve the step direction
    bpl :+              ; if positive, don't flip the texture coord
    eor #$FF            ; negative, flip the coord
:   sta txColNum
    ; Calculate line height
    ; we need to subtract diff from log2(64) which is $0600
    lda #0
    sec
    sbc diff
    tay
    lda #6
    sbc diff+1
    tax
    jsr pow2_w_w        ; calculate 2 ^ (log(64) - diff)
    cpx #0
    beq :+
    lda #$FF            ; clamp large line heights to 255
:   sta lineCt
    rts                 ; all done with wall calculations

; Advance pLine to the next line on the hi-res screen
nextLine:
    lda pLine+1 ; Hi byte of line
    clc
    adc #4 ; Next line is 1K up
    tax
    eor pLine+1
    and #$20 ; Past end of screen?
    beq @done ; If not, we're done
    txa
    sec
    sbc #$20 ; Back to start
    tax
    lda pLine ; Lo byte
    clc
    adc #$80 ; Inner blks offset by 128 bytes
    sta pLine
    bcc @done
    inx ; Next page
    txa
    and #7
    cmp #4 ; Still inside inner blk?
    bne @done ; If so we're done
    txa
    sec
    sbc #4 ; Back to start of inner blk
    tax
    lda pLine
    clc
    adc #$28 ; Outer blks offset by 40 bytes
    sta pLine
@done:
    stx pLine+1
    rts

; Template for blitting code

blitTemplate: ; comments show byte offset
; even rows
    lda shiftA57 ;  0: pixel 3
    asl ;  3: save half of pix 3 in carry
    ora shiftA01 ;  4: pixel 0
    ora shiftA23 ;  7: pixel 1
    ora shiftA45 ; 10: pixel 2
    sta (0),Y ; 13: even column
    iny ; 15: prep for odd
    lda shiftA01 ; 16: pixel 4
    ora shiftA23 ; 19: pixel 5
    rol ; 22: recover half of pix 3
    ora shiftA56 ; 23: pixel 6 - after rol to ensure right hi bit
    sta (0),Y ; 26: odd column
    dey ; 28: prep for even
; odd rows
    lda shiftB57 ; 29: pixel 3
    asl ; 32: save half of pix 3 in carry
    ora shiftB01 ; 33: pixel 0
    ora shiftB23 ; 36: pixel 1
    ora shiftB45 ; 39: pixel 2
    sta (2),Y ; 42: even column
    iny ; 44: prep for odd
    lda shiftB01 ; 45: pixel 4
    ora shiftB23 ; 48: pixel 5
    rol ; 51: recover half of pix 3
    ora shiftB56 ; 52: pixel 6 - after rol to ensure right hi bit
    sta (2),Y ; 55: odd column
    dey ; 57: prep for even
    ; 58: total

; Create the unrolled blit code
makeBlit:
    lda #0 ; Start with line zero
    sta lineCt
    lda #<TOP_LINE ; Begin with the first screen line
    sta pLine
    lda #>TOP_LINE
    sta pLine+1
    lda #<blitRoll ; Store to blit unroll code buf
    sta pDst
    lda #>blitRoll
    sta pDst+1
@lineLup:
; Copy the template
    ldy #57
@copy:
    lda blitTemplate,Y
    sta (pDst),Y
    dey
    bpl @copy
     ; Record the address for the even line
    jsr @storeIndex
; Set the even line pointers
    ldy #14
    jsr @storeLine
    ldy #27
    jsr @storeLine
    ; Get ready for odd line
    jsr @advance
    ; Record the address for the odd line
    jsr @storeIndex
; Set the odd line pointers
    ldy #14
    jsr @storeLine
    ldy #27
    jsr @storeLine
    ; Prepare for next iteration
    jsr @advance
; Loop until all lines are done
    lda lineCt
    cmp #NLINES
    bne @lineLup
    jsr @storeIndex ; Last addr to index
    jmp storeRTS ; Finish with RTS for cleanliness
@storeLine: ; Subroutine to store pLine to pDst
    lda lineCt
    asl
    sta (pDst),Y
    rts
@storeIndex: ; Subroutine to store tbl ptr to index
    ldy lineCt
    lda pDst
    sta blitIndexLo,Y
    lda pDst+1
    sta blitIndexHi,Y
    rts
@advance: ; Subroutine to go to next unroll
    lda #29
    jsr advPDst
    inc lineCt
    jmp nextLine

; Create code to clear the blit
makeClrBlit:
    ldx #0
    ldy #0
@lup:
    lda @st
    sta clrBlitRoll,X
    inx
    lda blitIndexLo,Y
    sta clrBlitRoll,X
    inx
    lda blitIndexHi,Y
@st:
    sta clrBlitRoll,X
    inx
    iny
    iny
    cpy #64
    bne @noSwitch
    lda @tya ; switch from sky color to ground color
    sta clrBlitRoll,X
    inx
@noSwitch:
    cpy #NLINES
    bne @lup
    lda @rts
    sta clrBlitRoll,X
@rts:
    rts
@tya:
    tya

; Clear the blit
clearBlit:
    ldy #GROUND_COLOR
clearBlit2:
    ldx blitOffsetEven+0
    lda #SKY_COLOR
    jsr clrBlitRoll
    ldx blitOffsetEven+1
    lda #SKY_COLOR
    jsr clrBlitRoll
    ldx blitOffsetEven+2
    lda #SKY_COLOR
    jsr clrBlitRoll
    ldx blitOffsetEven+3
    lda #SKY_COLOR
    jsr clrBlitRoll
    ldx blitOffsetEven+4
    lda #SKY_COLOR
    jsr clrBlitRoll
    ldx blitOffsetEven+5
    lda #SKY_COLOR
    jsr clrBlitRoll
    ldx blitOffsetEven+6
    lda #SKY_COLOR
    jsr clrBlitRoll
    ldx blitOffsetOdd+0
    lda #SKY_COLOR
    jsr clrBlitRoll
    ldx blitOffsetOdd+1
    lda #SKY_COLOR
    jsr clrBlitRoll
    ldx blitOffsetOdd+2
    lda #SKY_COLOR
    jsr clrBlitRoll
    ldx blitOffsetOdd+3
    lda #SKY_COLOR
    jsr clrBlitRoll
    ldx blitOffsetOdd+4
    lda #SKY_COLOR
    jsr clrBlitRoll
    ldx blitOffsetOdd+5
    lda #SKY_COLOR
    jsr clrBlitRoll
    ldx blitOffsetOdd+6
    lda #SKY_COLOR
    jmp clrBlitRoll

; Construct the shift tables
makeShift:
    ldx #0
@shiftA:
    txa
    and #3
@shiftA01:
    sta shiftA01,X
@shiftA23:
    asl
    asl
    sta shiftA23,X
@shiftA45:
    asl
    asl
    ora #$80
    sta shiftA45,X
@shiftA56:
    asl
    ora #$80
    sta shiftA56,X
@shiftA57:
    asl
    asl
    php
    lsr
    plp
    ror
    sta shiftA57,X
@shiftB:
    txa
    lsr
    lsr
    lsr
    lsr
    and #3
@shiftB01:
    ora #$80
    sta shiftB01,X
@shiftB23:
    asl
    asl
    ora #$80
    sta shiftB23,X
@shiftB45:
    asl
    asl
    ora #$80
    sta shiftB45,X
@shiftB56:
    asl
    ora #$80
    sta shiftB56,X
@shiftB57:
    asl
    asl
    php
    lsr
    plp
    ror
    sta shiftB57,X
@next:
    inx
    bne @shiftA
    rts

; Template for decimation. Offsets in comments
decimTemplate:
    lda (pTex),Y ; 0
    sta blitRoll,X ; 2
    sta blitRoll+29,X ; 5
    lda (pBump),Y ; 8
    tay ; 10
    ; 11

; Unroll the decimation code
makeDCM:
    ldx #0 ; Line counter
    lda #<decimRoll
    sta pDst
    lda #>decimRoll
    sta pDst+1
@oneSet:
; Save address to the index
    jsr @storeIndex
    ldy #11 ; Copy the template
@copySet: 
    lda decimTemplate,Y
    sta (pDst),Y
    dey
    bpl @copySet
    ldy #3
    jsr @storeBlit
    ldy #6
    jsr @storeBlit
    lda #11
    jsr advPDst
@more:
    ; Loop until all lines done
    cpx #NLINES
    bcc @oneSet
    jsr @storeIndex ; Last addr to index
    jmp storeRTS ; Finish with an RTS for cleanliness
@storeBlit: ; Store current blit addr
    lda blitIndexLo,X
    sta (pDst),Y
    iny
    lda blitIndexHi,X
    sta (pDst),Y
    inx ; Next line
    rts
@storeIndex:
    txa
    lsr ; One entry per two lines
    tay
    lda pDst
    sta dcmIndexLo,Y
    lda pDst+1
    sta dcmIndexHi,Y
    rts

storeRTS:
    lda #$60 ; Store an rts at pDst
    ldy #0
    sta (pDst),Y
    rts
advPDst: ; Add A to PDST
    clc
    adc pDst
    sta pDst
    bcc @rts
    inc pDst+1
@rts:
    rts

; Clear all the memory we're going to fill
clearMem:
    ldx #$10
    lda #$BE
    jmp clearScreen2

; Clear the screens
clearScreen:
    ldx #>screen
    .if DOUBLE_BUFFER
    lda #>screen + $40 ; both hi-res screens
    .else
    lda #>screen + $20 ; one hi-res screen
    .endif
clearScreen2:
    sta @limit+1
    ldy #0
    sty pDst
    tya
@outer:
    stx pDst+1
@inner:
    sta (pDst),Y
    iny
    bne @inner
    inx
@limit:
    cpx #>screen + $20
    bne @outer
    rts

; Make a simple texture with alternating colors.
; Input: Y = tex num
;        A, X: color numbers, 0-3
simpleTexture:
    sta @load1+1
    txa
    asl
    asl
    asl
    asl
    sta @load2+1
    lda texAddrLo,Y
    sta pDst
    lda texAddrHi,Y
    sta pDst+1
    ldx #>TEX_SIZE
    ldy #0
    sty @limit+1
@outer:
@load1:
    lda #0
@load2:
    ora #0
@lup:
    sta (pDst),Y
    iny
@limit:
    cpy #0
    bne @lup
    inc pDst+1
    dex
    bmi @done
    bne @outer
    lda #<TEX_SIZE ; partial last page
    sta @limit+1
    jmp @outer
@done: rts

; Generate the table of "bumps" for decimation
makeBumps:
    lda #63 ; 126/2 bump lists
    sta lineCt
    lda #<bumps
    sta pDst
    lda #>bumps
    sta pDst+1
    lda #0
    sta @ratioLo
    lda #1
    sta @ratioHi
; Goal is to make ratio = 63 divided by targetSize.
; The calculation is cool & weird, but I verified
; in Python that the logic actually works. You
; start with hi=1, lo=0. To calculate the next
; step, add hi to low and take the sum mod the next
; target size. To use the ratio, increment by hi
; and lo. Whenever the low byte goes beyond the
; target size, add an extra to hi.
@onePass:
    lda lineCt ; Init A with the lo byte = target size
    lsr ; ...div 2
    ldx #0 ; Hi byte always starts at zero
    ldy #0 ; Location to store at
@bumpLup:
    clc  ; increment lo byte by ratio
    adc @ratioLo
    cmp lineCt ; if we wrap around, need extra hi-byte bump
    bcc @noBump
    sec
    sbc lineCt
    inx
@noBump:
    pha ; save lo byte
    txa ; now work on hi byte
    clc
    adc @ratioHi
    tax
    sta (pDst),Y ; store to the table
    tay ; next loc to store
    cpx #63 ; check for end of column
    pla ; get lo byte back
    bcc @bumpLup ; loop until whole column is done
    lda #64
    jsr advPDst ; advance dst to next column
@next:
    dec lineCt ; all columns complete?
    beq @done
    lda @ratioLo ; next ratio calculation (see explanation above)
    clc
    adc @ratioHi
@modLup:
    cmp lineCt
    bcc @noMod
    inc @ratioHi
    sec
    sbc lineCt
    bne @modLup ; this must indeed be a loop
@noMod:
    sta @ratioLo
    jmp @onePass ; next column
@done:
    rts
@ratioLo: .byte 0
@ratioHi: .byte 0

; Decimate a column of the texture
; Input: Y - texture number
;        txColNum - src column num in the texture
;        pixNum - dst pixel num in the blit roll
;        lineCt - height to render, in dbl lines
; The output will be vertically centered.
decimateCol:
    ; if height is zero, render nothing
    lda lineCt
    bne @notZero
    rts
@notZero:
    ; determine mip level in X reg
    ldx #0
    lda lineCt
    sta @adjustedHeight
    lda txColNum
    sta @adjustedCol
    lda #32
@mipLup:
    cmp lineCt
    bcc @gotMip
    inx
    asl @adjustedHeight
    lsr @adjustedCol
    lsr
    cmp #2
    bcs @mipLup
@gotMip:
    .if DEBUG
    lda #"t"
    jsr cout
    tya
    jsr prByte
    lda #" "
    jsr cout

    lda #"h"
    jsr cout
    lda lineCt
    jsr prByte
    lda #" "
    jsr cout

    lda #"m"
    jsr cout
    txa
    jsr prByte
    lda #" "
    jsr cout
    .endif

    ; calc addr of tex
    lda texAddrLo,Y
    clc
    adc mipOffsetLo,X
    sta pDst
    lda texAddrHi,Y
    adc mipOffsetHi,X
    sta pDst+1

    .if DEBUG
    lda #"a"
    jsr cout
    lda pDst+1
    jsr prByte
    lda pDst
    jsr prByte
    lda #" "
    jsr cout
    .endif

@calcOffset: ; calc offset within tex
    lda #0
    sta pTex+1
    lda @adjustedCol
@shift:
    asl
    rol pTex+1
    inx ; Note: destroys mip level
    cpx #6
    bne @shift

    .if DEBUG
    pha
    lda #"x"
    jsr cout
    lda @adjustedCol
    jsr prByte
    lda #" "
    jsr cout

    lda #"o"
    jsr cout
    lda pTex+1
    jsr prByte
    pla
    pha
    jsr prByte
    lda #" "
    jsr cout
    pla
    .endif

    clc
    adc pDst
    sta pTex
    lda pTex+1
    adc pDst+1
    sta pTex+1
; calculate bump table ptr
    ldx @adjustedHeight
    jsr calcBump
    ; figure first line in decim unroll
    lda #63
    sec
    sbc lineCt ; height 63 is first in decim tbl
    lsr
    tax
    lda dcmIndexLo,X
    sta @call+1
    lda dcmIndexHi,X
    sta @call+2
    ; figure last line of decim unroll
    txa
    clc
    adc lineCt
    tax
    lda dcmIndexLo,X
    sta pTmp
    lda dcmIndexHi,X
    sta pTmp+1
; determine blit offset for writing
    ldy pixNum
    ldx blitOffsetEven,Y
    ; store rts so decim returns @ right moment
    ldy #0
    lda (pTmp),Y ; save existing byte
    pha
    lda @rts
    sta (pTmp),Y

    .if DEBUG
    phx
    phy
    jsr rdKey
    pha
    jsr crout
    pla
    ply
    plx
    cmp #$9B
    bne @notEscape
    brk
@notEscape:
    nop
    .endif

@call:
    jsr decimRoll
; fix rts to what it was before
    ldy #0
    pla
    sta (pTmp),Y

    .if DEBUG
    ldy byteNum ; to see results early
    sta setAuxZP
    jsr blitRoll
    sta clrAuxZP
    .endif

@rts:
    rts
@adjustedHeight: .byte 0
@adjustedCol: .byte 0

; Calc pointer into the bump table
; Input: X - height to render in dbl lines
calcBump:
    stx @sub+1
    lda #0
    sta pBump+1
    lda #63 ; bump 63 is actually first
    sec
@sub:
    sbc #0
    bpl @notNeg
    lda #0
@notNeg:

    .if DEBUG
    pha
    lda #"b"
    jsr cout
    pla
    pha
    jsr prByte
    lda #" "
    jsr cout
    pla
    .endif

    ldx #6
@lup:
    asl
    rol pBump+1
    dex
    bne @lup
    clc
    adc #<bumps
    sta pBump
    lda pBump+1
    adc #>bumps
    sta pBump+1

    .if DEBUG
    lda #"p"
    jsr cout
    lda pBump+1
    jsr prByte
    lda pBump
    jsr prByte
    lda #" "
    jsr cout
    .endif

    rts

; Build table of screen line pointers
; on aux zero-page
makeLines:
    lda #0
    sta lineCt
    lda #<TOP_LINE
    sta pLine
    lda #>TOP_LINE
    sta pLine+1
@lup:
    lda lineCt
    asl
    tax
    lda pLine
    ldy pLine+1
    sta setAuxZP
    sta 0,X
    sty 1,X
    sta clrAuxZP
    jsr nextLine
    inc lineCt
    lda lineCt
    cmp #NLINES
    bne @lup
    rts

; Set screen lines to current back buf
setBackBuf:
; calculate screen start
    lda bacKBuf
    asl
    asl
    asl
    asl
    asl
    clc
    adc #$20
    sta setAuxZP
    sta $FF
    ldx #0
@lup:
    lda 1,X
    and #$1F
    ora $FF
    sta 1,X
    inx
    inx
    bne @lup
    sta clrAuxZP
    rts

; Load file, len-prefixed name in A/X (hi/lo), to addr on stack
; (push hi byte first, then push lo byte)
bload:
    stx @mliCommand+1 ; filename lo
    sta @mliCommand+2 ; filename hi
    lda #<prodosBuf
    sta @mliCommand+3
    lda #>prodosBuf
    sta @mliCommand+4
    lda #$C8 ; open
    ldx #3
    jsr @doMLI
    lda @mliCommand+5 ; get handle and put it in place
    sta @mliCommand+1
    ply ; save ret addr
    plx
    pla
    sta @mliCommand+2 ; load addr lo
    pla
    sta @mliCommand+3 ; load addr hi
    phx ; restore ret addr
    phy
    lda #$CA ; read
    sta @mliCommand+5 ; also length (more than enough)
    ldx #4
    jsr @doMLI
@close:
    stz @mliCommand+1 ; close all
    lda #$CC
    ldx #1
    ; fall through
@doMLI:
    sta @mliOp
    stx @mliCommand
    jsr MLI
@mliOp: .byte 0
    .addr @mliCommand
    bcs @err
    rts
@err:
    jsr prByte
    jsr prErr
    ldx #$FF
    txs
    jmp monitor
@mliCommand: .res 10 ; 10 bytes should be plenty

; Copy X pages starting at pg Y to aux mem
copyToAux:
    sta setAuxWr
    sty pDst+1
    ldy #0
    sty pDst
@lup:
    lda (pDst),Y
    sta (pDst),Y
    iny
    bne @lup
    inc pDst+1
    dex
    bne @lup
    sta clrAuxWr
    rts

; Test code to see if things really work
test:
    ; clear ProDOS mem map so it lets us load
    ldx #$18
    lda #1
@memLup:
    sta memMap-1,X
    lda #0
    dex
    bne @memLup
    ; make reset go to monitor
    lda #<monitor
    sta resetVec
    lda #>monitor
    sta resetVec+1
    eor #$A5
    sta resetVec+2
; Copy our code to aux mem so we can seamlessly switch back and forth
; It's wasteful but makes things easy for now.
    ldy #>codeBeg
    ldx #>codeEnd - >codeBeg + 1
    jsr copyToAux
; set up everything else
    jsr clearMem
    ; load the textures
    lda #>tex0
    pha
    lda #<tex0
    pha
    ldx #<@tex0Name
    lda #>@tex0Name
    jsr bload

    lda #>tex1
    pha
    lda #<tex1
    pha
    ldx #<@tex1name
    lda #>@tex1name
    jsr bload

    lda #>tex2
    pha
    lda #<tex2
    pha
    ldx #<@tex2name
    lda #>@tex2name
    jsr bload

    lda #>tex3
    pha
    lda #<tex3
    pha
    ldx #<@tex3name
    lda #>@tex3name
    jsr bload

    ; load the fancy frame
    lda #>$2000
    pha
    lda #<$2000
    pha
    ldx #<@frameName
    lda #>@frameName
    jsr bload

; build all the unrolls and tables
    jsr makeBlit
    jsr makeClrBlit
    jsr makeShift
    jsr makeDCM
    jsr makeBumps
    jsr makeLines
; set up front and back buffers
    lda #0
    sta frontBuf
    .if DOUBLE_BUFFER
    lda #1
    .endif
    sta bacKBuf

    bit clrText
    bit setHires

    lda #63
    sta lineCt
    lda #1
    sta @dir
    jsr clearBlit
@oneLevel:
    lda #0
    sta pixNum
    sta byteNum
    .if DOUBLE_BUFFER
    jsr setBackBuf
    .endif

    .if DEBUG
    lda pCast+1
    jsr prByte
    lda pCast
    jsr prByte
    jsr crout
    .endif

@oneCol:
    jsr getCast ; first byte is height
    cmp #$FF
    bne @noReset
; found end of cast data, start over
    lda #0
    sta pCast
    lda #$20
    sta pCast+1
    jsr getCast
@noReset:
    cmp #63
    bcc @heightOk
    lda #62
@heightOk:
    sta lineCt
    jsr getCast ; second byte is tex num and tex col
    pha
    and #$3F
    cmp #63
    bcc @columnOk
    lda #62
@columnOk:
    sta txColNum
    pla
    lsr ; div by 64
    lsr
    lsr
    lsr
    lsr
    lsr
    tay ; Y now holds tex num
    jsr decimateCol
    inc pixNum
    lda pixNum
    cmp #7
    bne @oneCol
@flush:
    ldy byteNum
    iny
    iny
    sta setAuxZP
    jsr blitRoll
    sta clrAuxZP
    jsr clearBlit
    lda #0
    sta pixNum
    inc byteNum
    inc byteNum
    lda byteNum
    cmp #18
    bne @oneCol
@nextLevel:
; flip onto the screen
    .if DOUBLE_BUFFER
    ldx bacKBuf
    lda frontBuf
    sta bacKBuf
    stx frontBuf
    lda page1,X
    .endif
    ; adv past FE in cast data
    jsr getCast
    cmp #$FE
    bne @err
    jsr getCast
    cmp #$FE
    beq @incDec
@err:
    brk
@incDec:
    lda kbd ; stop if ESC is pressed
    cmp #$9B
    beq @done
    cmp #$A0 ; pause if space is pressed
    bne @notSpace
    bit kbdStrobe
@pauseLup:
    lda kbd
    bpl @pauseLup
@notSpace:
    jmp @oneLevel
@done:
    sta kbdStrobe ; eat the keypress
    bit setText
    bit page1
; quit the ProDOS way
    inc resetVec+2 ; invalidate reset vector
    jsr MLI
    .byte $65
    .addr @quitParms
@quitParms:
    .byte 4, 0
    .word 0
    .byte 0
    .word 0

@dir: .byte 1
@tex0Name: .byte 21
    .byte "/LL/ASSETS/BUILDING01"
@tex1name: .byte 21
    .byte "/LL/ASSETS/BUILDING02"
@tex2name: .byte 21
    .byte "/LL/ASSETS/BUILDING03"
@tex3name: .byte 21
    .byte "/LL/ASSETS/BUILDING04"
@precastName: .byte 18
    .byte "/LL/ASSETS/PRECAST"
@frameName: .byte 16
    .byte "/LL/ASSETS/FRAME"

; Following are log/pow lookup tables. For speed, align them on a page boundary.
    .align 256

; Table to translate an unsigned byte to 3+5 bit fixed point log2
tbl_log2_b_b:
    .byte $00,$00,$00,$00,$00,$07,$0C,$11,$15,$19,$1C,$1F,$22,$24,$27,$29
    .byte $2B,$2D,$2E,$30,$32,$33,$34,$36,$37,$38,$3A,$3B,$3C,$3D,$3E,$3F
    .byte $40,$41,$42,$43,$44,$44,$45,$46,$47,$48,$48,$49,$4A,$4A,$4B,$4C
    .byte $4C,$4D,$4E,$4E,$4F,$50,$50,$51,$51,$52,$52,$53,$53,$54,$54,$55
    .byte $55,$56,$56,$57,$57,$58,$58,$59,$59,$59,$5A,$5A,$5B,$5B,$5B,$5C
    .byte $5C,$5D,$5D,$5D,$5E,$5E,$5E,$5F,$5F,$5F,$60,$60,$61,$61,$61,$61
    .byte $62,$62,$62,$63,$63,$63,$64,$64,$64,$65,$65,$65,$65,$66,$66,$66
    .byte $67,$67,$67,$67,$68,$68,$68,$68,$69,$69,$69,$69,$6A,$6A,$6A,$6A
    .byte $6B,$6B,$6B,$6B,$6C,$6C,$6C,$6C,$6D,$6D,$6D,$6D,$6D,$6E,$6E,$6E
    .byte $6E,$6F,$6F,$6F,$6F,$6F,$70,$70,$70,$70,$70,$71,$71,$71,$71,$71
    .byte $72,$72,$72,$72,$72,$72,$73,$73,$73,$73,$73,$74,$74,$74,$74,$74
    .byte $74,$75,$75,$75,$75,$75,$75,$76,$76,$76,$76,$76,$76,$77,$77,$77
    .byte $77,$77,$77,$78,$78,$78,$78,$78,$78,$79,$79,$79,$79,$79,$79,$79
    .byte $7A,$7A,$7A,$7A,$7A,$7A,$7A,$7B,$7B,$7B,$7B,$7B,$7B,$7B,$7C,$7C
    .byte $7C,$7C,$7C,$7C,$7C,$7D,$7D,$7D,$7D,$7D,$7D,$7D,$7D,$7E,$7E,$7E
    .byte $7E,$7E,$7E,$7E,$7F,$7F,$7F,$7F,$7F,$7F,$7F,$7F,$7F,$7F,$7F,$7F

; Table to translate 3+5 bit fixed point log2 back to an unsigned byte
tbl_pow2_b_b:
    .byte $00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
    .byte $00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
    .byte $00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
    .byte $00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
    .byte $00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
    .byte $00,$00,$00,$00,$00,$00,$01,$01,$01,$01,$01,$01,$01,$01,$01,$01
    .byte $01,$01,$01,$01,$01,$01,$01,$01,$01,$01,$01,$02,$02,$02,$02,$02
    .byte $02,$02,$02,$02,$02,$02,$02,$02,$03,$03,$03,$03,$03,$03,$03,$03
    .byte $04,$04,$04,$04,$04,$04,$04,$05,$05,$05,$05,$05,$05,$06,$06,$06
    .byte $06,$06,$07,$07,$07,$07,$08,$08,$08,$09,$09,$09,$09,$0A,$0A,$0A
    .byte $0B,$0B,$0C,$0C,$0C,$0D,$0D,$0E,$0E,$0F,$0F,$10,$10,$11,$11,$12
    .byte $13,$13,$14,$14,$15,$16,$17,$17,$18,$19,$1A,$1B,$1C,$1D,$1D,$1E
    .byte $20,$21,$22,$23,$24,$25,$26,$28,$29,$2A,$2C,$2D,$2F,$30,$32,$34
    .byte $35,$37,$39,$3B,$3D,$3F,$41,$43,$45,$48,$4A,$4C,$4F,$52,$54,$57
    .byte $5A,$5D,$60,$63,$67,$6A,$6D,$71,$75,$79,$7D,$81,$85,$8A,$8E,$93
    .byte $98,$9D,$A2,$A7,$AD,$B3,$B8,$BF,$C5,$CB,$D2,$D9,$E0,$E8,$EF,$F7

; Table to translate 8-bit mantissa to fractional part of log2
tbl_log2_w_w:
    .byte $00,$01,$02,$04,$05,$07,$08,$09,$0B,$0C,$0E,$0F,$10,$12,$13,$15
    .byte $16,$17,$19,$1A,$1B,$1D,$1E,$1F,$21,$22,$23,$25,$26,$27,$28,$2A
    .byte $2B,$2C,$2E,$2F,$30,$31,$33,$34,$35,$36,$38,$39,$3A,$3B,$3D,$3E
    .byte $3F,$40,$41,$43,$44,$45,$46,$47,$49,$4A,$4B,$4C,$4D,$4E,$50,$51
    .byte $52,$53,$54,$55,$57,$58,$59,$5A,$5B,$5C,$5D,$5E,$60,$61,$62,$63
    .byte $64,$65,$66,$67,$68,$69,$6A,$6C,$6D,$6E,$6F,$70,$71,$72,$73,$74
    .byte $75,$76,$77,$78,$79,$7A,$7B,$7C,$7D,$7E,$7F,$80,$81,$83,$84,$85
    .byte $86,$87,$88,$89,$8A,$8B,$8C,$8C,$8D,$8E,$8F,$90,$91,$92,$93,$94
    .byte $95,$96,$97,$98,$99,$9A,$9B,$9C,$9D,$9E,$9F,$A0,$A1,$A2,$A2,$A3
    .byte $A4,$A5,$A6,$A7,$A8,$A9,$AA,$AB,$AC,$AD,$AD,$AE,$AF,$B0,$B1,$B2
    .byte $B3,$B4,$B5,$B5,$B6,$B7,$B8,$B9,$BA,$BB,$BC,$BC,$BD,$BE,$BF,$C0
    .byte $C1,$C2,$C2,$C3,$C4,$C5,$C6,$C7,$C8,$C8,$C9,$CA,$CB,$CC,$CD,$CD
    .byte $CE,$CF,$D0,$D1,$D1,$D2,$D3,$D4,$D5,$D6,$D6,$D7,$D8,$D9,$DA,$DA
    .byte $DB,$DC,$DD,$DE,$DE,$DF,$E0,$E1,$E1,$E2,$E3,$E4,$E5,$E5,$E6,$E7
    .byte $E8,$E8,$E9,$EA,$EB,$EB,$EC,$ED,$EE,$EF,$EF,$F0,$F1,$F2,$F2,$F3
    .byte $F4,$F5,$F5,$F6,$F7,$F7,$F8,$F9,$FA,$FA,$FB,$FC,$FD,$FD,$FE,$FF

; Table to translate fractional part of log2 back to 8-bit mantissa
tbl_pow2_w_w:
    .byte $00,$00,$01,$02,$02,$03,$04,$04,$05,$06,$07,$07,$08,$09,$09,$0A
    .byte $0B,$0C,$0C,$0D,$0E,$0E,$0F,$10,$11,$11,$12,$13,$14,$14,$15,$16
    .byte $17,$17,$18,$19,$1A,$1A,$1B,$1C,$1D,$1E,$1E,$1F,$20,$21,$21,$22
    .byte $23,$24,$25,$25,$26,$27,$28,$29,$29,$2A,$2B,$2C,$2D,$2D,$2E,$2F
    .byte $30,$31,$32,$32,$33,$34,$35,$36,$37,$37,$38,$39,$3A,$3B,$3C,$3D
    .byte $3D,$3E,$3F,$40,$41,$42,$43,$44,$44,$45,$46,$47,$48,$49,$4A,$4B
    .byte $4C,$4C,$4D,$4E,$4F,$50,$51,$52,$53,$54,$55,$56,$57,$57,$58,$59
    .byte $5A,$5B,$5C,$5D,$5E,$5F,$60,$61,$62,$63,$64,$65,$66,$67,$68,$69
    .byte $6A,$6B,$6C,$6D,$6E,$6F,$70,$71,$72,$73,$74,$75,$76,$77,$78,$79
    .byte $7A,$7B,$7C,$7D,$7E,$7F,$80,$81,$82,$83,$84,$85,$86,$87,$88,$89
    .byte $8A,$8C,$8D,$8E,$8F,$90,$91,$92,$93,$94,$95,$96,$97,$99,$9A,$9B
    .byte $9C,$9D,$9E,$9F,$A0,$A2,$A3,$A4,$A5,$A6,$A7,$A8,$AA,$AB,$AC,$AD
    .byte $AE,$AF,$B1,$B2,$B3,$B4,$B5,$B6,$B8,$B9,$BA,$BB,$BC,$BE,$BF,$C0
    .byte $C1,$C3,$C4,$C5,$C6,$C7,$C9,$CA,$CB,$CC,$CE,$CF,$D0,$D1,$D3,$D4
    .byte $D5,$D7,$D8,$D9,$DA,$DC,$DD,$DE,$E0,$E1,$E2,$E4,$E5,$E6,$E7,$E9
    .byte $EA,$EB,$ED,$EE,$EF,$F1,$F2,$F4,$F5,$F6,$F8,$F9,$FA,$FC,$FD,$FF

; Precalculated ray initialization parameters. One table for each of the 16 angles.
; Each angle has 63 rays, and each ray is provided with 4 parameters (one byte each param):
; dirX, dirY, deltaX, deltaY
precast_0:
    .byte $73,$C7,$3E,$7C
    .byte $73,$C8,$3D,$7E
    .byte $73,$CA,$2C,$5E
    .byte $73,$CC,$39,$7E
    .byte $73,$CE,$30,$6E
    .byte $73,$D0,$35,$7E
    .byte $73,$D2,$33,$7E
    .byte $73,$D3,$31,$7E
    .byte $73,$D5,$2F,$7E
    .byte $73,$D7,$28,$70
    .byte $73,$D9,$2B,$7E
    .byte $73,$DB,$29,$7E
    .byte $73,$DC,$27,$7E
    .byte $73,$DE,$25,$7E
    .byte $73,$E0,$23,$7E
    .byte $73,$E2,$21,$7E
    .byte $73,$E4,$1F,$7E
    .byte $73,$E6,$1D,$7E
    .byte $73,$E7,$18,$70
    .byte $73,$E9,$19,$7E
    .byte $73,$EB,$17,$7E
    .byte $73,$ED,$14,$78
    .byte $73,$EF,$13,$7E
    .byte $73,$F1,$11,$7E
    .byte $73,$F2,$0F,$7E
    .byte $73,$F4,$0D,$7E
    .byte $73,$F6,$0B,$7E
    .byte $73,$F8,$09,$7E
    .byte $73,$FA,$07,$7E
    .byte $73,$FB,$05,$7E
    .byte $73,$FD,$03,$7E
    .byte $73,$FF,$01,$7E
    .byte $73,$01,$01,$7F
    .byte $73,$03,$03,$7E
    .byte $73,$05,$04,$65
    .byte $73,$06,$07,$7E
    .byte $73,$08,$09,$7F
    .byte $73,$0A,$0B,$7E
    .byte $73,$0C,$0A,$61
    .byte $73,$0E,$0F,$7E
    .byte $73,$0F,$0C,$59
    .byte $73,$11,$13,$7E
    .byte $73,$13,$15,$7F
    .byte $73,$15,$17,$7E
    .byte $73,$17,$18,$79
    .byte $73,$19,$18,$70
    .byte $73,$1A,$1A,$71
    .byte $73,$1C,$1F,$7E
    .byte $73,$1E,$1C,$6B
    .byte $73,$20,$23,$7E
    .byte $73,$22,$20,$6D
    .byte $73,$24,$27,$7E
    .byte $73,$25,$1B,$53
    .byte $73,$27,$2B,$7E
    .byte $73,$29,$28,$70
    .byte $73,$2B,$2F,$7E
    .byte $73,$2D,$23,$5A
    .byte $73,$2E,$33,$7E
    .byte $73,$30,$2D,$6B
    .byte $73,$32,$30,$6E
    .byte $73,$34,$34,$73
    .byte $73,$36,$2C,$5E
    .byte $73,$38,$3D,$7E
    .res 4 ; to bring it up to 256 bytes per angle
precast_1:
    .byte $80,$F7,$09,$7F
    .byte $7F,$F9,$05,$56
    .byte $7F,$FA,$05,$6F
    .byte $7E,$FC,$04,$7D
    .byte $7D,$FE,$02,$6A
    .byte $7C,$FF,$00,$7F
    .byte $7C,$01,$01,$7C
    .byte $7B,$03,$02,$5C
    .byte $7A,$04,$04,$71
    .byte $7A,$06,$06,$79
    .byte $79,$08,$06,$5E
    .byte $78,$09,$09,$73
    .byte $78,$0B,$09,$61
    .byte $77,$0D,$0D,$79
    .byte $76,$0E,$0B,$5A
    .byte $75,$10,$0E,$66
    .byte $75,$12,$12,$76
    .byte $74,$14,$15,$7D
    .byte $73,$15,$14,$6D
    .byte $73,$17,$19,$7E
    .byte $72,$19,$0E,$41
    .byte $71,$1A,$19,$6C
    .byte $71,$1C,$1D,$75
    .byte $70,$1E,$20,$79
    .byte $6F,$1F,$1B,$60
    .byte $6E,$21,$22,$72
    .byte $6E,$23,$23,$6F
    .byte $6D,$24,$2A,$7F
    .byte $6C,$26,$22,$61
    .byte $6C,$28,$2A,$72
    .byte $6B,$29,$2E,$77
    .byte $6A,$2B,$33,$7E
    .byte $6A,$2D,$24,$55
    .byte $69,$2E,$2E,$68
    .byte $68,$30,$35,$73
    .byte $68,$32,$32,$68
    .byte $67,$33,$3F,$7E
    .byte $66,$35,$40,$7B
    .byte $65,$37,$43,$7C
    .byte $65,$39,$3C,$6B
    .byte $64,$3A,$39,$62
    .byte $63,$3C,$2F,$4E
    .byte $63,$3E,$49,$75
    .byte $62,$3F,$47,$6E
    .byte $61,$41,$54,$7E
    .byte $61,$43,$50,$74
    .byte $60,$44,$2F,$42
    .byte $5F,$46,$56,$75
    .byte $5E,$48,$5B,$78
    .byte $5E,$49,$56,$6E
    .byte $5D,$4B,$53,$67
    .byte $5C,$4D,$53,$64
    .byte $5C,$4E,$64,$75
    .byte $5B,$50,$5F,$6C
    .byte $5A,$52,$56,$5F
    .byte $5A,$53,$6C,$74
    .byte $59,$55,$70,$75
    .byte $58,$57,$7A,$7C
    .byte $58,$58,$5C,$5B
    .byte $57,$5A,$6C,$68
    .byte $56,$5C,$71,$6A
    .byte $55,$5E,$68,$5F
    .byte $55,$5F,$64,$59
    .res 4 ; to bring it up to 256 bytes per angle
precast_2:
    .byte $7A,$29,$2A,$7F
    .byte $78,$2A,$29,$76
    .byte $77,$2B,$2A,$74
    .byte $76,$2C,$1A,$45
    .byte $75,$2E,$28,$66
    .byte $73,$2F,$2A,$67
    .byte $72,$30,$24,$55
    .byte $71,$32,$33,$74
    .byte $6F,$33,$2A,$5C
    .byte $6E,$34,$35,$70
    .byte $6D,$35,$37,$70
    .byte $6B,$37,$39,$70
    .byte $6A,$38,$3A,$6E
    .byte $69,$39,$42,$79
    .byte $68,$3B,$41,$73
    .byte $66,$3C,$45,$76
    .byte $65,$3D,$48,$77
    .byte $64,$3E,$4B,$78
    .byte $62,$40,$42,$66
    .byte $61,$41,$54,$7E
    .byte $60,$42,$2F,$44
    .byte $5F,$44,$57,$7A
    .byte $5D,$45,$4C,$67
    .byte $5C,$46,$60,$7E
    .byte $5B,$47,$55,$6C
    .byte $59,$49,$5B,$70
    .byte $58,$4A,$5E,$70
    .byte $57,$4B,$6E,$7F
    .byte $56,$4D,$6E,$7B
    .byte $54,$4E,$6C,$75
    .byte $53,$4F,$66,$6B
    .byte $52,$50,$7D,$7F
    .byte $50,$52,$40,$3F
    .byte $4F,$53,$6C,$67
    .byte $4E,$54,$76,$6D
    .byte $4D,$56,$72,$66
    .byte $4B,$57,$71,$62
    .byte $4A,$58,$51,$44
    .byte $49,$59,$7B,$64
    .byte $47,$5B,$7F,$64
    .byte $46,$5C,$7A,$5D
    .byte $45,$5D,$7E,$5D
    .byte $44,$5F,$7B,$58
    .byte $42,$60,$51,$38
    .byte $41,$61,$7F,$55
    .byte $40,$62,$77,$4D
    .byte $3E,$64,$7B,$4D
    .byte $3D,$65,$72,$45
    .byte $3C,$66,$5E,$37
    .byte $3B,$68,$7A,$45
    .byte $39,$69,$77,$41
    .byte $38,$6A,$5B,$30
    .byte $37,$6B,$6E,$38
    .byte $35,$6D,$72,$38
    .byte $34,$6E,$74,$37
    .byte $33,$6F,$7F,$3A
    .byte $32,$71,$6D,$30
    .byte $30,$72,$5C,$27
    .byte $2F,$73,$4C,$1F
    .byte $2E,$75,$4F,$1F
    .byte $2C,$76,$72,$2B
    .byte $2B,$77,$7F,$2E
    .byte $2A,$78,$73,$28
    .res 4 ; to bring it up to 256 bytes per angle
precast_3:
    .byte $61,$54,$62,$71
    .byte $5F,$55,$61,$6D
    .byte $5E,$55,$74,$7F
    .byte $5C,$56,$69,$70
    .byte $5A,$57,$67,$6B
    .byte $58,$58,$5A,$5B
    .byte $57,$58,$7D,$7B
    .byte $55,$59,$5E,$5A
    .byte $53,$5A,$66,$5F
    .byte $52,$5A,$4A,$43
    .byte $50,$5B,$7D,$6E
    .byte $4E,$5C,$7C,$6A
    .byte $4D,$5C,$6A,$58
    .byte $4B,$5D,$43,$36
    .byte $49,$5E,$4E,$3D
    .byte $48,$5E,$74,$58
    .byte $46,$5F,$66,$4B
    .byte $44,$60,$49,$34
    .byte $43,$61,$64,$45
    .byte $41,$61,$7F,$55
    .byte $3F,$62,$4F,$33
    .byte $3E,$63,$7D,$4E
    .byte $3C,$63,$49,$2C
    .byte $3A,$64,$6E,$40
    .byte $39,$65,$7B,$45
    .byte $37,$65,$6F,$3C
    .byte $35,$66,$62,$33
    .byte $33,$67,$7F,$40
    .byte $32,$68,$4F,$26
    .byte $30,$68,$75,$36
    .byte $2E,$69,$71,$32
    .byte $2D,$6A,$76,$32
    .byte $2B,$6A,$79,$31
    .byte $29,$6B,$4B,$1D
    .byte $28,$6C,$7A,$2D
    .byte $26,$6C,$4D,$1B
    .byte $24,$6D,$7E,$2A
    .byte $23,$6E,$72,$24
    .byte $21,$6E,$7C,$25
    .byte $1F,$6F,$67,$1D
    .byte $1E,$70,$66,$1B
    .byte $1C,$71,$79,$1E
    .byte $1A,$71,$5F,$16
    .byte $19,$72,$74,$19
    .byte $17,$73,$7D,$19
    .byte $15,$73,$62,$12
    .byte $14,$74,$77,$14
    .byte $12,$75,$48,$0B
    .byte $10,$75,$50,$0B
    .byte $0E,$76,$62,$0C
    .byte $0D,$77,$5D,$0A
    .byte $0B,$78,$56,$08
    .byte $09,$78,$66,$08
    .byte $08,$79,$7D,$08
    .byte $06,$7A,$78,$06
    .byte $04,$7A,$70,$04
    .byte $03,$7B,$5B,$02
    .byte $01,$7C,$7B,$01
    .byte $FF,$7C,$5B,$00
    .byte $FE,$7D,$69,$02
    .byte $FC,$7E,$7C,$04
    .byte $FA,$7F,$6E,$05
    .byte $F9,$7F,$67,$06
    .res 4 ; to bring it up to 256 bytes per angle
precast_4:
    .byte $39,$73,$7F,$40
    .byte $38,$73,$5F,$2E
    .byte $36,$73,$7E,$3B
    .byte $34,$73,$5F,$2B
    .byte $32,$73,$47,$1F
    .byte $30,$73,$72,$30
    .byte $2E,$73,$54,$22
    .byte $2D,$73,$71,$2C
    .byte $2B,$73,$43,$19
    .byte $29,$73,$7B,$2C
    .byte $27,$73,$7B,$2A
    .byte $25,$73,$56,$1C
    .byte $24,$73,$71,$23
    .byte $22,$73,$77,$23
    .byte $20,$73,$73,$20
    .byte $1E,$73,$67,$1B
    .byte $1C,$73,$41,$10
    .byte $1A,$73,$75,$1B
    .byte $19,$73,$79,$1A
    .byte $17,$73,$7D,$19
    .byte $15,$73,$73,$15
    .byte $13,$73,$7D,$15
    .byte $11,$73,$6A,$10
    .byte $0F,$73,$6F,$0F
    .byte $0E,$73,$6D,$0D
    .byte $0C,$73,$74,$0C
    .byte $0A,$73,$67,$09
    .byte $08,$73,$7D,$09
    .byte $06,$73,$7D,$07
    .byte $05,$73,$7D,$05
    .byte $03,$73,$7D,$03
    .byte $01,$73,$7D,$01
    .byte $FF,$73,$7E,$01
    .byte $FD,$73,$7E,$03
    .byte $FB,$73,$7E,$05
    .byte $FA,$73,$7E,$07
    .byte $F8,$73,$7E,$09
    .byte $F6,$73,$7E,$0B
    .byte $F4,$73,$7E,$0D
    .byte $F2,$73,$7E,$0F
    .byte $F1,$73,$7E,$11
    .byte $EF,$73,$7E,$13
    .byte $ED,$73,$7E,$15
    .byte $EB,$73,$7E,$17
    .byte $E9,$73,$7E,$19
    .byte $E7,$73,$7E,$1B
    .byte $E6,$73,$7E,$1D
    .byte $E4,$73,$7E,$1F
    .byte $E2,$73,$7E,$21
    .byte $E0,$73,$7E,$23
    .byte $DE,$73,$7E,$25
    .byte $DC,$73,$7E,$27
    .byte $DB,$73,$7E,$29
    .byte $D9,$73,$7E,$2B
    .byte $D7,$73,$7E,$2D
    .byte $D5,$73,$7E,$2F
    .byte $D3,$73,$7E,$31
    .byte $D2,$73,$7E,$33
    .byte $D0,$73,$7E,$35
    .byte $CE,$73,$47,$1F
    .byte $CC,$73,$7E,$39
    .byte $CA,$73,$7E,$3B
    .byte $C8,$73,$7E,$3D
    .res 4 ; to bring it up to 256 bytes per angle
precast_5:
    .byte $09,$80,$7E,$09
    .byte $07,$7F,$67,$06
    .byte $06,$7F,$6E,$05
    .byte $04,$7E,$7C,$04
    .byte $02,$7D,$69,$02
    .byte $01,$7C,$5B,$00
    .byte $FF,$7C,$7B,$01
    .byte $FD,$7B,$5B,$02
    .byte $FC,$7A,$70,$04
    .byte $FA,$7A,$78,$06
    .byte $F8,$79,$7D,$08
    .byte $F7,$78,$66,$08
    .byte $F5,$78,$56,$08
    .byte $F3,$77,$5D,$0A
    .byte $F2,$76,$62,$0C
    .byte $F0,$75,$50,$0B
    .byte $EE,$75,$48,$0B
    .byte $EC,$74,$77,$14
    .byte $EB,$73,$62,$12
    .byte $E9,$73,$7D,$19
    .byte $E7,$72,$74,$19
    .byte $E6,$71,$5F,$16
    .byte $E4,$71,$79,$1E
    .byte $E2,$70,$66,$1B
    .byte $E1,$6F,$67,$1D
    .byte $DF,$6E,$7C,$25
    .byte $DD,$6E,$72,$24
    .byte $DC,$6D,$7E,$2A
    .byte $DA,$6C,$4D,$1B
    .byte $D8,$6C,$7A,$2D
    .byte $D7,$6B,$4B,$1D
    .byte $D5,$6A,$79,$31
    .byte $D3,$6A,$76,$32
    .byte $D2,$69,$71,$32
    .byte $D0,$68,$75,$36
    .byte $CE,$68,$4F,$26
    .byte $CD,$67,$7F,$40
    .byte $CB,$66,$62,$33
    .byte $C9,$65,$6F,$3C
    .byte $C7,$65,$7B,$45
    .byte $C6,$64,$6E,$40
    .byte $C4,$63,$49,$2C
    .byte $C2,$63,$7D,$4E
    .byte $C1,$62,$4F,$33
    .byte $BF,$61,$7F,$55
    .byte $BD,$61,$64,$45
    .byte $BC,$60,$49,$34
    .byte $BA,$5F,$66,$4B
    .byte $B8,$5E,$74,$58
    .byte $B7,$5E,$4E,$3D
    .byte $B5,$5D,$43,$36
    .byte $B3,$5C,$6A,$58
    .byte $B2,$5C,$7C,$6A
    .byte $B0,$5B,$7D,$6E
    .byte $AE,$5A,$4A,$43
    .byte $AD,$5A,$66,$5F
    .byte $AB,$59,$5E,$5A
    .byte $A9,$58,$7D,$7B
    .byte $A8,$58,$5A,$5B
    .byte $A6,$57,$67,$6B
    .byte $A4,$56,$69,$70
    .byte $A2,$55,$74,$7F
    .byte $A1,$55,$61,$6D
    .res 4 ; to bring it up to 256 bytes per angle
precast_6:
    .byte $D7,$7A,$7E,$2A
    .byte $D6,$78,$73,$28
    .byte $D5,$77,$7F,$2E
    .byte $D4,$76,$7A,$2E
    .byte $D2,$75,$4F,$1F
    .byte $D1,$73,$4C,$1F
    .byte $D0,$72,$76,$32
    .byte $CE,$71,$7D,$37
    .byte $CD,$6F,$7F,$3A
    .byte $CC,$6E,$72,$36
    .byte $CB,$6D,$72,$38
    .byte $C9,$6B,$6E,$38
    .byte $C8,$6A,$6E,$3A
    .byte $C7,$69,$77,$41
    .byte $C5,$68,$73,$41
    .byte $C4,$66,$6A,$3E
    .byte $C3,$65,$72,$45
    .byte $C2,$64,$7B,$4D
    .byte $C0,$62,$77,$4D
    .byte $BF,$61,$7F,$55
    .byte $BE,$60,$51,$38
    .byte $BC,$5F,$7E,$5A
    .byte $BB,$5D,$7E,$5D
    .byte $BA,$5C,$7A,$5D
    .byte $B9,$5B,$5E,$4A
    .byte $B7,$59,$7B,$64
    .byte $B6,$58,$51,$44
    .byte $B5,$57,$78,$68
    .byte $B3,$56,$72,$66
    .byte $B2,$54,$76,$6D
    .byte $B1,$53,$56,$52
    .byte $B0,$52,$7F,$7D
    .byte $AE,$50,$7D,$7F
    .byte $AD,$4F,$52,$56
    .byte $AC,$4E,$6C,$75
    .byte $AA,$4D,$66,$72
    .byte $A9,$4B,$68,$78
    .byte $A8,$4A,$5E,$70
    .byte $A7,$49,$5B,$70
    .byte $A5,$47,$4A,$5E
    .byte $A4,$46,$60,$7E
    .byte $A3,$45,$4C,$67
    .byte $A1,$44,$5A,$7E
    .byte $A0,$42,$2F,$44
    .byte $9F,$41,$54,$7E
    .byte $9E,$40,$4D,$77
    .byte $9C,$3E,$4B,$78
    .byte $9B,$3D,$48,$77
    .byte $9A,$3C,$3E,$6A
    .byte $98,$3B,$41,$73
    .byte $97,$39,$42,$79
    .byte $96,$38,$3A,$6E
    .byte $95,$37,$39,$70
    .byte $93,$35,$37,$70
    .byte $92,$34,$36,$72
    .byte $91,$33,$2A,$5C
    .byte $8F,$32,$37,$7D
    .byte $8E,$30,$32,$76
    .byte $8D,$2F,$2A,$67
    .byte $8B,$2E,$28,$66
    .byte $8A,$2C,$2E,$7A
    .byte $89,$2B,$2A,$74
    .byte $88,$2A,$29,$76
    .res 4 ; to bring it up to 256 bytes per angle
precast_7:
    .byte $AC,$61,$62,$55
    .byte $AB,$5F,$64,$59
    .byte $AB,$5E,$68,$5F
    .byte $AA,$5C,$71,$6A
    .byte $A9,$5A,$6C,$68
    .byte $A8,$58,$5C,$5B
    .byte $A8,$57,$7A,$7C
    .byte $A7,$55,$70,$75
    .byte $A6,$53,$6C,$74
    .byte $A6,$52,$56,$5F
    .byte $A5,$50,$5F,$6C
    .byte $A4,$4E,$64,$75
    .byte $A4,$4D,$53,$64
    .byte $A3,$4B,$53,$67
    .byte $A2,$49,$56,$6E
    .byte $A2,$48,$5B,$78
    .byte $A1,$46,$56,$75
    .byte $A0,$44,$2F,$42
    .byte $9F,$43,$50,$74
    .byte $9F,$41,$54,$7E
    .byte $9E,$3F,$47,$6E
    .byte $9D,$3E,$49,$75
    .byte $9D,$3C,$2F,$4E
    .byte $9C,$3A,$39,$62
    .byte $9B,$39,$3C,$6B
    .byte $9B,$37,$43,$7C
    .byte $9A,$35,$40,$7B
    .byte $99,$33,$3F,$7E
    .byte $98,$32,$32,$68
    .byte $98,$30,$35,$73
    .byte $97,$2E,$2E,$68
    .byte $96,$2D,$24,$55
    .byte $96,$2B,$33,$7E
    .byte $95,$29,$2E,$77
    .byte $94,$28,$2A,$72
    .byte $94,$26,$22,$61
    .byte $93,$24,$2A,$7F
    .byte $92,$23,$23,$6F
    .byte $92,$21,$22,$72
    .byte $91,$1F,$1B,$60
    .byte $90,$1E,$20,$79
    .byte $8F,$1C,$1D,$75
    .byte $8F,$1A,$19,$6C
    .byte $8E,$19,$0E,$41
    .byte $8D,$17,$19,$7E
    .byte $8D,$15,$14,$6D
    .byte $8C,$14,$15,$7D
    .byte $8B,$12,$12,$76
    .byte $8B,$10,$0E,$66
    .byte $8A,$0E,$0B,$5A
    .byte $89,$0D,$0D,$79
    .byte $88,$0B,$09,$61
    .byte $88,$09,$09,$73
    .byte $87,$08,$06,$5E
    .byte $86,$06,$06,$79
    .byte $86,$04,$04,$71
    .byte $85,$03,$02,$5C
    .byte $84,$01,$01,$7C
    .byte $84,$FF,$00,$7F
    .byte $83,$FE,$02,$6A
    .byte $82,$FC,$04,$7D
    .byte $81,$FA,$05,$6F
    .byte $81,$F9,$05,$56
    .res 4 ; to bring it up to 256 bytes per angle
precast_8:
    .byte $8D,$39,$3F,$7E
    .byte $8D,$38,$3D,$7E
    .byte $8D,$36,$3B,$7E
    .byte $8D,$34,$39,$7E
    .byte $8D,$32,$37,$7E
    .byte $8D,$30,$35,$7E
    .byte $8D,$2E,$33,$7E
    .byte $8D,$2D,$31,$7E
    .byte $8D,$2B,$2F,$7E
    .byte $8D,$29,$2D,$7E
    .byte $8D,$27,$2B,$7E
    .byte $8D,$25,$29,$7E
    .byte $8D,$24,$27,$7E
    .byte $8D,$22,$25,$7E
    .byte $8D,$20,$23,$7E
    .byte $8D,$1E,$21,$7E
    .byte $8D,$1C,$1F,$7E
    .byte $8D,$1A,$1D,$7E
    .byte $8D,$19,$1B,$7E
    .byte $8D,$17,$19,$7E
    .byte $8D,$15,$17,$7E
    .byte $8D,$13,$15,$7E
    .byte $8D,$11,$13,$7E
    .byte $8D,$0F,$11,$7E
    .byte $8D,$0E,$0F,$7E
    .byte $8D,$0C,$0D,$7E
    .byte $8D,$0A,$0B,$7E
    .byte $8D,$08,$09,$7E
    .byte $8D,$06,$07,$7E
    .byte $8D,$05,$05,$7E
    .byte $8D,$03,$03,$7E
    .byte $8D,$01,$01,$7E
    .byte $8D,$FF,$01,$7F
    .byte $8D,$FD,$03,$7F
    .byte $8D,$FB,$04,$65
    .byte $8D,$FA,$07,$7F
    .byte $8D,$F8,$09,$7F
    .byte $8D,$F6,$0A,$73
    .byte $8D,$F4,$0A,$61
    .byte $8D,$F2,$0C,$65
    .byte $8D,$F1,$0C,$59
    .byte $8D,$EF,$0B,$49
    .byte $8D,$ED,$15,$7F
    .byte $8D,$EB,$16,$79
    .byte $8D,$E9,$18,$79
    .byte $8D,$E7,$19,$75
    .byte $8D,$E6,$1A,$71
    .byte $8D,$E4,$1E,$7A
    .byte $8D,$E2,$1C,$6B
    .byte $8D,$E0,$21,$77
    .byte $8D,$DE,$20,$6D
    .byte $8D,$DC,$1E,$61
    .byte $8D,$DB,$1B,$53
    .byte $8D,$D9,$1D,$55
    .byte $8D,$D7,$29,$73
    .byte $8D,$D5,$2C,$76
    .byte $8D,$D3,$2F,$79
    .byte $8D,$D2,$24,$59
    .byte $8D,$D0,$2D,$6B
    .byte $8D,$CE,$30,$6E
    .byte $8D,$CC,$34,$73
    .byte $8D,$CA,$2C,$5E
    .byte $8D,$C8,$3C,$7C
    .res 4 ; to bring it up to 256 bytes per angle
precast_9:
    .byte $80,$09,$09,$7F
    .byte $81,$07,$05,$56
    .byte $81,$06,$05,$6F
    .byte $82,$04,$04,$7D
    .byte $83,$02,$02,$6A
    .byte $84,$01,$00,$7F
    .byte $84,$FF,$01,$7C
    .byte $85,$FD,$02,$5C
    .byte $86,$FC,$04,$71
    .byte $86,$FA,$06,$79
    .byte $87,$F8,$06,$5E
    .byte $88,$F7,$09,$73
    .byte $88,$F5,$09,$61
    .byte $89,$F3,$0D,$79
    .byte $8A,$F2,$0B,$5A
    .byte $8B,$F0,$0E,$66
    .byte $8B,$EE,$12,$76
    .byte $8C,$EC,$15,$7D
    .byte $8D,$EB,$14,$6D
    .byte $8D,$E9,$19,$7E
    .byte $8E,$E7,$0E,$41
    .byte $8F,$E6,$19,$6C
    .byte $8F,$E4,$1D,$75
    .byte $90,$E2,$20,$79
    .byte $91,$E1,$1B,$60
    .byte $92,$DF,$22,$72
    .byte $92,$DD,$23,$6F
    .byte $93,$DC,$2A,$7F
    .byte $94,$DA,$22,$61
    .byte $94,$D8,$2A,$72
    .byte $95,$D7,$2E,$77
    .byte $96,$D5,$33,$7E
    .byte $96,$D3,$24,$55
    .byte $97,$D2,$2E,$68
    .byte $98,$D0,$35,$73
    .byte $98,$CE,$32,$68
    .byte $99,$CD,$3F,$7E
    .byte $9A,$CB,$40,$7B
    .byte $9B,$C9,$43,$7C
    .byte $9B,$C7,$3C,$6B
    .byte $9C,$C6,$39,$62
    .byte $9D,$C4,$2F,$4E
    .byte $9D,$C2,$49,$75
    .byte $9E,$C1,$47,$6E
    .byte $9F,$BF,$54,$7E
    .byte $9F,$BD,$50,$74
    .byte $A0,$BC,$2F,$42
    .byte $A1,$BA,$56,$75
    .byte $A2,$B8,$5B,$78
    .byte $A2,$B7,$56,$6E
    .byte $A3,$B5,$53,$67
    .byte $A4,$B3,$53,$64
    .byte $A4,$B2,$64,$75
    .byte $A5,$B0,$5F,$6C
    .byte $A6,$AE,$56,$5F
    .byte $A6,$AD,$6C,$74
    .byte $A7,$AB,$70,$75
    .byte $A8,$A9,$7A,$7C
    .byte $A8,$A8,$5C,$5B
    .byte $A9,$A6,$6C,$68
    .byte $AA,$A4,$71,$6A
    .byte $AB,$A2,$68,$5F
    .byte $AB,$A1,$64,$59
    .res 4 ; to bring it up to 256 bytes per angle
precast_10:
    .byte $86,$D7,$2A,$7F
    .byte $88,$D6,$29,$76
    .byte $89,$D5,$2A,$74
    .byte $8A,$D4,$1A,$45
    .byte $8B,$D2,$28,$66
    .byte $8D,$D1,$2A,$67
    .byte $8E,$D0,$24,$55
    .byte $8F,$CE,$33,$74
    .byte $91,$CD,$2A,$5C
    .byte $92,$CC,$35,$70
    .byte $93,$CB,$37,$70
    .byte $95,$C9,$39,$70
    .byte $96,$C8,$27,$4A
    .byte $97,$C7,$42,$79
    .byte $98,$C5,$3D,$6C
    .byte $9A,$C4,$45,$76
    .byte $9B,$C3,$48,$77
    .byte $9C,$C2,$4B,$78
    .byte $9E,$C0,$4B,$74
    .byte $9F,$BF,$54,$7E
    .byte $A0,$BE,$2F,$44
    .byte $A1,$BC,$57,$7A
    .byte $A3,$BB,$4C,$67
    .byte $A4,$BA,$60,$7E
    .byte $A5,$B9,$55,$6C
    .byte $A7,$B7,$5B,$70
    .byte $A8,$B6,$5E,$70
    .byte $A9,$B5,$6E,$7F
    .byte $AA,$B3,$6E,$7B
    .byte $AC,$B2,$6C,$75
    .byte $AD,$B1,$66,$6B
    .byte $AE,$B0,$7C,$7E
    .byte $B0,$AE,$40,$3F
    .byte $B1,$AD,$6C,$67
    .byte $B2,$AC,$76,$6D
    .byte $B3,$AA,$7C,$6F
    .byte $B5,$A9,$71,$62
    .byte $B6,$A8,$51,$44
    .byte $B7,$A7,$7B,$64
    .byte $B9,$A5,$7F,$64
    .byte $BA,$A4,$7A,$5D
    .byte $BB,$A3,$7E,$5D
    .byte $BC,$A1,$7B,$58
    .byte $BE,$A0,$51,$38
    .byte $BF,$9F,$7F,$55
    .byte $C0,$9E,$7A,$4F
    .byte $C2,$9C,$7B,$4D
    .byte $C3,$9B,$72,$45
    .byte $C4,$9A,$5E,$37
    .byte $C5,$98,$7A,$45
    .byte $C7,$97,$77,$41
    .byte $C8,$96,$5B,$30
    .byte $C9,$95,$6E,$38
    .byte $CB,$93,$72,$38
    .byte $CC,$92,$74,$37
    .byte $CD,$91,$7F,$3A
    .byte $CE,$8F,$6D,$30
    .byte $D0,$8E,$5C,$27
    .byte $D1,$8D,$4C,$1F
    .byte $D2,$8B,$4F,$1F
    .byte $D4,$8A,$72,$2B
    .byte $D5,$89,$7F,$2E
    .byte $D6,$88,$73,$28
    .res 4 ; to bring it up to 256 bytes per angle
precast_11:
    .byte $9F,$AC,$62,$71
    .byte $A1,$AB,$61,$6D
    .byte $A2,$AB,$74,$7F
    .byte $A4,$AA,$69,$70
    .byte $A6,$A9,$67,$6B
    .byte $A8,$A8,$5A,$5B
    .byte $A9,$A8,$7D,$7B
    .byte $AB,$A7,$5E,$5A
    .byte $AD,$A6,$66,$5F
    .byte $AE,$A6,$4A,$43
    .byte $B0,$A5,$7D,$6E
    .byte $B2,$A4,$7C,$6A
    .byte $B3,$A4,$6A,$58
    .byte $B5,$A3,$43,$36
    .byte $B7,$A2,$4E,$3D
    .byte $B8,$A2,$74,$58
    .byte $BA,$A1,$66,$4B
    .byte $BC,$A0,$49,$34
    .byte $BD,$9F,$64,$45
    .byte $BF,$9F,$7F,$55
    .byte $C1,$9E,$4F,$33
    .byte $C2,$9D,$7D,$4E
    .byte $C4,$9D,$49,$2C
    .byte $C6,$9C,$6E,$40
    .byte $C7,$9B,$7B,$45
    .byte $C9,$9B,$6F,$3C
    .byte $CB,$9A,$62,$33
    .byte $CD,$99,$7F,$40
    .byte $CE,$98,$4F,$26
    .byte $D0,$98,$75,$36
    .byte $D2,$97,$71,$32
    .byte $D3,$96,$76,$32
    .byte $D5,$96,$79,$31
    .byte $D7,$95,$4B,$1D
    .byte $D8,$94,$7A,$2D
    .byte $DA,$94,$4D,$1B
    .byte $DC,$93,$7E,$2A
    .byte $DD,$92,$72,$24
    .byte $DF,$92,$7C,$25
    .byte $E1,$91,$67,$1D
    .byte $E2,$90,$66,$1B
    .byte $E4,$8F,$79,$1E
    .byte $E6,$8F,$5F,$16
    .byte $E7,$8E,$74,$19
    .byte $E9,$8D,$7D,$19
    .byte $EB,$8D,$62,$12
    .byte $EC,$8C,$77,$14
    .byte $EE,$8B,$48,$0B
    .byte $F0,$8B,$50,$0B
    .byte $F2,$8A,$62,$0C
    .byte $F3,$89,$5D,$0A
    .byte $F5,$88,$56,$08
    .byte $F7,$88,$66,$08
    .byte $F8,$87,$7D,$08
    .byte $FA,$86,$78,$06
    .byte $FC,$86,$70,$04
    .byte $FD,$85,$5B,$02
    .byte $FF,$84,$7B,$01
    .byte $01,$84,$5B,$00
    .byte $02,$83,$69,$02
    .byte $04,$82,$7C,$04
    .byte $06,$81,$6E,$05
    .byte $07,$81,$67,$06
    .res 4 ; to bring it up to 256 bytes per angle
precast_12:
    .byte $C7,$8D,$7F,$40
    .byte $C8,$8D,$5F,$2E
    .byte $CA,$8D,$4F,$25
    .byte $CC,$8D,$5F,$2B
    .byte $CE,$8D,$47,$1F
    .byte $D0,$8D,$72,$30
    .byte $D2,$8D,$79,$31
    .byte $D3,$8D,$71,$2C
    .byte $D5,$8D,$43,$19
    .byte $D7,$8D,$7B,$2C
    .byte $D9,$8D,$7B,$2A
    .byte $DB,$8D,$56,$1C
    .byte $DC,$8D,$71,$23
    .byte $DE,$8D,$77,$23
    .byte $E0,$8D,$73,$20
    .byte $E2,$8D,$67,$1B
    .byte $E4,$8D,$41,$10
    .byte $E6,$8D,$75,$1B
    .byte $E7,$8D,$79,$1A
    .byte $E9,$8D,$7D,$19
    .byte $EB,$8D,$73,$15
    .byte $ED,$8D,$7D,$15
    .byte $EF,$8D,$6A,$10
    .byte $F1,$8D,$6F,$0F
    .byte $F2,$8D,$6D,$0D
    .byte $F4,$8D,$74,$0C
    .byte $F6,$8D,$67,$09
    .byte $F8,$8D,$7D,$09
    .byte $FA,$8D,$7D,$07
    .byte $FB,$8D,$7D,$05
    .byte $FD,$8D,$7D,$03
    .byte $FF,$8D,$7D,$01
    .byte $01,$8D,$7E,$01
    .byte $03,$8D,$7E,$03
    .byte $05,$8D,$7E,$05
    .byte $06,$8D,$7E,$07
    .byte $08,$8D,$7E,$09
    .byte $0A,$8D,$7E,$0B
    .byte $0C,$8D,$7E,$0D
    .byte $0E,$8D,$7E,$0F
    .byte $0F,$8D,$7E,$11
    .byte $11,$8D,$7E,$13
    .byte $13,$8D,$7E,$15
    .byte $15,$8D,$7E,$17
    .byte $17,$8D,$7E,$19
    .byte $19,$8D,$7E,$1B
    .byte $1A,$8D,$7E,$1D
    .byte $1C,$8D,$7E,$1F
    .byte $1E,$8D,$7E,$21
    .byte $20,$8D,$7E,$23
    .byte $22,$8D,$7E,$25
    .byte $24,$8D,$7E,$27
    .byte $25,$8D,$7E,$29
    .byte $27,$8D,$7E,$2B
    .byte $29,$8D,$7E,$2D
    .byte $2B,$8D,$7E,$2F
    .byte $2D,$8D,$7E,$31
    .byte $2E,$8D,$7E,$33
    .byte $30,$8D,$7E,$35
    .byte $32,$8D,$7E,$37
    .byte $34,$8D,$7E,$39
    .byte $36,$8D,$7E,$3B
    .byte $38,$8D,$7E,$3D
    .res 4 ; to bring it up to 256 bytes per angle
precast_13:
    .byte $F7,$80,$7E,$09
    .byte $F9,$81,$67,$06
    .byte $FA,$81,$6E,$05
    .byte $FC,$82,$7C,$04
    .byte $FE,$83,$69,$02
    .byte $FF,$84,$5B,$00
    .byte $01,$84,$7B,$01
    .byte $03,$85,$5B,$02
    .byte $04,$86,$70,$04
    .byte $06,$86,$78,$06
    .byte $08,$87,$7D,$08
    .byte $09,$88,$66,$08
    .byte $0B,$88,$56,$08
    .byte $0D,$89,$5D,$0A
    .byte $0E,$8A,$62,$0C
    .byte $10,$8B,$50,$0B
    .byte $12,$8B,$48,$0B
    .byte $14,$8C,$77,$14
    .byte $15,$8D,$62,$12
    .byte $17,$8D,$7D,$19
    .byte $19,$8E,$74,$19
    .byte $1A,$8F,$5F,$16
    .byte $1C,$8F,$79,$1E
    .byte $1E,$90,$66,$1B
    .byte $1F,$91,$67,$1D
    .byte $21,$92,$7C,$25
    .byte $23,$92,$72,$24
    .byte $24,$93,$7E,$2A
    .byte $26,$94,$4D,$1B
    .byte $28,$94,$7A,$2D
    .byte $29,$95,$4B,$1D
    .byte $2B,$96,$79,$31
    .byte $2D,$96,$76,$32
    .byte $2E,$97,$71,$32
    .byte $30,$98,$75,$36
    .byte $32,$98,$4F,$26
    .byte $33,$99,$7F,$40
    .byte $35,$9A,$62,$33
    .byte $37,$9B,$6F,$3C
    .byte $39,$9B,$7B,$45
    .byte $3A,$9C,$6E,$40
    .byte $3C,$9D,$49,$2C
    .byte $3E,$9D,$7D,$4E
    .byte $3F,$9E,$4F,$33
    .byte $41,$9F,$7F,$55
    .byte $43,$9F,$64,$45
    .byte $44,$A0,$49,$34
    .byte $46,$A1,$66,$4B
    .byte $48,$A2,$74,$58
    .byte $49,$A2,$4E,$3D
    .byte $4B,$A3,$43,$36
    .byte $4D,$A4,$6A,$58
    .byte $4E,$A4,$7C,$6A
    .byte $50,$A5,$7D,$6E
    .byte $52,$A6,$4A,$43
    .byte $53,$A6,$66,$5F
    .byte $55,$A7,$5E,$5A
    .byte $57,$A8,$7D,$7B
    .byte $58,$A8,$5A,$5B
    .byte $5A,$A9,$67,$6B
    .byte $5C,$AA,$69,$70
    .byte $5E,$AB,$74,$7F
    .byte $5F,$AB,$61,$6D
    .res 4 ; to bring it up to 256 bytes per angle
precast_14:
    .byte $29,$86,$7E,$2A
    .byte $2A,$88,$73,$28
    .byte $2B,$89,$7F,$2E
    .byte $2C,$8A,$7A,$2E
    .byte $2E,$8B,$4F,$1F
    .byte $2F,$8D,$4C,$1F
    .byte $30,$8E,$76,$32
    .byte $32,$8F,$7D,$37
    .byte $33,$91,$7F,$3A
    .byte $34,$92,$72,$36
    .byte $35,$93,$72,$38
    .byte $37,$95,$6E,$38
    .byte $38,$96,$6E,$3A
    .byte $39,$97,$77,$41
    .byte $3B,$98,$73,$41
    .byte $3C,$9A,$6A,$3E
    .byte $3D,$9B,$72,$45
    .byte $3E,$9C,$7B,$4D
    .byte $40,$9E,$77,$4D
    .byte $41,$9F,$7F,$55
    .byte $42,$A0,$51,$38
    .byte $44,$A1,$7E,$5A
    .byte $45,$A3,$7E,$5D
    .byte $46,$A4,$7A,$5D
    .byte $47,$A5,$5E,$4A
    .byte $49,$A7,$7B,$64
    .byte $4A,$A8,$51,$44
    .byte $4B,$A9,$78,$68
    .byte $4D,$AA,$72,$66
    .byte $4E,$AC,$76,$6D
    .byte $4F,$AD,$56,$52
    .byte $50,$AE,$7F,$7D
    .byte $52,$B0,$7D,$7F
    .byte $53,$B1,$52,$56
    .byte $54,$B2,$6C,$75
    .byte $56,$B3,$66,$72
    .byte $57,$B5,$68,$78
    .byte $58,$B6,$5E,$70
    .byte $59,$B7,$5B,$70
    .byte $5B,$B9,$4A,$5E
    .byte $5C,$BA,$60,$7E
    .byte $5D,$BB,$4C,$67
    .byte $5F,$BC,$5A,$7E
    .byte $60,$BE,$2F,$44
    .byte $61,$BF,$54,$7E
    .byte $62,$C0,$4D,$77
    .byte $64,$C2,$4B,$78
    .byte $65,$C3,$48,$77
    .byte $66,$C4,$3E,$6A
    .byte $68,$C5,$41,$73
    .byte $69,$C7,$42,$79
    .byte $6A,$C8,$3A,$6E
    .byte $6B,$C9,$39,$70
    .byte $6D,$CB,$37,$70
    .byte $6E,$CC,$36,$72
    .byte $6F,$CD,$2A,$5C
    .byte $71,$CE,$37,$7D
    .byte $72,$D0,$32,$76
    .byte $73,$D1,$2A,$67
    .byte $75,$D2,$28,$66
    .byte $76,$D4,$2E,$7A
    .byte $77,$D5,$2A,$74
    .byte $78,$D6,$29,$76
    .res 4 ; to bring it up to 256 bytes per angle
precast_15:
    .byte $54,$9F,$62,$55
    .byte $55,$A1,$64,$59
    .byte $55,$A2,$68,$5F
    .byte $56,$A4,$71,$6A
    .byte $57,$A6,$6C,$68
    .byte $58,$A8,$5C,$5B
    .byte $58,$A9,$7A,$7C
    .byte $59,$AB,$70,$75
    .byte $5A,$AD,$6C,$74
    .byte $5A,$AE,$56,$5F
    .byte $5B,$B0,$5F,$6C
    .byte $5C,$B2,$64,$75
    .byte $5C,$B3,$53,$64
    .byte $5D,$B5,$53,$67
    .byte $5E,$B7,$56,$6E
    .byte $5E,$B8,$5B,$78
    .byte $5F,$BA,$56,$75
    .byte $60,$BC,$2F,$42
    .byte $61,$BD,$50,$74
    .byte $61,$BF,$54,$7E
    .byte $62,$C1,$47,$6E
    .byte $63,$C2,$49,$75
    .byte $63,$C4,$2F,$4E
    .byte $64,$C6,$39,$62
    .byte $65,$C7,$3C,$6B
    .byte $65,$C9,$43,$7C
    .byte $66,$CB,$40,$7B
    .byte $67,$CD,$3F,$7E
    .byte $68,$CE,$32,$68
    .byte $68,$D0,$35,$73
    .byte $69,$D2,$2E,$68
    .byte $6A,$D3,$24,$55
    .byte $6A,$D5,$33,$7E
    .byte $6B,$D7,$2E,$77
    .byte $6C,$D8,$2A,$72
    .byte $6C,$DA,$22,$61
    .byte $6D,$DC,$2A,$7F
    .byte $6E,$DD,$23,$6F
    .byte $6E,$DF,$22,$72
    .byte $6F,$E1,$1B,$60
    .byte $70,$E2,$20,$79
    .byte $71,$E4,$1D,$75
    .byte $71,$E6,$19,$6C
    .byte $72,$E7,$0E,$41
    .byte $73,$E9,$19,$7E
    .byte $73,$EB,$14,$6D
    .byte $74,$EC,$15,$7D
    .byte $75,$EE,$12,$76
    .byte $75,$F0,$0E,$66
    .byte $76,$F2,$0B,$5A
    .byte $77,$F3,$0D,$79
    .byte $78,$F5,$09,$61
    .byte $78,$F7,$09,$73
    .byte $79,$F8,$06,$5E
    .byte $7A,$FA,$06,$79
    .byte $7A,$FC,$04,$71
    .byte $7B,$FD,$02,$5C
    .byte $7C,$FF,$01,$7C
    .byte $7C,$01,$00,$7F
    .byte $7D,$02,$02,$6A
    .byte $7E,$04,$04,$7D
    .byte $7F,$06,$05,$6F
    .byte $7F,$07,$05,$56
    .res 4 ; to bring it up to 256 bytes per angle 

codeEnd = *

