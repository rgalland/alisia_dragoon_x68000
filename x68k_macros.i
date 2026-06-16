; =============================================================================
; x68k_macros.i — X68000 Utility Macros
; For use with VASM (Motorola 68k syntax)
;
; Include after x68k_hw.i:
;   include "x68k_hw.i"
;   include "x68k_macros.i"
; =============================================================================


; =============================================================================
; CRTC macros
; =============================================================================

; CRTC_WRITE reg, value
; Write an immediate value to a CRTC register
; Clobbers: nothing (uses move.w immediate)
CRTC_WRITE  MACRO
    move.w  #\2,\1
    ENDM

; SET_SCROLL_L0 hscroll_reg, vscroll_reg
; Set horizontal and vertical scroll for graphic layer 0
; \1 = data register holding H scroll value
; \2 = data register holding V scroll value
SET_SCROLL_L0   MACRO
    move.w  \1,(GFX_L0_HSCROLL)
    move.w  \2,(GFX_L0_VSCROLL)
    ENDM

; SET_SCROLL_L1 hscroll_reg, vscroll_reg
; Set horizontal and vertical scroll for graphic layer 1
SET_SCROLL_L1   MACRO
    move.w  \1,(GFX_L1_HSCROLL)
    move.w  \2,(GFX_L1_VSCROLL)
    ENDM


; =============================================================================
; Palette macros
; =============================================================================

; SET_GPAL_ENTRY index, colour
; Write a single colour word to graphic palette entry N
; \1 = palette index (immediate or data register)
; \2 = 16-bit colour word (immediate)
; Clobbers: a0
SET_GPAL_ENTRY  MACRO
    lea     (GPAL_BASE),a0
    move.w  \2,((\1)*GPAL_ENTRY_SIZE,a0)
    ENDM

; COPY_PALETTE src_addr, dst_palette_addr, count
; Copy count colour words from src to palette RAM
; \1 = source address register (a0-a6)
; \2 = destination address register pointing into palette RAM
; \3 = data register holding word count
; Clobbers: \3 (used as dbf counter)
COPY_PALETTE    MACRO
    subq.w  #1,\3
.cp_loop\@:
    move.w  (\1)+,(\2)+
    dbf     \3,.cp_loop\@
    ENDM

; CLEAR_GPAL
; Zero all 256 graphic palette entries (black)
; Clobbers: d0, a0
CLEAR_GPAL  MACRO
    lea     (GPAL_BASE),a0
    move.w  #(GPAL_COUNT-1),d0
.cgp_loop\@:
    clr.w   (a0)+
    dbf     d0,.cgp_loop\@
    ENDM


; =============================================================================
; Graphic VRAM macros
; =============================================================================

; GVRAM_ADDR_L0 x_reg, y_reg, result_reg
; Calculate byte address in graphic layer 0 VRAM for pixel (x,y)
; \1 = data register holding X (pixel column, 0-511)
; \2 = data register holding Y (pixel row,    0-511)
; \3 = address register to receive result
; Formula: GVRAM_PAGE0 + (Y * GVRAM_VWIDTH) + X
; Clobbers: \2 (multiplied in place), \3
GVRAM_ADDR_L0   MACRO
    move.w  \2,\3
    mulu.w  #GVRAM_VWIDTH,\3
    add.w   \1,\3
    lea     (GVRAM_PAGE0,\3.l),\3
    ENDM

; GVRAM_ADDR_L1 x_reg, y_reg, result_reg
; Calculate byte address in graphic layer 1 VRAM for pixel (x,y)
GVRAM_ADDR_L1   MACRO
    move.w  \2,\3
    mulu.w  #GVRAM_VWIDTH,\3
    add.w   \1,\3
    lea     (GVRAM_PAGE2,\3.l),\3
    ENDM

