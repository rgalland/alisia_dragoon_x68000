; =============================================================================
; soundtest.s — X68000 Sound Driver Test Shell
;
; Command-line test program for verifying sound_driver.s functionality.
; Loads music and SFX data from disk, initialises the sound driver,
; then provides an interactive shell for triggering playback.
;
; Build (vasm + vlink two-step):
;   vasmm68k_mot -m68000 -mot -Felf -o soundtest.o soundtest.s
;   vlink -bxfile -o soundtest.x soundtest.o
;
; Usage from Human68k prompt:
;   soundtest.x music.bin sfx.bin
;
; Commands (single key, no enter needed):
;   0-9    Play music track (bank 0/1, track 1-10)
;   A-Z    Play music track (track 11-36)
;   B      Toggle bank 0/1
;   S      Trigger SFX by hex index
;   I      Trigger instrument by hex index
;   F      Fade out current music
;   P      Pause / resume toggle
;   +/-    Volume up/down
;   D      Print debug info (IRQ count, OPM write count, pointers)
;   ?      Help
;   Q      Quit and restore system
;
; Human68k entry convention (confirmed):
;   a2 = pointer to command line string, possibly prefixed with $0B
;        (HUPAIR mark), followed by " arg1 arg2..." terminated by $0D
;   d0-d7, a0-a1, a3-a6 = undefined on entry
;   sp = valid stack provided by OS — do not set up your own
;   Do NOT use MOVE SR,<ea> or MOVE <ea>,SR — privileged, causes
;   privilege violation in user mode
;
; File format expected:
;   music.bin : two concatenated 32KB banks
;               each bank starts with a word table of track offsets
;               (little-endian), e.g. $18,$00,$76,$04 = track1@$0018,
;               track2@$0476 within the bank. Table ends at first
;               zero word or offset >= bank size.
;
;   sfx.bin   : raw SFX/instrument data, loaded to snd_sfx_buffer
;               (equivalent of Z80 $13A3 area)
; =============================================================================

    ; Entry point must be reachable as the very first executed instruction
    ; regardless of how vlink orders sections — jump straight to main.
    jmp     main

    include "x68k_hw.i"
    include "x68k_macros.i"
    include "inc/doscall.i"


; =============================================================================
; Memory layout
; =============================================================================

MUSIC_BANK_SIZE     equ 32768       ; 32KB per bank
MUSIC_FILE_SIZE     equ MUSIC_BANK_SIZE*2   ; 64KB total
SFX_BUFFER_SIZE     equ $0C5D       ; SFX area size (Z80 $13A3-$1FFF equiv)

OPEN_READ           equ 0


; =============================================================================
; Code
; =============================================================================
    text
    even
; =============================================================================
; main
; Human68k entry: a2 = command line string (see header notes)
; =============================================================================

main:
    ; Human68k confirmed entry convention:
    ;   a2 = command line string
    ;   sp = valid stack provided by OS
    ;   All other registers undefined
    ; DO NOT read/write SR (privileged)
    ; DO NOT write vector table directly (low memory write protected)
    ; Use DOS _INTVCS for interrupt vector install/restore (done in snd_init)

    ; --- Parse command line from a2 ---
    ; Skip HUPAIR mark ($0B) if present
    move.b  (a2)+,d5
    bne.b   .check_args
.no_args:
    pea     .no_args_str
    DOS     _PRINT
    addq.l  #4,sp
    DOS     _EXIT0
.no_args_str:
    dc.b    "No arguments. Usage: soundtest.x music.bin sfx.bin",$0D,$0A,0
    even
