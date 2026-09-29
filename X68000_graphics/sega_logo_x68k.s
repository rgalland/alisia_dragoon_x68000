; =============================================================================
; sega_logo_x68k.s — X68000 port of display_sega_logo
; Ported from ad_md_sound_driver.s-adjacent graphics source (alisia_dis.asm),
; "==== SEGA LOGO Assets and routines ====" section, lines ~700-814.
;
; Architecture decision (confirmed with Regis): bitmap blit onto the
; 256-colour graphic layer 0 (GVRAM_PAGE0), NOT the PCG/BG tile-and-nametable
; hardware. Tiles are copied once as pixel data at load time; there is no
; runtime tilemap indirection or hardware scroll on the X68000 side for this
; screen, since the Sega logo never scrolls.
;
; Display timing: CRTC_320_* preset (x68k_hw.i) — a 320x224 15kHz window
; cropped from a confirmed-working 384x240 15kHz timing, left/top-anchored,
; chosen specifically so MD tile/tilemap pixel coordinates (computed against
; a 512-wide plane) carry over with zero rescaling. See x68k_hw.i comments
; for the full derivation.
;
; NOT yet ported (explicitly deferred, see notes at end of file):
;   - Joypad Start-skip logic (Regis is redesigning the joypad/keyboard
;     layer separately)
;   - The one-shot "fade in from black" nudge that prepare_dma_palette_transfer
;     / modify_current_colours performs on palette 0 colours 1,13,14,15
;     before the colour-cycle starts. Traced against the MD source: this
;     produces at most a single +-2-per-channel nudge (not a multi-frame
;     fade — see conversation notes) and only affects 4 of palette 0's 16
;     colours, all of which are outside the 11 colours the visible
;     colour-cycle touches. Low visual impact; can be added later if a
;     side-by-side comparison shows it's noticeable.
;
; Assumes: sega_logo_tiles_8bpp (converted from sega_logo_tileset.bin, 4bpp
; MD tile format -> 8bpp X68000 pixel format, palette indices 0-15,
; preserving original tile numbering/order 1:1 including the unused tile 0)
; has already been produced by a separate offline conversion step, not yet
; written. Tile format: 49 tiles x 64 bytes (8x8 pixels, 1 byte/pixel),
; tile 0 unused/skipped (matches MD source: sega_logo_tilemap references
; tile indices 1-48 only, tile 0's slot is uploaded but never referenced).
; =============================================================================

    include "x68k_hw.i"
    include "x68k_macros.i"
    include "inc/doscall.i"
    include "inc/gfx/palettes.i"

    text
    even

; =============================================================================
; display_sega_logo
; Equivalent of the MD display_sega_logo routine (alisia_dis.asm ~L700-757)
; =============================================================================
display_sega_logo:
    DOS_SUPER
    bsr.w   init_crtc_320x224      ; MD: init_vdp (register setup half only —
                                    ; the MD's vram_fill_dma VRAM-zero call has
                                    ; no direct analogue here; GVRAM is cleared
                                    ; explicitly below instead)

    ; --- Clear graphic layer 0 to colour index 0 ---
    ; MD: reset_vram_bg1_and_2_tilemaps filled BOTH nametables with a blank
    ; tile ($400) under DISABLE_INTERRUPTS, because the MD VDP would show
    ; garbage tile data otherwise. On X68000 there's no nametable to
    ; initialise — the equivalent guarantee is just: the framebuffer starts
    ; at colour index 0 everywhere until we blit real pixels over it.
    CLEAR_GVRAM_L0  0
    CLEAR_GVRAM_L1  0
    CLEAR_GPAL
    CLEAR_SPAL

    ; clear bss variables
    bsr     clear_bg_pal_ram
    bsr     clear_sp_pal_ram

    ; --- Clear graphic palette entries 0-15 (logo's palette block) ---
    ; MD: clear_palettes_0_to_3 + clear_palettes_4_to_7 zeroed all 8 CRAM
    ; palettes (4 words x 8 = 32 words). We only need entries 0-15 here,
    ; since the logo's 8bpp tile data only ever indexes 0-15 (see
    ; conversion note above) and nothing else uses GPAL 16-255 yet.
    lea     (GPAL_BASE),a0
    moveq   #15,d0
.clear_gpal_loop:
    clr.w   (a0)+
    dbf     d0,.clear_gpal_loop

    ; --- Upload and blit tile pixel data directly into place ---
    ; MD: two separate steps — (1) raw copy of all 49 tiles to VRAM address
    ; 0 as a flat blob, then (2) a 12x4 tilemap write that references tile
    ; indices 1-48 by number, landing them at nametable address $C61C
    ; (column 14, row 12 — see conversation notes for the derivation).
    ; X68000: no indirection needed — blit each tile's pixels straight to
    ; its final framebuffer position in one pass, in the same raster order
    ; the MD tilemap used (sega_logo_tilemap is a plain ascending sequence
    ; 1..48, no reordering or flip bits), so no tilemap table is needed at
    ; all on this side.
    lea     (sega_logo_tiles_4bpp+MD_TILE_BYTES),a0   ; skip unused tile 0
    moveq   #3,d6                  ; 4 rows (was moveq #$3,d6 on MD)
    move.w  #LOGO_ORIGIN_Y,d3      ; current row's Y pixel position
.blit_row:
    moveq   #11,d7                 ; 12 columns (was moveq #$b,d5 on MD)
    move.w  #(LOGO_ORIGIN_X),d2  ; current column's X pixel position in words
.blit_col:
    ; NOTE: GVRAM_ADDR_L0's doc comment (x68k_macros.i) claims it clobbers
    ; the Y register, but its actual body only writes the result register
    ; -- traced directly rather than trusting the comment, so no save/
    ; restore of d2/d3 is needed around this call.
    BLIT_TILE_L0 a0,d2,d3,a1        ; a0 auto-advances past this tile
    addq.w  #(TILE_W),d2
    dbf     d7,.blit_col
    addq.w  #TILE_H,d3
    dbf     d6,.blit_row

    ; --- Convert the MD colour-cycle table once, up front ---
    ; See convert_md_colours_to_x68k below. Keeping the MD table verbatim
    ; as the single source of truth (rather than hand-transcribing a
    ; pre-converted table) means any future correction to the original
    ; data doesn't need a parallel manual re-conversion.
    CONVERT_MD_TO_X68K_COLOURS sega_logo_colours_md, sega_logo_colours_x68k, 30

    ; --- Set up initial colour-cycle state and enable display ---
    ; MD: move.w #$0000,(palettes_4) / move.w #CRAM_WHITE,(palettes_4+2)
    ; then moveq #$0,d5 / moveq #$28,d6 / moveq #$0,d7 before enabling
    ; display and entering the wait loop. We don't need the palettes_4
    ; staging area at all (see deferred fade-in note above) — go straight
    ; to the live colour-cycle state.
    moveq   #0,d5                  ; vblank delay counter (reload $3)
    move.w  #COLOUR_CYCLE_START,d6 ; word index into sega_logo_colours_x68k
    moveq   #0,d7                  ; elapsed-frame counter

    lea     (GPAL_BASE),a0
    move.w  #$0000,(a0)+
    move.w  #$fffe,(a0)+
    bsr.w   update_sega_logo_colours_x68k
    
    ; Enable graphic layer 0 + sprite/text stay off for this screen
    move.w  #VC_R2_GAME,(VC_R2)

    REPT 60
        WAIT_VBLANK
    ENDR
    

    ; --- Hold for ~2 seconds, running the colour cycle each VBLANK ---
    ; MD: waits for pad Start (deferred here — see file header) OR a
    ; $0078 (120) frame timeout. Timeout-only version:
.wait_loop:
    WAIT_VBLANK
    bsr.w   update_sega_logo_colours_x68k
    addq.w  #1,d7
    cmpi.w  #120,d7                ; MD used $0078 = 120 frames (~2s)
    bcs.b   .wait_loop

    bsr     play_intro_credits

infinite_loop:
    bra     infinite_loop

    DOS     _EXIT0
    rts




LOGO_ORIGIN_X   equ 112             ; MD tilemap column 14 x 8px, unchanged
                                    ; since our GVRAM crop is left-anchored
LOGO_ORIGIN_Y   equ 96              ; MD tilemap row 12 x 8px, unchanged
                                    ; since our GVRAM crop is top-anchored
COLOUR_CYCLE_START equ $28          ; MD: d6 initial colour offset $28


; =============================================================================
; init_crtc_320x224
; Programs the CRTC + video controller for the 320x224 15kHz mode derived
; in x68k_hw.i, and selects 256-colour/512x512 graphic mode.
; =============================================================================
init_crtc_320x224:
    lea     (CRTC_R00),a0
    move.w  #CRTC_320_R00,(a0)
    move.w  #CRTC_320_R01,(2,a0)
    move.w  #CRTC_320_R02,(4,a0)
    move.w  #CRTC_320_R03,(6,a0)
    move.w  #CRTC_320_R04,(8,a0)
    move.w  #CRTC_320_R05,(10,a0)
    move.w  #CRTC_320_R06,(12,a0)
    move.w  #CRTC_320_R07,(14,a0)
    move.w  #CRTC_320_R08,(16,a0)
    move.w  #CRTC_320_R20,(CRTC_R20)
    move.w  #CRTC_320_R21,(CRTC_R21)

    move.w  #VC_R0_GAME,(VC_R0)     ; 512x512 GVRAM + 256-colour
    move.w  #VC_R1_GAME,(VC_R1)     ; layer priority (sprite/text/graphic)
    move.w  #0,(VC_R2)

    move.w      #$0000,BG0_HSCROLL
    move.w      #$0000,BG0_VSCROLL
    move.w      #$0000,BG1_HSCROLL
    move.w      #$0000,BG1_VSCROLL
    move.w      #$0212,BG_CTRL
    move.w      #$00ff,BG_H_TOTAL
    move.w      #$000f,BG_H_POS
    move.w      #$0031,BG_V_POS
    move.w      #$0000,BG_RES

    ; NOTE: VC_R2 (layer on/off) deliberately NOT set here — display_sega_logo
    ; sets it explicitly after the framebuffer/palette are ready, to avoid
    ; a frame of garbage on screen (mirrors the MD's own DISABLE_INTERRUPTS-
    ; wrapped setup-before-enable ordering).
    rts


; =============================================================================
; convert_md_colours_to_x68k
; One-time conversion of the verbatim MD colour-cycle table into X68000
; GPAL G5-R5-B5 format, into a RAM buffer.
;
; MD CRAM word format:   0000 BBB0 GGG0 RRR0 (3-bit channels, LSB unused)
; X68k GPAL word format: GGGG GRRR RRBB BBBI (5-bit channels + intensity)
;
; Not used - Per-channel scaling uses md3_to_x68k5 (8-entry table, values 0-7 -> 0-31,
; rounded to nearest: v*31/7). See x68k_hw.i's MD-to-X68k conversion note.
; =============================================================================
convert_md_colours_to_x68k:
.convert_loop:
    moveq   #$0,d2                  ; will store x68000 colour result
    move.w  (a0)+,d0                ; d0 = MD colour word
    ; blue: bits 3-1
    move.w  d0,d1
    andi.w  #$000E,d1
    lsl.w   #7,d1
    or      d1,d2
    ; green: bits 7-5
    move.w  d0,d1
    andi.w  #$00E0,d1
    lsl.w   #8,d1
    or      d1,d2
    move.w  d0,d1
    andi.w  #$0E00,d1
    lsr.w   #6,d1
    or      d1,d2
    move.w  d2,(a1)+
    dbf     d3,.convert_loop
    rts


; =============================================================================
; update_sega_logo_colours_x68k
; Direct port of update_sega_logo_colours (alisia_dis.asm ~L784-798).
; Steps backward through sega_logo_colours_x68k one word position every
; 4th call, writing 11 converted colours into GPAL entries 2-12, until the
; index goes negative (matches MD's "bmi .exit" -- this is a one-way run
; through the table, NOT a repeating cycle; MD's original counted DOWN from
; word index 20 to 0, i.e. 21 activations total, ~84 frames at 4 frames each).
; =============================================================================
update_sega_logo_colours_x68k:
    movem.l d0-d2/a0-a1,-(sp)
    subq.w  #1,d5
    bpl.b   .exit
    move.w  #3,d5                    ; reload delay counter
    move.w  d6,d0
    bmi.b   .exit                    ; table exhausted -- stop permanently
    subq.w  #2,d6                    ; move to previous table entry
    lea     (sega_logo_colours_x68k),a0
    adda.w  d0,a0
    lea     (GPAL_BASE+4),a1         ; GPAL entry 2 (colour index 2)
    moveq   #(11-1),d1                   ; 11 colours
.copy_loop:
    move.w  (a0)+,(a1)+
    dbf     d1,.copy_loop
.exit:
    movem.l (sp)+,d0-d2/a0-a1
    rts


; increment_palette_if_palette_target_gt_d7 (00011176)
; d7=colour level, a2=palette addr, a3=palette target addr
increment_palette_if_palette_target_gt_d7:
    move.l      d7,-(SP)
    addq.w      #$1,d7
    lsl.w       #$1,d7
    moveq       #$f,d6
    .loops_16_times:
        move.b      (a2),d0
        cmp.b       (a3)+,d7
        bhi.b       .L0
        cmpi.b      #$0e,d0
        bcc.b       .L0
        addq.w      #$2,d0
    .L0:
        move.b      d0,(a2)+
        move.b      (a3)+,d1
        move.b      d1,d2
        andi.b      #$e0,d1
        lsr.b       #$4,d1
        move.b      (a2),d0
        andi.b      #$e0,d0
        cmp.b       d1,d7
        bhi.b       .L1
        cmpi.b      #$e0,d0
        bcc.b       .L1
        addi.b      #$20,d0
    .L1:
        move.b      d0,d1
        andi.b      #$0e,d2
        move.b      (a2),d0
        andi.b      #$0e,d0
        cmp.b       d2,d7
        bhi.b       .L2
        cmpi.b      #$0e,d0
        bcc.b       .L2
        addq.b      #$2,d0
    .L2:
        or.b        d0,d1
        move.b      d1,(a2)+
        dbf         d6,.loops_16_times
    move.l      (SP)+,d7
    rts

; decrement_palette
; a2=palette addr, clobbers d0,d1,d6
decrement_palette:      ; (0001122e) + 1 to each colour up to 7
    move.l      a2,-(SP)    ; save current A2 value
    DEC_N_COLOURS a2,d6,16
    movea.l     (SP)+,a2    ; restore initial A2 value
    rts

clear_bg_pal_ram:
    move.w  #(16*4-1),d7
.clr_loop:
    lea     (bg_pal0),a0
    clr.w   (a0)+
    dbf     d7,.clr_loop
    rts

clear_sp_pal_ram:
    move.w  #(16*4-1),d7
.clr_loop:
    lea     (sp_pal0),a0
    clr.w   (a0)+
    dbf     d7,.clr_loop
    rts

scroll_left_bg1:
    addq    #1,bg1_x
    move.w  bg1_x,CRTC_R12
    rts

scroll_right_bg1:
    subq    #1,bg1_x
    move.w  bg1_x,CRTC_R12
    rts

scroll_up_bg1:
    addq    #1,bg1_y
    move.w  bg1_y,CRTC_R13
    rts

scroll_down_bg1:
    subq    #1,bg1_y
    move.w  bg1_y,CRTC_R13
    rts

scroll_left_bg2:
    addq    #1,bg2_x
    move.w  (bg2_x),CRTC_R16
    rts

scroll_right_bg2:
    subq    #1,bg2_x
    move.w  (bg2_x),CRTC_R16
    rts

scroll_up_bg2:
    addq    #1,bg2_y
    move.w  bg2_y,CRTC_R17
    rts

scroll_down_bg2:
    subq    #1,bg2_y
    move.w  bg2_y,CRTC_R17
    rts

; include other source files here
    include "tile_decompress_x68k.s"
    include "intro_credits.s"
; =============================================================================
; Data
; =============================================================================

    data
    even
; Verbatim copy of the MD source table (alisia_dis.asm ~L779-782) — kept
; byte-identical to the Z80/MD reference rather than hand-converted, so the
; X68000 build always derives from the same ground truth.
sega_logo_colours_md:
    dw $0ec0, $0ea0, $0e80, $0e60, $0e40, $0e20, $0e00, $0c00
    dw $0a00, $0800, $0600, $0800, $0a00, $0c00, $0e00, $0e20
    dw $0e40, $0e60, $0e80, $0ea0, $0ec0, $0ea0, $0e80, $0e60
    dw $0e40, $0e20, $0e00, $0c00, $0a00, $0800, $0600

sega_logo_tiles_4bpp:
    incbin  "inc/gfx/sega_logo/sega_logo_tileset.bin"

; =============================================================================
; OPEN ITEMS / not yet implemented:
;
; 1. sega_logo_tiles_8bpp — the actual converted tile pixel data. Needs an
;    offline conversion tool (4bpp packed-nibble MD format -> 8bpp
;    1-byte-per-pixel X68000 format). Not written yet; propose as the next
;    concrete piece of work once this routine's structure is confirmed.
;
; 2. Joypad-driven early exit (Regis is redesigning this layer separately
;    to support 2/3-button pads + keyboard; deliberately left out per
;    conversation).
;
; 3. The one-shot pre-cycle fade-in nudge (see file header) — deferred,
;    low visual impact, can revisit if needed after a side-by-side check.
;
; 4. DISABLE_INTERRUPTS/ENABLE_INTERRUPTS are no-ops in x68k_macros.i for
;    Human68k user-mode reasons (see that file's comment). None of this
;    routine's steps are timing-critical against interrupts the way the
;    MD's DMA setup was, so no supervisor-mode workaround was needed here
;    -- worth double-checking once we plug this into the real VBLANK-driven
;    game loop rather than running it standalone at startup.
; =============================================================================

; =============================================================================
; BSS
; =============================================================================

    bss
    even
sega_logo_colours_x68k:
    ds.w    32                       ; filled at runtime by
                                      ; convert_md_colours_to_x68k
bg_vars:
bg1_x: ds.w    1
bg1_y: ds.w    1
bg2_x: ds.w    1
bg2_y: ds.w    1

bg_pal0:
    ds.w    16
bg_md_pal1:
    ds.w    16
bg_md_pal2:
    ds.w    16
bg_md_pal3:
    ds.w    16

sp_pal0:
    ds.w    16
sp_md_pal1:
    ds.w    16
sp_md_pal2:
    ds.w    16
sp_md_pal3:
    ds.w    16

scratch_memory:
    ds.b    65536                    ; scratch memory for doing decompressions