; CLEAR_GVRAM_L0 colour_index
; Fill entire graphic layer 0 VRAM with a colour index byte
; \1 = immediate byte value (colour index)
; Clobbers: d0, d1, a0
; Note: clears full 512x512 = 262144 bytes
CLEAR_GVRAM_L0  MACRO
    lea     (GVRAM_PAGE0),a0
    move.l  #(GVRAM_PAGE_SIZE/4)-1,d0
    move.b  #\1,d1
    lsl.w   #8,d1
    move.b  #\1,d1              ; d1.w = colcol
    swap    d1
    move.w  d1,d1               ; not needed but harmless
    move.b  #\1,d1
    lsl.w   #8,d1
    move.b  #\1,d1
    swap    d1                  ; d1.l = colcolcolcol
.cgl0\@:
    move.l  d1,(a0)+
    dbf     d0,.cgl0\@
    ENDM

; CLEAR_GVRAM_L1 colour_index
; Fill entire graphic layer 1 VRAM with a colour index byte
CLEAR_GVRAM_L1  MACRO
    lea     (GVRAM_PAGE2),a0
    move.l  #(GVRAM_PAGE_SIZE/4)-1,d0
    move.b  #\1,d1
    lsl.w   #8,d1
    move.b  #\1,d1
    swap    d1
    move.b  #\1,d1
    lsl.w   #8,d1
    move.b  #\1,d1
    swap    d1
.cgl1\@:
    move.l  d1,(a0)+
    dbf     d0,.cgl1\@
    ENDM


; =============================================================================
; Tileset copy macros
;
; In 256-colour mode, tile pixel data is 8bpp (1 byte per pixel).
; MD tilesets are 4bpp (2 pixels per byte, packed nibbles).
; After your startup conversion (4bpp -> 8bpp with palette offset applied),
; tiles are stored in RAM as 8bpp ready for direct VRAM copy.
;
; Tile dimensions on X68000 graphic layers:
;   We choose 8x8 tiles to match MD, but any size is valid since the
;   graphic layer is a plain framebuffer — tiles are just rectangular blits.
;
; TILE_W / TILE_H defined here — change if your port uses different tile sizes
; =============================================================================

TILE_W          equ 8               ; tile width in pixels
TILE_H          equ 8               ; tile height in pixels
TILE_BYTES      equ TILE_W*TILE_H   ; bytes per tile in 8bpp = 64

; BLIT_TILE_L0 src_areg, x_dreg, y_dreg, tmp_areg
; Copy one 8x8 8bpp tile from RAM to graphic layer 0 VRAM
; \1 = address register pointing to tile source data (8bpp, 64 bytes)
; \2 = data register holding tile X pixel position
; \3 = data register holding tile Y pixel position
; \4 = scratch address register for VRAM destination
; Clobbers: \4, d7
BLIT_TILE_L0    MACRO
    GVRAM_ADDR_L0 \2,\3,\4         ; calculate VRAM destination
    move.w  #(TILE_H-1),d7
.bt_row\@:
    move.l  (\1)+,(\4)             ; copy 4 pixels
    move.l  (\1)+,(4,\4)           ; copy next 4 pixels
    lea     (GVRAM_VWIDTH,\4),\4   ; advance destination by one row stride
    dbf     d7,.bt_row\@
    ENDM

; BLIT_TILE_L1 src_areg, x_dreg, y_dreg, tmp_areg
; Copy one 8x8 8bpp tile to graphic layer 1 VRAM
BLIT_TILE_L1    MACRO
    GVRAM_ADDR_L1 \2,\3,\4
    move.w  #(TILE_H-1),d7
.bt1_row\@:
    move.l  (\1)+,(\4)
    move.l  (\1)+,(4,\4)
    lea     (GVRAM_VWIDTH,\4),\4
    dbf     d7,.bt1_row\@
    ENDM


; =============================================================================
; Sprite macros
; =============================================================================