.check_args:
    bsr     skip_spaces_a2

    ; Check for empty command line
    tst.b   (a2)
    beq     print_usage_and_exit
    cmp.b   #$0D,(a2)
    beq     print_usage_and_exit
    cmp.b   #$0A,(a2)
    beq     print_usage_and_exit

    ; Parse music filename
    lea     (arg_music_buf),a0
    move.l  a0,(arg_music_path)
    bsr     copy_arg

    bsr     skip_spaces_a2

    tst.b   (a2)
    beq     print_usage_and_exit
    cmp.b   #$0D,(a2)
    beq     print_usage_and_exit
    cmp.b   #$0A,(a2)
    beq     print_usage_and_exit

    ; Parse sfx filename
    lea     (arg_sfx_buf),a0
    move.l  a0,(arg_sfx_path)
    bsr     copy_arg

    ; --- Print banner ---
    pea     str_banner
    DOS     _PRINT
    addq.l  #4,sp

    ; --- Debug: show where code/data landed in RAM ---
    pea     str_load_addr
    DOS     _PRINT
    addq.l  #4,sp
    lea     main,a0
    move.l  a0,d0
    bsr     print_hex_long
    bsr     print_new_line

    pea     str_ram_addr
    DOS     _PRINT
    addq.l  #4,sp
    lea     snd_bank,a0
    move.l  a0,d0
    bsr     print_hex_long
    bsr     print_new_line

    ; --- Load music file ---
    bsr     load_music_file
    tst.l   d0
    bne     exit_error

    ; --- Load SFX file ---
    bsr     load_sfx_file
    tst.l   d0
    bne     exit_error

    ; --- Debug: dump first 8 bytes of music data ---
    lea     str_music_hdr,a0
    bsr     print_string
    lea     (music_data),a0     ; $04638e for debugging
    bsr     print_hex_bytes_8
    bsr     print_new_line


    ; --- Discover track counts ---
    bsr     discover_tracks
    bsr     print_track_info

    ; --- Build driver asset pointers ---
    bsr     setup_driver_assets

    ; --- Debug: dump first 4 track pointers ---
    lea     str_track_ptrs,a0
    bsr     print_string
    lea     (snd_track_table),a0
    moveq   #3,d7
.ptr_loop:
    move.l  (a0)+,d0
    bsr     print_hex_long
    move.w  #' ',d0
    DOS_PUTCHAR_W
    dbf     d7,.ptr_loop
    bsr     print_new_line


    ; --- Initialise sound driver ---
    clr.l   (irq_counter)
    clr.l   (opm_write_count)
    jsr     snd_init

    ; --- Debug: verify _INTVCS assembled to correct address $FF25 ---
    pea     str_intvcs_check
    DOS     _PRINT
    addq.l  #4,sp
    move.l  #__DOS__INTVCS,d0  ; should print 0000FF25
    bsr     print_hex_long
    bsr     print_new_line

    ; --- Debug: verify OPM writes happened during init ---
    pea     str_opm_init_count
    DOS     _PRINT
    addq.l  #4,sp
    move.l  (opm_write_count),d0
    bsr     print_hex_long
    bsr     print_new_line

    ; --- Print help ---
    lea     str_help,a0
    bsr     print_string

    ; --- Initialise shell state ---
    clr.b   (shell_paused)
    move.b  #$40,(shell_volume)
    clr.b   (shell_bank)
    clr.b   (shell_track)
    move.b  #1,(shell_running)

    ; --- Main command loop ---
    bsr     command_loop

    ; --- Clean exit ---
    bsr     cleanup
    bra     exit_ok


; =============================================================================
; skip_spaces_a2 / copy_arg
; Command line parsing helpers operating on a2
; =============================================================================

skip_spaces_a2:
    cmp.b   #' ',(a2)
    bne.b   .done
    addq.l  #1,a2
    bra.b   skip_spaces_a2
.done:
    rts

; copy_arg: copy from a2 to a0 until space/null/CR/LF, null-terminate
copy_arg:
.loop:
    move.b  (a2)+,d0
    beq.b   .end
    cmp.b   #' ',d0
    beq.b   .backup_end
    cmp.b   #$0D,d0
    beq.b   .backup_end
    cmp.b   #$0A,d0
    beq.b   .backup_end
    move.b  d0,(a0)+
    bra.b   .loop
.backup_end:
    subq.l  #1,a2                ; leave terminator for caller to inspect
.end:
    clr.b   (a0)
    rts


; =============================================================================
; load_music_file / load_sfx_file
; =============================================================================

