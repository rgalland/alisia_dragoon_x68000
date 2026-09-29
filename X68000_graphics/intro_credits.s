    include "inc/gfx/palettes.i"

play_intro_credits:
    ; load intro credits to PAGE1
    lea     intro_credits_ts_p1,a0
    lea     scratch_memory,a1
    bsr     decompress_tileset
    lea     intro_credits_ts_p2,a0
    lea     scratch_memory+$6000,a1
    bsr     decompress_tileset
    ; save to VRAM
    lea     (intro_credits_bg2_tm),a3  ; ($40+$c0/2)*$13 tile sin total (160x24)
    move.w  #$20,d3   ; current row's Y pixel position in VRAM
    moveq   #(20-1),d6 ; intro credits tilemap is 20 rows high
    .blit_intro_credits_row:
        move.w  #0,d2  ; current column's X pixel position in words
        moveq   #(64-1),d7  ; 64 tiles to fit the whole VRAM width (8x64=512px)
        .blit_intro_credits_col:   ; 64 columns to include 24 columns not yet visible on screen
            move.w  (a3)+,d0
            lsl.w   #5,d0      ; tm index shifted to address 64 KB space
            lea     scratch_memory,a1       ; point at start of scratch memory again
            adda.w  d0,a1
            BLIT_TILE_L1 a1,d2,d3,a0        ; a1 auto-advances past this tile
            addq.w  #(TILE_W),d2
            dbf     d7,.blit_intro_credits_col
        adda.l      #(320-64*2),a3 ; skip horizontal tiles that will be displayed later when scrollng starts
        addq.w  #(TILE_H),d3
        dbf         d6,.blit_intro_credits_row

    ; update sprite palette
    lea     (sega_logo_sprite_palette),a0
    lea     (sp_pal0),a1
    lea     (SPAL_BASE),a2
    moveq   #(16-1),d7             ; 16 colours
.copy_spal0:
    move.w  (a0)+,d0    ; colour index
    move.w  d0,(a1)+    ; copy to RAM palette
    move    (X68ColourLUT,d0.w),(a2)+
    dbf     d7,.copy_spal0
    ; copy sprite tileset
    lea     (sega_logo_sprite_tiles),a0
    lea     (PCG_BASE),a1         ;
    move.w  #(12*64-1),d7                 ; 12 sprites x 64 words
.copy_sprites:
    move.w  (a0)+,(a1)+
    dbf     d7,.copy_sprites
    ; update sprite table
    lea     (sega_logo_sprite_table),a0
    lea     (SPRITE_TABLE),a1         ;
    moveq   #(12*4-1),d7              ; 12 sprites in table
.copy_sega_logo_sprite_table:
    move.w  (a0)+,(a1)+
    dbf     d7,.copy_sega_logo_sprite_table

    ; enable sptites
    ; disable bg1 - clear sega logo from gvram
    CLEAR_GVRAM_L0 0
    moveq       #$6,d7  ; max possible value
    .intro_fadein:
        moveq       #$0,d6
        .L0:
            WAIT_VBLANK
            WAIT_VBLANK
            bsr.w   scroll_left_bg2
            dbf         d6,.L0
        lea     (target_title_screen_palette),a3
        lea     (bg_pal0),a2    ; will be set to zero to be gin with
        bsr     increment_palette_if_palette_target_gt_d7
        WAIT_VBLANK
        WAIT_VBLANK
        bsr.w   scroll_left_bg2
        lea     (sega_logo_colours_x68k),a0
        lea     (GPAL_BASE),a1
        moveq   #(16-1),d5             ; 16 colours
        .copy_bg2_colour_loop:
            move.w  (a0)+,(a1)+
            move    (X68ColourLUT,d0.w),(a2)+

            dbf     d5,.copy_bg2_colour_loop
        dbf         d7,.intro_fadein
    moveq       #$6,d7
    .sp_fadeout:
        moveq       #$0,d6
        .L2:
            WAIT_VBLANK
            WAIT_VBLANK
            bsr.w   scroll_left_bg2
            dbf         d6,.L2
        lea         (sp_pal0),a2
        bsr.w       decrement_palette
        CONVERT_MD_TO_X68K_COLOURS sp_pal0,sega_logo_colours_x68k,16
        WAIT_VBLANK
        WAIT_VBLANK
        bsr.w   scroll_left_bg2
        lea     (sega_logo_colours_x68k),a0
        lea     (SPAL_BASE),a1
        moveq   #(16-1),d5             ; 16 colours
        .copy_sp0_colour_loop:
            move.w  (a0)+,(a1)+
            dbf     d5,.copy_sp0_colour_loop
        dbf         d7,.sp_fadeout
    moveq       #$46,d6
    .keep_scrolling_for_142_frames:
        WAIT_VBLANK
        WAIT_VBLANK
        bsr.w   scroll_left_bg2
        dbf         d6,.keep_scrolling_for_142_frames
    ; TODO add sound variation if start has been pressed during 142 frames
    clr.b       (alt_intro_credits_sound_flag)
    tst.b       (jp2_en_flag)
    bne.b       .L4
    move.b      #$1,(alt_intro_credits_sound_flag)