; SPRITE_SET index, x, y, pattern, palette, hflip, vflip
; Write all fields of a sprite table entry
; \1 = sprite index (immediate, 0-127)
; \2 = X screen coordinate (immediate or dreg)
; \3 = Y screen coordinate (immediate or dreg)
; \4 = pattern number (immediate, 0-255)
; \5 = palette block (immediate, 0-15)
; \6 = hflip (0 or SP_HFLIP)
; \7 = vflip (0 or SP_VFLIP)
; Clobbers: a0, d0
SPRITE_SET  MACRO
    lea     (SPRITE_TABLE+(\1*SPRITE_ENTRY_SIZE)),a0
    move.w  #(\2+SP_X_OFFSET),(SP_OFF_X,a0)
    move.w  #(\3+SP_Y_OFFSET),(SP_OFF_Y,a0)
    move.w  #((\4<<SP_PATTERN_SHIFT)|\6|\7|\5),(SP_OFF_ATTR,a0)
    ENDM

; SPRITE_LINK index, next_index
; Set the link field of sprite \1 to point to sprite \2
; \1 = this sprite index (immediate)
; \2 = next sprite index (immediate, set equal to \1 to terminate chain)
SPRITE_LINK MACRO
    move.w  #(\2&SP_LINK_MASK),(SPRITE_TABLE+(\1*SPRITE_ENTRY_SIZE)+SP_OFF_LINK)
    ENDM

; SPRITE_HIDE index
; Move a sprite off screen (negative coordinates via offset trick)
; \1 = sprite index (immediate)
; Clobbers: a0
SPRITE_HIDE MACRO
    lea     (SPRITE_TABLE+(\1*SPRITE_ENTRY_SIZE)),a0
    clr.w   (SP_OFF_X,a0)          ; X=0 = SP_X_OFFSET-SP_X_OFFSET = off left
    clr.w   (SP_OFF_Y,a0)
    ENDM

; SPRITE_SET_HEAD index
; Set the sprite display list head in BG_CTRL
; \1 = first sprite index (immediate)
; Clobbers: d0
SPRITE_SET_HEAD MACRO
    move.w  (BG_CTRL),d0
    andi.w  #~($FE00),d0            ; clear old head
    ori.w   #((\1)<<BG_SPRITE_HEAD_SHIFT),d0
    move.w  d0,(BG_CTRL)
    ENDM


; =============================================================================
; Interrupt macros
; =============================================================================

; DISABLE_INTERRUPTS / ENABLE_INTERRUPTS
;
; *** DO NOT USE under Human68k user-mode programs ***
; MOVE SR,<ea> and MOVE <ea>,SR are PRIVILEGED instructions on the 68000.
; Executing either in user mode (which is how Human68k runs .X executables)
; raises a privilege violation exception (vector 8) and crashes the program
; immediately, before any visible output.
;
; If supervisor-mode interrupt masking is genuinely required, use the
; Human68k DOS _SUPER call ($FF20) to switch to supervisor mode first —
; see doscall.i. For installing interrupt handlers via the vector table,
; a plain MOVE.L to the vector table address (e.g. VBLANK_VECTOR*4) is a
; normal RAM write and works fine in user mode without any SR access.
DISABLE_INTERRUPTS  MACRO
    ; intentionally left as a no-op placeholder — see comment above
    ENDM

ENABLE_INTERRUPTS   MACRO
    ; intentionally left as a no-op placeholder — see comment above
    ENDM

; SET_VBLANK_VECTOR addr
; Install a V-blank handler address into the MFP vector table
; \1 = handler routine label
; Clobbers: a0
SET_VBLANK_VECTOR   MACRO
    lea     (\1),a0
    move.l  a0,(VBLANK_VECTOR*4)
    ENDM


; =============================================================================
; Utility macros
; =============================================================================

; WAIT_VBLANK
; Busy-wait for the start of vertical blank by polling CRTC raster register
; Clobbers: d0
WAIT_VBLANK MACRO
.wvb_wait\@:
    move.w  (CRTC_R09),d0          ; read current raster line
    cmpi.w  #SCREEN_HEIGHT,d0      ; wait until we are past visible area
    bcs.b   .wvb_wait\@
    ENDM

; SAVE_REGS
; Push all data and address registers to stack (except SP)
SAVE_REGS   MACRO
    movem.l d0-d7/a0-a6,-(sp)
    ENDM

; RESTORE_REGS
; Pop all data and address registers from stack
RESTORE_REGS    MACRO
    movem.l (sp)+,d0-d7/a0-a6
    ENDM