load_music_file:
    lea     str_loading_music,a0
    bsr     print_string
    move.l  (arg_music_path),a0
    bsr     print_string
    bsr     print_new_line


    move.l  (arg_music_path),a0
    move.w  #OPEN_READ,d1
    DOS_OPEN_FILE
    tst.l   d0
    bmi.b   .open_error
    move.l  d0,(file_music)

    move.l  d0,d1
    lea     (music_data),a0
    move.l  #MUSIC_FILE_SIZE,d2
    DOS_READ_FILE
    tst.l   d0
    bmi.b   .read_error

    move.l  (file_music),d1
    DOS_CLOSE_FILE

    lea     str_ok,a0
    bsr     print_string
    moveq   #0,d0
    rts

.open_error:
    lea     str_err_open_music,a0
    bsr     print_string
    moveq   #-1,d0
    rts

.read_error:
    lea     str_err_read,a0
    bsr     print_string
    move.l  (file_music),d1
    DOS_CLOSE_FILE
    moveq   #-1,d0
    rts


load_sfx_file:
    lea     str_loading_sfx,a0
    bsr     print_string
    move.l  (arg_sfx_path),a0
    bsr     print_string
    bsr     print_new_line


    move.l  (arg_sfx_path),a0
    move.w  #OPEN_READ,d1
    DOS_OPEN_FILE
    tst.l   d0
    bmi.b   .open_error
    move.l  d0,(file_sfx)

    move.l  d0,d1
    lea     (sfx_data),a0
    move.l  #SFX_BUFFER_SIZE,d2
    DOS_READ_FILE
    ; short read is fine for SFX

    move.l  (file_sfx),d1
    DOS_CLOSE_FILE

    lea     str_ok,a0
    bsr     print_string
    moveq   #0,d0
    rts

.open_error:
    lea     str_err_open_sfx,a0
    bsr     print_string
    moveq   #-1,d0
    rts


; =============================================================================
; discover_tracks
; Scan word offset tables at start of each bank
; =============================================================================

discover_tracks:
    lea     (music_data),a0
    bsr     .count_tracks
    move.w  d0,(bank0_track_count)

    lea     (music_data+MUSIC_BANK_SIZE),a0
    bsr     .count_tracks
    move.w  d0,(bank1_track_count)
    rts

.count_tracks:
    moveq   #0,d0
    clr.w   d3
.scan:
    moveq   #0,d1
    move.b  (a0)+,d1
    moveq   #0,d2
    move.b  (a0)+,d2
    lsl.w   #8,d2
    or.w    d2,d1
    tst.w   d1
    beq.b   .done
    cmp.w   d3,d1
    bcs.b   .done
    cmp.w   #MUSIC_BANK_SIZE,d1
    bcc.b   .done
    move.w  d1,d3
    addq.w  #1,d0
    cmp.w   #64,d0
    bcs.b   .scan
.done:
    rts


; =============================================================================
; setup_driver_assets
; Convert Z80 bank/offset format to absolute X68000 RAM pointers
; =============================================================================

setup_driver_assets:
    ; Bank 0 tracks → snd_track_table slots 0-15
    lea     (snd_track_table),a2
    move.w  (bank0_track_count),d7
    beq.b   .bank0_done
    subq.w  #1,d7
    lea     (music_data),a0
.bank0_loop:
    move.w  (a0)+,d0
    move.w  d0,d1
    lsl.w   #8,d1
    lsr.w   #8,d0
    or.w    d1,d0
    lea     (music_data),a1
    adda.w  d0,a1
    move.l  a1,(a2)+
    dbf     d7,.bank0_loop
.bank0_done:

    ; Bank 1 tracks → snd_track_table slots 16-31
    lea     (snd_track_table+16*4),a2
    lea     (music_data+MUSIC_BANK_SIZE),a1
    move.w  (bank1_track_count),d7
    beq.b   .bank1_done
    subq.w  #1,d7
    lea     (music_data+MUSIC_BANK_SIZE),a0
.bank1_loop:
    move.b  (a0)+,d0
    move.b  (a0)+,d1
    lsl.w   #8,d1
    or.w    d1,d0
    move.l  a1,d1
    and.l   #$FFFF,d0
    add.l   d0,d1
    move.l  d1,(a2)+
    dbf     d7,.bank1_loop