.L4:
    lea         (S_PRODUCED_BY),a3      ; string
    lea         (TM_GAME_ART),a4        ; graphics sprites data
    move.w      #(S_PRODUCED_VPOS),d1
    move.w      #(S_PRODUCED_HPOS),d6
    move.b      #PAD_A,(intro_credits_pad_key)     ; pad code during intro?
    bsr.w       process_intro_credits_text_and_graphics
    lea         (S_ASSOCIATED_WITH),a3  ; string
    lea         (TM_GAINAX),a4          ; graphics sprites data
    move.w      #(S_ASSOCIATED_WITH_VPOS),d1
    move.w      #(S_ASSOCIATED_WITH_HPOS),d6
    move.b      #PAD_B,(intro_credits_pad_key)
    bsr.w       process_intro_credits_text_and_graphics
    lea         (S_MUSIC_COMPOSED_BY),a3; string
    lea         (TM_MECANO),a4          ; graphics sprites data
    move.w      #(S_MUSIC_COMPOSED_BY_VPOS),d1
    move.w      #(S_MUSIC_COMPOSED_BY_HPOS),d6
    move.b      #PAD_C,(intro_credits_pad_key)
    bsr.w       process_intro_credits_text_and_graphics
    .dec_intro_counter:
        WAIT_VBLANK
        WAIT_VBLANK
        bsr.w   scroll_left_bg2
        move.w      (intro_credits_ctr),d0    ; check counter
        cmpi.w      #$fce8,d0 ; 792 vblanks or 12 seconds?
        beq.b       .intro_counter_match
        bra.b       .dec_intro_counter
