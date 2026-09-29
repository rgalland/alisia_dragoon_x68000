; =============================================================================
; tile_decompress_x68k.s — Standalone bitplane-RLE tile decompressor
;
; Extracted from write_tileset (alisia_dis.asm ~L16962-17222) and its
; sub-routines .decompress_planar_data_streams / .decompress_plane /
; .planar_to_packed_conv.
;
; IMPORTANT CONTEXT: the Mega Drive's main CPU is a 68000, same as the
; X68000 -- this is NOT an instruction-set port like the Z80 sound driver
; was. The algorithm below is untouched 68000 logic. The only things
; removed are VDP-specific: the original write_tileset supported two output
; modes selected by a runtime flag (d1 param) --
;   flag=1 (what the MD actually used): set up a VDP VRAM write address,
;           then stream each decoded word straight to VDP_DATA
;   flag=0 (only path we need): write decoded words to a RAM pointer
; This file keeps ONLY the flag=0 / RAM-output path, and drops the
; VDP_CTRL address-setup preamble entirely, since VRAM isn't touched here
; at all -- this routine's whole job is decompress-to-RAM. The separate
; RAM-to-GVRAM blit (via the tilemap) is a distinct later step.
;
; DISABLE_INTERRUPTS/ENABLE_INTERRUPTS from the original are also dropped:
; on the MD they guarded against an interrupt handler touching VDP_CTRL
; mid-stream and corrupting the VRAM auto-increment address. Since this
; routine never touches hardware -- it only writes to a linear RAM buffer
; -- there's no equivalent hazard here.
;
; =============================================================================
; Compressed data format (verified against write_tileset, not guessed):
;
;   header+$00..$01  tile count (big-endian word)
;   header+$02..$09  8-byte "dictionary" -- used by the $00-$1F opcode class
;   header+$0A..$0B  offset from header to plane 1's stream (big-endian word)
;   header+$0C..$0D  offset from header to plane 2's stream
;   header+$0E..$0F  offset from header to plane 3's stream
;   header+$10       plane 0's stream starts here
;
; Each of the 4 streams is independently RLE-compressed (bitplane
; separation: pixel N's 4-bit palette index is split one bit per plane,
; each plane RLE'd separately since bitplanes have much longer runs than
; interleaved 4bpp pixel data).
;
; Per-plane RLE opcode table (dispatched on the top bits of each control
; byte read from the stream):
;
;   $00-$1F  write dictionary[(byte>>2)&7] TWICE, then copy (byte&3)
;            (0-3) literal bytes
;   $20-$2F  write ((byte>>2)&3)+2 (2-5) copies of $00, then copy (byte&3)
;            (0-3) literal bytes
;   $30-$3F  same as $20-$2F but with $FF instead of $00
;   $40-$5F  write (byte&$1F)+6 (6-37) copies of $00, no literal tail
;   $60-$7F  same as $40-$5F but with $FF
;   $80-$BF  read one byte V from the stream; write ((byte>>2)&$F)+2
;            (2-17) copies of V, then copy (byte&3) (0-3) literal bytes
;   $C0-$FF  copy (byte&$3F)+1 (1-64) literal bytes verbatim, no run
;
; NOTE on the ranges above: the four run-count opcodes ($20-$7F, $80-$BF)
; feed their computed count into a dbf loop, which executes (count+1)
; times on a 68000 -- three of these four opcode classes don't pre-
; compensate for that extra iteration the way the tail-copy loops and
; the $C0-$FF literal opcode do (both have an explicit subq.w #1 right
; before their own dbf). The ranges listed here already account for
; that; the inline code comments near each opcode below note the raw
; field value separately from the true executed range, since they
; differ by one. This was wrong in an earlier revision (both here and
; in the inline comments) until cross-checked against real compressed
; game data (block39.bin) failing to decode -- a synthetic round-trip
; self-test alone couldn't catch it, since a matching encoder/decoder
; pair sharing the same wrong assumption still agree with each other.
;
; Reassembly: once a batch of up to 256 bytes/plane is decoded into the 4
; scratch buffers below, each SET of 1 byte from every one of the 4 planes
; (8 bits = 8 pixels' worth of that bit position) is bit-interleaved back
; into 8 pixels of standard packed 4bpp tile data (4 output bytes) -- one
; bit shifted out of each plane register per pixel nibble, 4 shifts per
; pixel, rotated into an accumulator.
;
; Output size check (confirms the header's tile-count field is read
; correctly): total_bytes_per_plane = tile_count * 8, matching exactly
; 8 rows/tile x 1 byte/row/plane (8 pixels/row = 8 bits = 1 byte per
; bitplane per tile row).
; =============================================================================

    text
    even

; =============================================================================
; decompress_tileset
; Decode one full compressed tileset block into packed 4bpp tile data.
;
; In:  a0 = pointer to compressed data (header, as described above)
;      a1 = pointer to destination RAM buffer for decoded packed 4bpp
;           tile data (caller must size this: tile_count * 32 bytes,
;           since each 8x8 4bpp tile is 32 bytes packed)
; Out: a1 = advanced past the last byte written (== start + total size)
; Clobbers: d0-d7, a0-a6
; =============================================================================
decompress_tileset:
    movem.l a6-a0/d7-d0,-(sp)

    ; --- Read tile count, compute total bytes-per-plane to decode ---
    move.b  (a0),d1                ; header+$00 = count MSB
    lsl.w   #8,d1
    move.b  (1,a0),d1               ; header+$01 = count LSB
    mulu.w  #8,d1                   ; d1 = tile_count * 8 (bytes/plane total)

    ; --- Resolve the 4 plane stream start pointers ---
    movea.l a0,a3
    movea.l a0,a4
    movea.l a0,a5
    movea.l a0,a6
    clr.l   d7
    adda.w  #$10,a3                 ; plane 0 stream starts right after header

    move.b  ($a,a0),d7               ; plane 1 offset MSB
    lsl.w   #8,d7
    move.b  ($b,a0),d7               ; plane 1 offset LSB
    adda.l  d7,a4

    move.b  ($c,a0),d7               ; plane 2 offset MSB
    lsl.w   #8,d7
    move.b  ($d,a0),d7               ; plane 2 offset LSB
    adda.l  d7,a5

    move.b  ($e,a0),d7               ; plane 3 offset MSB
    lsl.w   #8,d7
    move.b  ($f,a0),d7               ; plane 3 offset LSB
    adda.l  d7,a6

.decode_loop:
    bsr.b   decompress_planar_data_streams
    bsr.w   planar_to_packed_conv
    tst.w   d1
    bne.b   .decode_loop

    movem.l (sp)+,d0-d7/a0-a6
    rts


; =============================================================================
; decompress_planar_data_streams
; Decode up to 256 bytes from EACH of the 4 plane streams into the 4
; scratch buffers below. d1 = total bytes/plane still remaining overall
; (decremented here); d2 = bytes decoded THIS batch (fed to
; planar_to_packed_conv immediately after).
; a3-a6 = current read position in each of the 4 plane streams (advanced
; in place, ready for the next batch).
; =============================================================================
decompress_planar_data_streams:
    tst.w   d1
    beq.w   .leave
    move.l  a1,-(sp)
    move.w  #$100,d2
    cmp.w   d2,d1
    bcs.b   .less_than_100h
    sub.w   d2,d1                   ; more than 256 left -- take a full batch
    bra.b   .decompress_all_planes
.less_than_100h:
    move.w  d1,d2                   ; final partial batch
    clr.w   d1
.decompress_all_planes:
    movea.l a3,a1
    lea     (plane_buf0),a2
    bsr.b   decompress_plane
    movea.l a1,a3

    movea.l a4,a1
    lea     (plane_buf1),a2
    bsr.b   decompress_plane
    movea.l a1,a4

    movea.l a5,a1
    lea     (plane_buf2),a2
    bsr.b   decompress_plane
    movea.l a1,a5

    movea.l a6,a1
    lea     (plane_buf3),a2
    bsr.b   decompress_plane
    movea.l a1,a6

    movea.l (sp)+,a1
.leave:
    rts


; =============================================================================
; decompress_plane
; Decode one plane's RLE stream. a1 = stream read pointer (advanced),
; a2 = scratch output buffer (advanced), d2 = bytes to produce.
; a0 must still hold the compressed-block HEADER pointer (used for the
; $00-$1F opcode's dictionary lookup at header+2..+9) -- this is why
; decompress_tileset never repurposes a0 for anything else.
; Clobbers: d3-d6, a1, a2
; =============================================================================
decompress_plane:
    move.w  d2,d6                   ; d6 = remaining output bytes this batch
.next_op:
    tst.w   d6
    beq.w   .done
    move.b  (a1)+,d3                ; d3 = control byte
    move.b  d3,d4
    andi.b  #$f0,d4
    cmpi.b  #$30,d4
    beq.b   .op_30_ff_short
    cmpi.b  #$20,d4
    beq.b   .op_20_00_short
    andi.b  #$e0,d4
    cmpi.b  #$60,d4
    beq.b   .op_60_ff_long
    cmpi.b  #$40,d4
    beq.b   .op_40_00_long
    andi.b  #$c0,d4
    cmpi.b  #$c0,d4
    beq.w   .op_c0_literal
    cmpi.b  #$80,d4
    beq.b   .op_80_byte_run
    ; --- $00-$1F: dictionary byte x2, then (d3&3) literal bytes ---
    move.b  d3,d4
    andi.w  #$1c,d4
    lsr.w   #2,d4                    ; d4 = dictionary index 0-7
    move.b  ($2,a0,d4.w),d5           ; d5 = header+2+d4 (the dictionary byte)
    subq.w  #2,d6
    move.b  d5,(a2)+
    move.b  d5,(a2)+
    andi.w  #3,d3
    beq    .next_op
    sub.w   d3,d6
    subq.w  #1,d3
.op00_tail:
    move.b  (a1)+,(a2)+
    dbf     d3,.op00_tail
    bra     .next_op

.op_20_00_short:
    moveq   #0,d5
    bra.b   .op_20_30_common
.op_30_ff_short:
    moveq   #-1,d5
.op_20_30_common:
    move.b  d3,d4
    andi.w  #$c,d3
    lsr.w   #2,d3
    addq.w  #1,d3                    ; d3 = 1-4 here, but dbf below executes
                                     ; (d3+1) times -- true run length is 2-5.
                                     ; This matches real MD behaviour exactly
                                     ; (same dbf semantics on both CPUs); only
                                     ; get this wrong if you're computing the
                                     ; range from d3's value instead of from
                                     ; what the dbf loop actually executes.
    sub.w   d3,d6
    subq.w  #1,d6
.op2030_run:
    move.b  d5,(a2)+
    dbf     d3,.op2030_run
    andi.w  #3,d4                    ; literal tail count 0-3
    beq     .next_op
    sub.w   d4,d6
    subq.w  #1,d4
.op2030_tail:
    move.b  (a1)+,(a2)+
    dbf     d4,.op2030_tail
    bra     .next_op

.op_40_00_long:
    moveq   #0,d5
    bra.b   .op_40_60_common
.op_60_ff_long:
    moveq   #-1,d5
.op_40_60_common:
    andi.w  #$1f,d3
    addq.w  #5,d3                    ; d3 = 5-36 here, but dbf below executes
                                     ; (d3+1) times -- true run length is 6-37.
    sub.w   d3,d6
    subq.w  #1,d6
.op4060_run:
    move.b  d5,(a2)+
    dbf     d3,.op4060_run
    bra     .next_op

.op_80_byte_run:
    move.b  d3,d4
    andi.w  #$3c,d3
    lsr.w   #2,d3
    addq.w  #1,d3                    ; d3 = 1-16 here, but dbf below executes
                                     ; (d3+1) times -- true run length is 2-17.
    sub.w   d3,d6
    subq.w  #1,d6
    move.b  (a1)+,d5                 ; d5 = the byte value to repeat
.op80_run:
    move.b  d5,(a2)+
    dbf     d3,.op80_run
    andi.w  #3,d4                    ; literal tail count 0-3
    beq     .next_op
    sub.w   d4,d6
    subq.w  #1,d4
.op80_tail:
    move.b  (a1)+,(a2)+
    dbf     d4,.op80_tail
    bra     .next_op

.op_c0_literal:
    andi.w  #$3f,d3
    sub.w   d3,d6
    subq.w  #1,d6
.opc0_copy:
    move.b  (a1)+,(a2)+
    dbf     d3,.opc0_copy
    bra     .next_op

.done:
    rts


; =============================================================================
; planar_to_packed_conv
; Interleave one decoded batch (d2 bytes from EACH of the 4 plane scratch
; buffers) into packed 4bpp pixel data, written to (a1)+.
; Every 1 byte consumed from each of the 4 planes (8 bits = 8 pixels'
; worth of that bit position) produces 8 pixels of packed output (4
; bytes / 2 words), built 1 pixel nibble at a time: shift a bit out of
; each of the 4 plane registers, rotate it into the accumulator -- 4
; shifts per pixel nibble.
; =============================================================================
planar_to_packed_conv:
    tst.w   d2
    beq.w   .exit
    movem.l d2/d1,-(sp)
    lea     (plane_buf0),a2
    subi.w  #1,d2
.byte_loop:
    swap    d2
    move.b  (a2),d5                  ; plane 0 byte
    move.b  ($100,a2),d6              ; plane 1 byte
    move.b  ($200,a2),d4              ; plane 2 byte
    move.b  ($300,a2),d3              ; plane 3 byte
    addq.w  #1,a2
    move.w  #1,d2
.pixel_pair_loop:
BYTE_IDX SET 0
    REPT 2
        REPT 2
            ; Verified bit order (traced by hand through the 9-bit
            ; roxl.b rotate-through-extend ring across all 8 steps that
            ; build one output byte -- see the equivalent derivation in
            ; md_tile_codec.py's module docstring for the full working):
            ; each pixel's final nibble = (plane3_bit<<3)|(plane2_bit<<2)
            ; |(plane0_bit<<1)|(plane1_bit). Note plane0 and plane1 land
            ; in the middle bits, not bits 0/1 as you'd naively guess --
            ; an earlier revision of the comments below (but NOT the
            ; code, which was always correct) had d5/d6 swapped relative
            ; to their actual load source just above (plane_buf0/buf1).
            lsl.b   #1,d3             ; plane 3 bit -> carry
            roxl.b  #1,d1             ; ...into accumulator
            lsl.b   #1,d4             ; plane 2 bit
            roxl.b  #1,d1
            lsl.b   #1,d5             ; plane 0 bit (d5 loaded from plane_buf0)
            roxl.b  #1,d1
            lsl.b   #1,d6             ; plane 1 bit (d6 loaded from plane_buf1)
            roxl.b  #1,d1
        ENDR
        IF BYTE_IDX=1
            rol.w   #8,d7              ; previous packed byte -> high byte
        ENDIF
        move.b  d1,d7
BYTE_IDX SET BYTE_IDX+1
    ENDR
    move.w  d7,(a1)+                  ; write 1 word (2 packed bytes / 4 px)
    dbf     d2,.pixel_pair_loop
    swap    d2
    dbf     d2,.byte_loop
    movem.l (sp)+,d1/d2
.exit:
    rts


; =============================================================================
; Scratch buffers -- one 256-byte window per bitplane, reused across
; batches. Not re-entrant; fine for load-time-only use.
; =============================================================================
    bss
    even
plane_buf0:     ds.b    256
plane_buf1:     ds.b    256
plane_buf2:     ds.b    256
plane_buf3:     ds.b    256