.bank1_done:

    ; SFX / instrument data pointer
    lea     (sfx_data),a0
    move.l  a0,(snd_inst_table)
    rts


; =============================================================================
; print_track_info
; =============================================================================

print_track_info:
    lea     str_tracks_found,a0
    bsr     print_string
    move.w  (bank0_track_count),d0
    bsr     print_decimal
    lea     str_tracks_bank0,a0
    bsr     print_string
    move.w  (bank1_track_count),d0
    bsr     print_decimal
    lea     str_tracks_bank1,a0
    bsr     print_string
    rts


; =============================================================================
; command_loop
; =============================================================================

command_loop:
.loop:
    lea     str_prompt,a0
    bsr     print_string

    DOS_GETCHAR_D0
    move.b  d0,d2

    ; Uppercase
    cmp.b   #'a',d2
    bcs.b   .no_lower
    cmp.b   #'z'+1,d2
    bcc.b   .no_lower
    sub.b   #32,d2
.no_lower:

    ; Echo
    move.b  d2,d0
    DOS_PUTCHAR_W
    bsr     print_new_line


    cmp.b   #'Q',d2
    beq.w   .quit
    cmp.b   #'P',d2
    beq.b   .pause
    cmp.b   #'F',d2
    beq.b   .fade
    cmp.b   #'+',d2
    beq.b   .vol_up
    cmp.b   #'-',d2
    beq.b   .vol_down
    cmp.b   #'S',d2
    beq.b   .sfx
    cmp.b   #'I',d2
    beq.b   .instrument
    cmp.b   #'B',d2
    beq.b   .bank_toggle
    cmp.b   #'D',d2
    beq.b   .debug
    cmp.b   #'?',d2
    beq.b   .help

    cmp.b   #'0',d2
    bcs.b   .check_alpha
    cmp.b   #'9'+1,d2
    bcc.b   .check_alpha
    sub.b   #'0'-1,d2            ; '0'->1 .. '9'->10
    bsr     cmd_play_track
    bra.b   .loop

.check_alpha:
    cmp.b   #'A',d2
    bcs.b   .unknown
    cmp.b   #'Z'+1,d2
    bcc.b   .unknown
    sub.b   #'A'-11,d2           ; 'A'->11 .. 'Z'->36
    bsr     cmd_play_track
    bra.w   .loop

.pause:
    bsr     cmd_pause
    bra.w   .loop
.fade:
    bsr     cmd_fade
    bra.w   .loop
.vol_up:
    bsr     cmd_vol_up
    bra.w   .loop
.vol_down:
    bsr     cmd_vol_down
    bra.w   .loop
.sfx:
    bsr     cmd_sfx
    bra.w   .loop
.instrument:
    bsr     cmd_instrument
    bra.w   .loop
.bank_toggle:
    bsr     cmd_bank_toggle
    bra.w   .loop
.debug:
    bsr     cmd_debug
    bra.w   .loop
.help:
    lea     str_help,a0
    bsr     print_string
    bra.w   .loop
.unknown:
    lea     str_unknown_cmd,a0
    bsr     print_string
    bra.w   .loop
.quit:
    rts


; =============================================================================
; cmd_debug
; Print IRQ counter, OPM write counter, sound driver status
; =============================================================================

cmd_debug:
    lea     str_dbg_irq,a0
    bsr     print_string
    move.l  (irq_counter),d0
    bsr     print_hex_long
    bsr     print_new_line


    lea     str_dbg_opm,a0
    bsr     print_string
    move.l  (opm_write_count),d0
    bsr     print_hex_long
    bsr     print_new_line


    lea     str_dbg_status,a0
    bsr     print_string
    moveq   #0,d0
    move.b  (snd_status),d0
    bsr     print_hex_long
    bsr     print_new_line


    lea     str_dbg_track,a0
    bsr     print_string
    move.l  (snd_track_ptr),d0
    bsr     print_hex_long
    bsr     print_new_line


    ; Dump channel 0 flags and config
    lea     str_dbg_ch0,a0
    bsr     print_string
    moveq   #0,d0
    move.b  (snd_music_ch+CH_CONFIG),d0
    bsr     print_hex_long
    move.w  #' ',d0
    DOS_PUTCHAR_W
    moveq   #0,d0
    move.b  (snd_music_ch+CH_FLAGS),d0
    bsr     print_hex_long
    move.w  #' ',d0
    DOS_PUTCHAR_W
    moveq   #0,d0
    move.b  (snd_music_ch+CH_DISABLE),d0
    bsr     print_hex_long
    bsr     print_new_line

    rts