.intro_counter_match:
    lea         (options_tileset_0001),a0
    moveq       #$0,d1
    move.l      #(DAT_00ff1a48),d2   ; to RAM (length?)
    bsr.w       write_tileset
    lea         (options_tileset_0003),a0
    moveq       #$0,d1
    move.l      #(DAT_00ff3a48),d2   ; to RAM
    bsr.w       write_tileset
    lea         (VDP_CTRL),a0
    moveq       #$0,d7
    .L0001014e:
        moveq       #$3,d6
        .L00010150:
            movem.l     d7-d6,-(SP)
            WAIT_VBLANK
            bsr.w       update_cram_with_palettes_0123
            WAIT_VBLANK
            movem.l     (SP)+,d6-d7
            bsr.w       update_cram_col1_8_with_d7
            dbf         d6,.L00010150
        lea         (L0001163c),a3
        lea         (palettes_0),a2
        bsr.w       increment_half_palette_if_palette_target_gt_d7    ; only called once
        bsr.w       update_cram_with_palettes_0123
        addq.w      #$1,d7
        cmpi.w      #$7,d7
        bcs.b       .L0001014e
    WAIT_VBLANK
    moveq       #$8,d6
    moveq       #$7,d7
    .L00010190:
        WAIT_VBLANK
        bsr.w       update_cram_col1_8_with_d7
        WAIT_VBLANK
        bsr.w       update_cram_with_palettes_0123
        WAIT_VBLANK
        bsr.w       update_cram_blue_col1_8_with_d7
        WAIT_VBLANK
        bsr.w       update_cram_with_palettes_0123
        dbf         d6,.L00010190
    moveq       #$6,d7
    .L000101b6:
        moveq       #$0,d6
        .L000101b8:
            WAIT_VBLANK
            bsr.w       update_cram_blue_col1_8_with_d7
            WAIT_VBLANK
            bsr.w       update_cram_with_palettes_0123
            WAIT_VBLANK
            bsr.w       update_cram_blue_col1_8_with_d7
            WAIT_VBLANK
            bsr.w       update_cram_with_palettes_0123
            WAIT_VBLANK
            bsr.w       update_cram_blue_col1_8_with_d7
            dbf         d6,.L000101b8
        lea         (palettes_0),a2
        bsr.w       drecrement_half_palette
        WAIT_VBLANK
        bsr.w       update_cram_with_palettes_0123
        WAIT_VBLANK
        bsr.w       update_cram_blue_col1_8_with_d7
        dbf         d7,.L000101b6
    lea         (DAT_00ff655c),a3
    moveq       #$4,d0
    .L0001020a:
        WAIT_VBLANK
        moveq       #$1d,d1
        .L00010210:
            move.l      #$0,(a3)+
            move.l      #$0,(a3)+
            move.l      #$0,(a3)+
            move.l      #$0,(a3)+
            dbf         d1,.L00010210
        dbf         d0,.L0001020a
    bsr.w       L00010b32
    bsr.w       L0001074e
    bsr.w       L00010862
    bsr.w       L0001065c
    clr.w       (intro_credits_ctr)
    move.w      #$00a0,d7     ; psb_phase counter
    psb_phase:
        move.l      d7,-(SP)
        bsr.w       update_psb_msg
        jsr         jp_read
        btst.b      #$7,(jp1_result)    ; PAD_START
        bne.b       .psb_start_pressed           ; branch if start pressed
        move.l      (SP)+,d7
        dbf         d7,psb_phase
    bsr.w       write_z80_reg6_with_c8h
    moveq       #$7,d7
    .dec_palettes:
        lea         (palettes_3),a2
        bsr.w       decrement_palette
        lea         (palettes_2),a2
        bsr.w       decrement_palette
        lea         (palettes_1),a2
        bsr.w       decrement_palette
        lea         (palettes_0),a2
        bsr.w       decrement_palette
        WAIT_VBLANK
        WAIT_VBLANK
        bsr.w       update_cram_with_palettes_0123
        dbf         d7,.dec_palettes
    jsr         disable_display
    moveq       #$0,d0
    rts
    .psb_start_pressed:
        VDP_WVRAM_CMD $ec90
        moveq       #$18,d0
        .clear_bg1_line1_char:
            move.w      #$0,(a1)
            dbf         d0,.clear_bg1_line1_char
        VDP_WVRAM_CMD $ed10
        moveq       #$18,d0
        .clear_bg1_line2_char:
            move.w      #$0,(a1)
            dbf         d0,.clear_bg1_line2_char
        moveq       #$0,d7  ; row counter reset
        .set_bg2_tilemap_row:
            bsr.w       wait_for_vblank_plus_small_delay
            move.l      #VDP_VSRAM_WADDR,(VDP_CTRL)
            move.w      d7,(VDP_DATA)   ; reset v scrolling
            move.w      d7,(VDP_DATA)   ; reset v scrolling
            VDP_WVRAM_CMD $f000
            moveq       #$4f,d6
            lea         (sprite_table_data),a2  ; might be scratch memory not only for sprites
            .transfer_sprite_table_item:
                subq.w      #$1,(a2)        ; vpos_1 is temp sprite table?
                move.w      (a2)+,(VDP_DATA)
                move.w      (a2)+,(VDP_DATA)
                move.w      (a2)+,(VDP_DATA)
                move.w      (a2)+,(VDP_DATA)
                dbf         d6,.transfer_sprite_table_item
            addq.w      #$1,d7  ; row counter++
            cmpi.w      #$18,d7 ; 24 rows
            bcs.b       .set_bg2_tilemap_row
        VDP_WVRAM_CMD PRESS_START_BUTTON_POS
        moveq       #$1e,d7     ; message length-1
        .erase_psb_msg:
            move.w      #$0,(VDP_DATA)
            dbf         d7,.erase_psb_msg
        bra.w       start_options_screen

; a3=string src, a4=graphics sprite data, d1=text vpos, d6= text hpos
process_intro_credits_text_and_graphics:  ; (00010f18)
    bsr.w       display_intro_text_and_graphics_sprites
    moveq       #$6,d7  ; max possible value
    .L00010f1e:
        lea         (grey_text_palette),a3          ; clear text tilemap?
        lea         (palettes_3),a2
        bsr.w       increment_palette_if_palette_target_gt_d7
        WAIT_VBLANK
        WAIT_VBLANK
        bsr.w       update_cram_with_palettes_0123
        bsr.w       intro_credit_scrolling
        moveq       #$0,d6
        .L00010f40:
            WAIT_VBLANK
            WAIT_VBLANK
            bsr.w       intro_credit_scrolling
            dbf         d6,.L00010f40
        dbf         d7,.L00010f1e
    bsr.b       check_alt_intro_credits_sound_pad_key
    moveq       #$6,d7
    .L00010f58:
        moveq       #$0,d6
        .L00010f5a:
            WAIT_VBLANK
            WAIT_VBLANK
            bsr.w       intro_credit_scrolling
            dbf         d6,.L00010f5a
        lea         (palettes_3),a2
        bsr.w       decrement_palette
        WAIT_VBLANK
        WAIT_VBLANK
        bsr.w       update_cram_with_palettes_0123
        bsr.w       intro_credit_scrolling
        dbf         d7,.L00010f58
    VDP_WVRAM_CMD $f000
    move.l      #$0,(a1)    ; sprite 0?
    bra.w       play_intro_credits_for_142_frames   ; why as this is just below?



sega_logo_sprite_tiles:  ; $0001171c - $600 bytes of sprite tiles
    incbin "inc/gfx/intro_credits/sega_logo_sprite_tiles.bin"

sega_logo_sprite_palette:
    MDCOLOR 0,0,0
    MDCOLOR 7,7,7
    MDCOLOR 7,6,0
    MDCOLOR 7,5,0
    MDCOLOR 7,4,0
    MDCOLOR 7,3,0
    MDCOLOR 7,2,0
    MDCOLOR 7,1,0
    MDCOLOR 7,0,0
    MDCOLOR 6,0,0
    MDCOLOR 5,0,0
    MDCOLOR 4,0,0
    MDCOLOR 3,0,0
    MDCOLOR 0,0,0
    MDCOLOR 0,0,0
    MDCOLOR 0,0,0