; =============================================================================
; Command handlers
; =============================================================================

cmd_play_track:
    move.b  (shell_bank),d0
    move.b  d2,d1

    move.w  (bank0_track_count),d3
    tst.b   d0
    beq.b   .bank0_check
    move.w  (bank1_track_count),d3
.bank0_check:
    cmp.b   d3,d2
    bhi.b   .track_invalid

    lea     str_playing,a0
    bsr     print_string
    lea     str_bank,a0
    bsr     print_string
    moveq   #0,d0
    move.b  (shell_bank),d0
    bsr     print_decimal
    lea     str_track,a0
    bsr     print_string
    moveq   #0,d0
    move.b  d2,d0
    bsr     print_decimal
    bsr     print_new_line

    move.b  (shell_bank),d0
    move.b  d2,(shell_track)
    move.b  d2,d1
    clr.b   (shell_paused)
    jsr     snd_cmd_play_music
    rts

.track_invalid:
    lea     str_track_invalid,a0
    bsr     print_string
    rts


cmd_pause:
    tst.b   (shell_paused)
    bne.b   .resume
    move.b  #1,d0
    jsr     snd_cmd_pause
    move.b  #1,(shell_paused)
    lea     str_paused,a0
    bsr     print_string
    rts
.resume:
    clr.b   d0
    jsr     snd_cmd_pause
    clr.b   (shell_paused)
    lea     str_resumed,a0
    bsr     print_string
    rts


cmd_fade:
    lea     str_fading,a0
    bsr     print_string
    move.b  #$10,d0
    move.b  #$07,d1
    jsr     snd_cmd_stop_music
    rts


cmd_vol_up:
    move.b  (shell_volume),d0
    sub.b   #8,d0
    bpl.b   .ok
    clr.b   d0
.ok:
    move.b  d0,(shell_volume)
    move.b  d0,(snd_vol_accum)
    lea     str_vol,a0
    bsr     print_string
    moveq   #0,d0
    move.b  (shell_volume),d0
    bsr     print_decimal
    bsr     print_new_line

    rts


cmd_vol_down:
    move.b  (shell_volume),d0
    add.b   #8,d0
    cmp.b   #$7F,d0
    bls.b   .ok
    move.b  #$7F,d0
.ok:
    move.b  d0,(shell_volume)
    move.b  d0,(snd_vol_accum)
    lea     str_vol,a0
    bsr     print_string
    moveq   #0,d0
    move.b  (shell_volume),d0
    bsr     print_decimal
    bsr     print_new_line

    rts


cmd_sfx:
    lea     str_sfx_prompt,a0
    bsr     print_string
    bsr     read_hex_byte
    tst.b   d0
    beq.b   .cancel
    lea     str_triggering_sfx,a0
    bsr     print_string
    moveq   #0,d1
    move.b  d0,d1
    bsr     print_hex_long_from_d1
    bsr     print_new_line

    jsr     snd_cmd_play_instrument
.cancel:
    rts


cmd_instrument:
    lea     str_inst_prompt,a0
    bsr     print_string
    bsr     read_hex_byte
    tst.b   d0
    beq.b   .cancel
    lea     str_triggering_inst,a0
    bsr     print_string
    moveq   #0,d1
    move.b  d0,d1
    bsr     print_hex_long_from_d1
    bsr     print_new_line

    jsr     snd_cmd_play_instrument
.cancel:
    rts


cmd_bank_toggle:
    tst.b   (shell_bank)
    bne.b   .to_bank0
    move.b  #1,(shell_bank)
    lea     str_bank1,a0
    bsr     print_string
    rts
.to_bank0:
    clr.b   (shell_bank)
    lea     str_bank0,a0
    bsr     print_string
    rts


; =============================================================================
; cleanup
; Restore system state before exit
; NOTE: Does not touch SR (privileged). Sound driver's snd_init installed
; the timer B vector; we restore the original vector and stop the timer
; via OPM register writes only (no privileged instructions).
; =============================================================================

cleanup:
    ; Fade out and silence
    move.b  #$10,d0
    move.b  #$7F,d1
    jsr     snd_cmd_stop_music

    move.l  #100000,d0
.wait:
    subq.l  #1,d0
    bne.b   .wait

    jsr     snd_silence_all

    ; Restore original timer B handler via DOS _INTVCS (user-mode safe)
    ; saved_vblank_vec was set by snd_init from the _INTVCS return value
    move.l  (saved_vblank_vec),-(sp)   ; old handler address
    move.w  #VBLANK_VECTOR,-(sp)       ; vector number $4D
    DOS     _INTVCS                       ; DOS _INTVCS
    addq.l  #6,sp

    ; Stop OPM timer B (direct chip register write — always allowed)
    move.b  #OPM_TIMER_CTRL,d0
    move.b  #$00,d1
    jsr     write_opm

    lea     str_goodbye,a0
    bsr     print_string
    rts


; =============================================================================
; read_hex_byte
; =============================================================================

read_hex_byte:
    DOS_GETCHAR_D0
    move.b  d0,d2
    cmp.b   #$1B,d2
    beq.b   .cancel
    bsr     hex_char_to_nibble
    bmi.b   .cancel
    lsl.b   #4,d0
    move.b  d0,d3

    DOS_GETCHAR_D0
    move.b  d0,d2
    cmp.b   #$1B,d2
    beq.b   .cancel
    bsr     hex_char_to_nibble
    bmi.b   .cancel
    or.b    d3,d0

    move.b  d0,d3
    moveq   #0,d1
    move.b  d3,d1
    bsr     print_hex_long_from_d1
    bsr     print_new_line

    move.b  d3,d0
    rts

.cancel:
    clr.b   d0
    rts

hex_char_to_nibble:
    move.b  d2,d0
    cmp.b   #'0',d0
    bcs.b   .invalid
    cmp.b   #'9'+1,d0
    bcc.b   .try_alpha
    sub.b   #'0',d0
    rts
.try_alpha:
    or.b    #$20,d0
    cmp.b   #'a',d0
    bcs.b   .invalid
    cmp.b   #'f'+1,d0
    bcc.b   .invalid
    sub.b   #'a'-10,d0
    rts
.invalid:
    moveq   #-1,d0
    rts


; =============================================================================
; print_string
; Print null or CR terminated string to stdout
; a0 = string pointer
; =============================================================================

print_string:
    movem.l d0/a0,-(sp)
.loop:
    move.b  (a0)+,d0
    beq.b   .done
    DOS_PUTCHAR_W
    bra.b   .loop
.done:
    movem.l (sp)+,d0/a0
    rts


; =============================================================================
; print_decimal
; Print 16-bit unsigned value in d0.w as decimal
; CRITICAL: before each divu the upper word of the dividend must be zero.
; If d1.l upper word is non-zero and the quotient > 65535 the 68000 generates
; a divide overflow exception ($14) which crashes the program.
; =============================================================================

print_decimal:
    movem.l d0-d2/a0,-(sp)
    lea     .buf+5,a0           ; point to end of buffer
    move.b  #0,-(a0)            ; null terminator (build digits right to left)
    moveq   #10,d2              ; divisor
    move.l  d0,d1
    and.l   #$0000FFFF,d1       ; clear upper word — essential for first divu
.divide:
    divu    d2,d1               ; d1.l / 10
                                ; → quotient  in d1 lower word
                                ; → remainder in d1 upper word
    move.w  d1,-(sp)            ; save quotient
    swap    d1                  ; bring remainder to lower word
    add.b   #'0',d1             ; remainder → ASCII digit
    move.b  d1,-(a0)            ; store digit (right to left in buffer)
    move.w  (sp)+,d1            ; restore quotient to lower word
    and.l   #$0000FFFF,d1       ; CRITICAL: clear upper word before next divu
    tst.w   d1                  ; quotient = 0?
    bne.b   .divide             ; no → divide again
    bsr     print_string        ; a0 points to first digit
    movem.l (sp)+,d0-d2/a0
    rts