sega_logo_sprite_table:  ; 12 sprites (X68000 ------XXXXXXXXXX,------YYYYYYYYYY,VH--CCCCSSSSSSSS,--------------PP
    dw $00f8, $0057, $0000, $0003   ; s1 t0 p3
    dw $0108, $0057, $0001, $0003   ; s1 t1 p3
    dw $0118, $0057, $0002, $0003   ; s1 t2 p3
    dw $0128, $0057, $0003, $0003   ; s1 t3 p3
    dw $0138, $0057, $0004, $0003   ; s2 t4 p3
    dw $0148, $0057, $0005, $0003   ; s2 t1 p3
    dw $00f8, $0067, $0006, $0003   ; s2 t2 p3
    dw $0108, $0067, $0007, $0003   ; s2 t3 p3
    dw $0118, $0067, $0008, $0003   ; s3 t4 p3
    dw $0128, $0067, $0009, $0003   ; s3 t1 p3
    dw $0138, $0067, $000a, $0003   ; s3 t2 p3
    dw $0148, $0067, $000b, $0003   ; s3 t3 p3

intro_credits_ts_p1:
    incbin  "inc/gfx/intro_credits/block39.bin"
intro_credits_ts_p2:
    incbin  "inc/gfx/intro_credits/block40.bin"
intro_credits_bg2_tm:
    incbin  "inc/gfx/intro_credits/bg2_tm.bin"

target_title_screen_palette:
    MDCOLOR 0,0,0
    MDCOLOR 2,3,3
    MDCOLOR 3,4,4
    MDCOLOR 0,0,0
    MDCOLOR 0,0,0
    MDCOLOR 0,0,0
    MDCOLOR 0,0,0
    MDCOLOR 0,0,0
    MDCOLOR 0,1,0
    MDCOLOR 0,0,0
    MDCOLOR 0,0,0
    MDCOLOR 0,1,1
    MDCOLOR 1,2,2
    MDCOLOR 2,3,3
    MDCOLOR 3,4,4
    MDCOLOR 4,5,5

intro_credits_ts_p3:    ; tiles for sprites
    incbin  "inc/gfx/intro_credits/block41.bin"
    
; TODO convert tilemaps to X68000 sprite format        
TM_GAME_ART:  ; GAME ART sprites data during produced by -
   dw $0005 ; n+1 sprites
   dw $00F8, $0E00, $6620, $00BD
   dw $00F8, $0E00, $662C, $00DD
   dw $00F8, $0E00, $6638, $00FD
   dw $00F8, $0E00, $6644, $0123
   dw $00F8, $0E00, $6650, $0143
   dw $00F8, $0E00, $665C, $0163

TM_GAINAX:  ; GAINAX sprites data during associated with
   dw $0003 ; n+1 sprites
   dw $00F2, $0F00, $6668, $00EC, $00F2, $0F00, $6678, $010C
   dw $00F2, $0F00, $6688, $012C, $00F2, $0300, $6698, $014C

TM_MECANO:  ; MECANO ASSOCIATES sprites data during music composed by
   dw $0004 ; n+1 sprites
   dw $00F8, $0d00, $669C, $00CE, $00F8, $0d00, $66A4, $00EE
   dw $00F8, $0d00, $66AC, $0112, $00F8, $0d00, $66B4, $0132
   dw $00F8, $0d00, $66BC, $0152, $0000, $0000, $0000, $0000
        
S_PRODUCED_BY:
    db "PRODUCED BY", $00
S_ASSOCIATED_WITH:
    db "ASSOCIATED WITH", $00
S_MUSIC_COMPOSED_BY:
    db "MUSIC COMPOSED BY", $00
        
S_PRODUCED_VPOS equ $00d8
S_PRODUCED_HPOS equ $00ee
S_ASSOCIATED_WITH_VPOS equ $00d8
S_ASSOCIATED_WITH_HPOS equ $00e4
S_MUSIC_COMPOSED_BY_VPOS equ $00d8
S_MUSIC_COMPOSED_BY_HPOS equ $00d8

options_tileset:
    incbin  "inc/gfx/intro_credits/options_tileset.bin"
options_tileset_0001:
    incbin  "inc/gfx/intro_credits/options_tileset_0001.bin"
options_tileset_0002:
    incbin  "inc/gfx/intro_credits/options_tileset_0002.bin"
options_tileset_0003:
    incbin  "inc/gfx/intro_credits/options_tileset_0003.bin"

; PAD cosntants TODO
PAD_A: equ $00
PAD_B: equ $00
PAD_C: equ $00


    bss
alt_intro_credits_sound_flag: ds.b 1
jp2_en_flag: ds.b 1
intro_credits_pad_key: ds.b 1
    even
intro_credits_ctr: ds.w 1