.buf:   ds.b    6               ; 5 digits max for 16-bit + null terminator


; =============================================================================
; print_hex_long
; Print d0.l as 8 hex digits
; =============================================================================

print_hex_long:
    movem.l d0-d2,-(sp)
    move.l  d0,d1   ; save to d1 as d0 will be used by DOS PUTCHAR
    moveq   #7,d2
.loop:
    rol.l   #4,d1
    move.l  d1,d0
    and.b   #$0f,d0
    bsr     print_hex_digit
    dbf     d2,.loop
    movem.l (sp)+,d0-d2
    rts

; print_hex_long_from_d1: same but value in d1.l (preserves d0)
print_hex_long_from_d1:
    movem.l d0-d2,-(sp)
    moveq   #7,d2
.loop:
    rol.l   #4,d1
    move.l  d1,d0
    and.b   #$0f,d0
    bsr     print_hex_digit
    dbf     d2,.loop
    movem.l (sp)+,d0-d2
    rts


; =============================================================================
; print_hex_bytes_8
; Print 8 bytes from a0 as space-separated hex pairs
; =============================================================================

print_hex_bytes_8:
    movem.l d0-d2/a0,-(sp)
    moveq   #7,d2
.loop:
    move.b  (a0)+,d1
    move.b  d1,d0
    lsr.b   #4,d0
    bsr     print_hex_digit
    move.b  d1,d0
    and.b   #$0f,d0
    bsr     print_hex_digit
    move.w  #' ',d0
    DOS_PUTCHAR_W
    dbf     d2,.loop
    movem.l (sp)+,d0-d2/a0
    rts

; d0 is the hex digit stored in the bottom nibble
print_hex_digit:
    add.b   #'0',d0
    cmp.b   #'9'+1,d0
    bcs.b   .hex_ok
    add.b   #'A'-'9'-1,d0
.hex_ok:
    DOS_PUTCHAR_W
    rts

print_new_line:
    pea     str_newline
    DOS     _PRINT
    addq.l  #4,sp
    rts

; =============================================================================
; print_usage_and_exit
; =============================================================================

print_usage_and_exit:
    lea     str_usage,a0
    bsr     print_string
    bra     exit_error


; =============================================================================
; Exit routines
; =============================================================================

exit_ok:
    DOS_EXIT_CODE 0

exit_error:
    DOS_EXIT_CODE 1


; =============================================================================
; String constants
; =============================================================================
    data
    even

str_banner:
    dc.b    $0D,$0A
    dc.b    "X68000 Sound Driver Test Shell",  $0D,$0A
    dc.b    "Port of MD bespoke Z80 driver",   $0D,$0A
    dc.b    "YM2151 + MSM6258 + MIDI (MU1000EX)", $0D,$0A
    dc.b    "------------------------------------",$0D,$0A
    dc.b    0

str_help:
    dc.b    $0D,$0A
    dc.b    "Commands:",$0D,$0A
    dc.b    "  0-9      Play track 1-10 (current bank)",$0D,$0A
    dc.b    "  A-Z      Play track 11-36 (current bank)",$0D,$0A
    dc.b    "  B        Toggle bank 0/1",$0D,$0A
    dc.b    "  S        Trigger SFX by hex index",$0D,$0A
    dc.b    "  I        Trigger instrument by hex index",$0D,$0A
    dc.b    "  F        Fade out current music",$0D,$0A
    dc.b    "  P        Pause / Resume toggle",$0D,$0A
    dc.b    "  +        Volume up",$0D,$0A
    dc.b    "  -        Volume down",$0D,$0A
    dc.b    "  D        Debug info (IRQ/OPM counters, status)",$0D,$0A
    dc.b    "  ?        Show this help",$0D,$0A
    dc.b    "  Q        Quit",$0D,$0A
    dc.b    0

str_usage:
    dc.b    "Usage: soundtest.x music.bin sfx.bin",$0D,$0A
    dc.b    0

str_loading_music:
    dc.b    "Loading music: ",0
str_loading_sfx:
    dc.b    "Loading SFX:   ",0
str_ok:
    dc.b    "OK",$0D,$0A,0

str_load_addr:
    dc.b    "Code at: ",0
str_ram_addr:
    dc.b    "RAM  at: ",0
str_music_hdr:
    dc.b    "Music[0..7]: ",0
str_track_ptrs:
    dc.b    "Track ptrs : ",0

str_tracks_found:
    dc.b    "Tracks found: Bank0=",0
str_tracks_bank0:
    dc.b    " Bank1=",0
str_tracks_bank1:
    dc.b    $0D,$0A,0

str_playing:
    dc.b    "Playing: ",0
str_bank:
    dc.b    "Bank ",0
str_track:
    dc.b    " Track ",0
str_bank0:
    dc.b    "Switched to bank 0",$0D,$0A,0
str_bank1:
    dc.b    "Switched to bank 1",$0D,$0A,0
str_track_invalid:
    dc.b    "Track not found in bank",$0D,$0A,0

str_paused:
    dc.b    "Paused",$0D,$0A,0
str_resumed:
    dc.b    "Resumed",$0D,$0A,0
str_fading:
    dc.b    "Fading out...",$0D,$0A,0
str_vol:
    dc.b    "Volume TL offset: ",0

str_sfx_prompt:
    dc.b    "SFX index (2 hex digits, ESC=cancel): ",0
str_inst_prompt:
    dc.b    "Instrument index (2 hex digits, ESC=cancel): ",0
str_triggering_sfx:
    dc.b    "Triggering SFX 0x",0
str_triggering_inst:
    dc.b    "Triggering instrument 0x",0

str_dbg_irq:
    dc.b    "IRQ count   : 0x",0
str_dbg_opm:
    dc.b    "OPM writes  : 0x",0
str_dbg_status:
    dc.b    "Drv status  : 0x",0
str_dbg_track:
    dc.b    "Track ptr   : 0x",0
str_dbg_ch0:
    dc.b    "Ch0 cfg/flg/dis: 0x",0
str_intvcs_check:
    dc.b    "INTVCS addr : 0x",0
str_opm_init_count:
    dc.b    "OPM init writes: 0x",0

str_unknown_cmd:
    dc.b    "Unknown command - press ? for help",$0D,$0A,0
str_err_open_music:
    dc.b    "Error: cannot open music file",$0D,$0A,0
str_err_open_sfx:
    dc.b    "Error: cannot open sfx file",$0D,$0A,0
str_err_read:
    dc.b    "Error: file read failed",$0D,$0A,0
str_goodbye:
    dc.b    "Sound driver stopped. Goodbye.",$0D,$0A,0
str_prompt:
    dc.b    "> ",0
str_newline:
    dc.b    $0D,$0A,0

; =============================================================================
; RAM variables (BSS section)
; =============================================================================

; File handles
    bss
    even
file_music:         ds.l    1
file_sfx:           ds.l    1

; Loaded data buffers
music_data:         ds.b    MUSIC_FILE_SIZE
sfx_data:           ds.b    SFX_BUFFER_SIZE

; Argument buffers (filenames copied from command line, null terminated)
    even
arg_music_buf:      ds.b    128
arg_sfx_buf:        ds.b    128
    even
arg_music_path:     ds.l    1       ; pointer to arg_music_buf
arg_sfx_path:       ds.l    1       ; pointer to arg_sfx_buf

; Shell state
shell_paused:       ds.b    1
shell_volume:       ds.b    1
shell_bank:         ds.b    1
shell_track:        ds.b    1
shell_running:      ds.b    1

    even
; Saved system state
; Note: saved_vblank_vec is in sound_driver.s RAM (set by snd_init via _INTVCS)

; Track counts per bank (discovered from file)
bank0_track_count:  ds.w    1
bank1_track_count:  ds.w    1

; --- Debug counters ---
irq_counter:        ds.l    1       ; incremented every timer B interrupt
opm_write_count:    ds.l    1       ; incremented every write_opm call


; =============================================================================
; Include sound driver
; =============================================================================

    include "sound_driver.s"
