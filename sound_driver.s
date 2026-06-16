; =============================================================================
; sound_driver.s — X68000 Sound Driver
; Port of bespoke Mega Drive Z80 sound driver to 68000 targeting:
;   YM2151  (OPM)     — FM music, replaces YM2612
;   MSM6258 (ADPCM)   — samples, replaces MD DAC (raw PCM converted at load)
;   MU1000EX via MIDI — PSG replacement via Polykubos board
;
; Two channel systems:
;   Music channels    : base MUSIC_CH_BASE ($11AA equiv)
;                       6 FM + 3 MIDI = 9 channels, 54 bytes ($36) each
;                       Processed by snd_music_tick at tempo-divided rate
;   Instrument channels: base INST_CH_BASE ($111A equiv)
;                       4 FM channels, 36 bytes ($24) each
;                       Processed by snd_inst_tick at timer B rate
;
; Key differences from Z80 driver:
;   - No bank switching — direct RAM pointers replace bank+offset system
;   - No Z80/68k shared RAM — single CPU, direct variable access
;   - YM2151 channels are linear 0-7, no port 0/1 split, no gap at $03
;   - YM2151 operator slots: slot = (op_index * 8) + channel
;   - OPM key-on operator mask bit order differs from YM2612 (1-bit right shift)
;   - PSG channels replaced by MIDI channels 1-3 on MU1000EX
;   - MD DAC (raw PCM) replaced by MSM6258 (OKI ADPCM format)
;   - Re-entrancy handled by 68k interrupt masking, not $0016 lock byte
;
; Communication interface (mirrors Z80 shared RAM $A000xx layout):
;   snd_bank        — track bank (0/1) → index into snd_track_table
;   snd_track       — track index to load ($0005)
;   snd_fade_speed  — fade rate, non-zero starts fade ($0006)
;   snd_ch_count    — active channel count $07 or $09 ($0007)
;   snd_status      — $3F=idle $00=busy, read by game ($0008)
;   snd_vol_accum   — volume accumulator, internal ($0009)
;   snd_pause       — $00=play $01=pause ($000B)
;   snd_sample      — $FF=ADPCM active $00=stopped ($0010)
;   snd_instrument  — instrument trigger: bits6-0=index bit7=all ops ($0012)
;   snd_pan         — panning value bits1-0 ($0013)
;   snd_expression  — expression/velocity ($0014)
;
; Build:
;   vasmm68k_mot -Fxfile -m68000 -mot -L sound.lst -o sound.x sound_driver.s
; =============================================================================

;    include "x68k_hw.i"
;    include "x68k_macros.i"


; =============================================================================
; Additional hardware addresses not in x68k_hw.i
; =============================================================================
    data
    even
; OKI MSM6258 ADPCM
ADPCM_CTRL          equ $E92001     ; control register (byte, odd)
                                    ;   bit 3   : 1=start 0=stop
                                    ;   bits 1-0: clock divider 00=/1024 01=/768 10=/512
ADPCM_DATA          equ $E92003     ; data port — write OKI ADPCM nibble pairs

; MIDI (Polykubos / Sharp CZ-6BM1 compatible)
MIDI_STATUS         equ $EAFA01     ; status: bit 1=TX ready bit 0=RX ready
MIDI_DATA           equ $EAFA03     ; read/write data byte


; =============================================================================
; YM2151 (OPM) register map
; =============================================================================
YM2151_ADDR         equ $E90001     ; register selection address
YM2151_DATA         equ $E90003     ; 8 bit value to write to selected register
YM2151_STATUS       equ $E90003     ; address to read status

OPM_TEST            equ $01         ; test register (write $02 to reset LFO)
OPM_KON             equ $08         ; key on/off
                                    ;   bits 6-3: op mask C2=6 M2=5 C1=4 M1=3
                                    ;   bits 2-0: channel 0-7
OPM_NOISE           equ $0F         ; noise enable / frequency
OPM_CLKA1           equ $10         ; timer A high 8 bits
OPM_CLKA2           equ $11         ; timer A low 2 bits
OPM_CLKB            equ $12         ; timer B (fires at sequencer rate)
OPM_TIMER_CTRL      equ $14         ; timer IRQ control
                                    ;   bit 5: reset timer B IRQ
                                    ;   bit 3: enable timer B IRQ
                                    ;   bit 1: start timer B
OPM_LFRQ            equ $18         ; LFO frequency
OPM_PMD_AMD         equ $19         ; LFO modulation depth (bit7=0→PMD, bit7=1→AMD)
OPM_CT_W            equ $1B         ; CT1/CT2 output + LFO waveform (bits 1-0)
OPM_RL_FB_CON       equ $20         ; ch 0-7: L/R pan + feedback + algorithm
                                    ;   bit 7: right output enable
                                    ;   bit 6: left output enable
                                    ;   bits 5-3: feedback level (0-7)
                                    ;   bits 2-0: algorithm (0-7)
OPM_KC              equ $28         ; ch 0-7: key code
                                    ;   bits 6-4: octave (0-7)
                                    ;   bits 3-0: note (C=0,C#=1,D=2,D#=4,E=5,
                                    ;             F=6,F#=8,G=9,G#=10,A=12,A#=13,B=14)
                                    ;   values 3,7,11 are unused
OPM_KF              equ $30         ; ch 0-7: key fraction (bits 7-2, 6 bits)
OPM_PMS_AMS         equ $38         ; ch 0-7: phase/amplitude mod sensitivity
                                    ;   bits 6-4: PMS (0-7)
                                    ;   bits 1-0: AMS (0-3)
; Operator registers — slot = (op_index * 8) + channel
; op_index: 0=M1 1=M2 2=C1 3=C2 → slots 0-7, 8-15, 16-23, 24-31
OPM_DT1_MUL         equ $40         ; detune1 (bits 6-4) + multiple (bits 3-0)
OPM_TL              equ $60         ; total level (bits 6-0, 0=max 127=silent)
OPM_KS_AR           equ $80         ; key scale (bits 7-6) + attack rate (bits 4-0)
OPM_AMS_D1R         equ $A0         ; AMS enable (bit 7) + decay1 rate (bits 4-0)
OPM_DT2_D2R         equ $C0         ; detune2 (bits 7-6) + decay2 rate (bits 4-0)
OPM_D1L_RR          equ $E0         ; decay1 level (bits 7-4) + release rate (bits 3-0)

; Key-on operator mask bits (for OPM_KON register)
OPM_KON_M1          equ $08         ; bit 3
OPM_KON_M2          equ $10         ; bit 4
OPM_KON_C1          equ $20         ; bit 5
OPM_KON_C2          equ $40         ; bit 6
OPM_KON_ALL         equ $78         ; all operators M1+M2+C1+C2

; YM2612 → YM2151 key-on operator mask conversion:
;   YM2612 $28 bits: C2=7 M2=6 C1=5 M1=4  → shift right 1 for OPM
;   OPM    $08 bits: C2=6 M2=5 C1=4 M1=3  → same operators, one bit lower

; Carrier operator masks per OPM algorithm (0-7)
; Bit set = operator is a carrier (affected by volume/fade)
; Bit 3=M1, Bit 2=M2, Bit 1=C1, Bit 0=C2
opm_carrier_mask:
    dc.b    %00000001   ; algo 0: C2 only
    dc.b    %00000001   ; algo 1: C2 only
    dc.b    %00000001   ; algo 2: C2 only
    dc.b    %00000001   ; algo 3: C2 only
    dc.b    %00000011   ; algo 4: C1+C2
    dc.b    %00000111   ; algo 5: M2+C1+C2
    dc.b    %00000111   ; algo 6: M2+C1+C2
    dc.b    %00001111   ; algo 7: all operators


; =============================================================================
; FM frequency table — confirmed from verified Z80 binary
; 3 bytes per note: [ix+$22 value] [F-number low] [F-number high with block]
; 14 entries covering the game's pitch range
; Used by sub_07dbh FM path (add $19 offset, * 3 per note)
; On X68000: F-number/block → OPM KeyCode/KeyFraction conversion applied at runtime
md_fm_freq_table:
    dc.b    $24,$83,$02     ; note 1  C
    dc.b    $26,$aa,$02     ; note 2  C#
    dc.b    $28,$d2,$02     ; note 3  D
    dc.b    $2a,$fd,$02     ; note 4  D#
    dc.b    $2d,$2b,$03     ; note 5  E
    dc.b    $30,$5b,$03     ; note 6  F
    dc.b    $33,$8e,$03     ; note 7  F#
    dc.b    $36,$c4,$03     ; note 8  G
    dc.b    $39,$fd,$03     ; note 9  G#
    dc.b    $3c,$3a,$04     ; note 10 A
    dc.b    $40,$7b,$04     ; note 11 A#
    dc.b    $44,$bf,$04     ; note 12 B
    dc.b    $cb,$5c,$0d     ; note 13
    dc.b    $c0,$9c,$0c     ; note 14

; PSG frequency table — confirmed from verified Z80 binary
; 3 bytes per note, PSG period values (descending = higher pitch)
; Used by sub_07dbh PSG path (add $3D offset)
; Not needed for X68000 port (PSG replaced by MIDI) — kept for reference
md_psg_freq_table:
    dc.b    $b5,$e7,$0b
    dc.b    $ab,$3c,$0b
    dc.b    $a1,$9a,$0a
    dc.b    $98,$02,$0a
    dc.b    $8f,$72,$09
    dc.b    $87,$ea,$08
    dc.b    $80,$6a,$08
    dc.b    $78,$f1,$07
    dc.b    $72,$7f,$07
    dc.b    $6b,$13,$07

; OPM KeyCode derivation from MD FM frequency table
; The MD F-number encodes pitch as a continuous value
; For OPM we use the note index directly via opm_note_table
; The ix+$22 byte from md_fm_freq_table is stored in CH_FREQ_BYTE
; and used for arpeggio/vibrato calculations — preserve it exactly

; MD F-number high byte bit layout: [block(3)][F-num-hi(5)]
; block = octave offset from base octave
; Extract: block = (F-hi >> 5) & 7, F-num-hi = F-hi & $1F
; On OPM: KeyCode = (octave << 4) | opm_note_nibble
;          KeyFraction = (fine-tune adjusted, bits 7-2)
; OPM note nibble values (bits 3-0 of KC register):
;   C=0, C#=1, D=2, D#=4, E=5, F=6, F#=8, G=9, G#=10, A=12, A#=13, B=14
;   Values 3, 7, 11 are unused (hardware quirk — skip them)
; MD pitch index 1=C through 12=B (semitone chromatic scale)
; Indices 13-14: check original Z80 frequency table for exact mapping
; =============================================================================

opm_note_table:
    dc.b    $00         ; index 0  unused (rest handled separately)
    dc.b    $00         ; index 1  C
    dc.b    $01         ; index 2  C#
    dc.b    $02         ; index 3  D
    dc.b    $04         ; index 4  D#
    dc.b    $05         ; index 5  E
    dc.b    $06         ; index 6  F
    dc.b    $08         ; index 7  F#
    dc.b    $09         ; index 8  G
    dc.b    $0A         ; index 9  G#
    dc.b    $0C         ; index 10 A
    dc.b    $0D         ; index 11 A#
    dc.b    $0E         ; index 12 B
    dc.b    $00         ; index 13 verify against original table
    dc.b    $00         ; index 14 verify against original table


; =============================================================================
; MIDI channel assignments and GM percussion map
; =============================================================================

MIDI_PSG0           equ 0           ; PSG ch0 → MIDI ch1 (0-indexed)
MIDI_PSG1           equ 1           ; PSG ch1 → MIDI ch2
MIDI_PSG2           equ 2           ; PSG ch2 → MIDI ch3
MIDI_PERCUSSION     equ 9           ; PSG noise → MIDI ch10 (GM percussion)

MIDI_BASSDRUM       equ 36
MIDI_RIMSHOT        equ 37
MIDI_SNARE          equ 38
MIDI_HIHAT_CL       equ 42
MIDI_HIHAT_OP       equ 46

; MIDI note offsets for PSG → MIDI note conversion
; Chromatic offsets: C=0 through B=11
midi_note_offset:
    dc.b    0,1,2,3,4,5,6,7,8,9,10,11,0,0

; PSG noise index → GM drum note mapping
; Indexed by (noise_value >> 3) & $07
midi_noise_map:
    dc.b    MIDI_BASSDRUM
    dc.b    MIDI_RIMSHOT
    dc.b    MIDI_SNARE
    dc.b    MIDI_SNARE
    dc.b    MIDI_HIHAT_CL
    dc.b    MIDI_HIHAT_CL
    dc.b    MIDI_HIHAT_OP
    dc.b    MIDI_SNARE


; =============================================================================
; Channel block field offsets
;
; MUSIC_CH_BASE blocks (54 bytes = $36 each, 9 total):
;   Used by music sequencer (snd_music_tick / snd_channel_tick)
;
; INST_CH_BASE blocks (36 bytes = $24 each, 4 total):
;   Used by instrument system (snd_inst_tick / snd_inst_channel_tick)
;
; Fields marked [M] = music channels only
; Fields marked [I] = instrument channels only
; Fields marked [B] = both channel types
; =============================================================================

; [B] Common fields
CH_CONFIG           equ $00     ; channel configuration byte
                                ;   bit 5   : 1=MIDI/PSG 0=FM
                                ;   bits 2-0: channel number
                                ;     FM: 0-5 (linear, no YM2612 port gap)
                                ;     MIDI: 0-2 (PSG channel index)
CH_DISABLE          equ $01     ; disable flag: non-zero suppresses hw writes
                                ; equivalent of ix+$01 in Z80 driver
                                ; set during channel init, cleared when ready
CH_FREQ_LO          equ $02     ; frequency low byte
                                ;   FM: OPM KeyCode (octave<<4 | note_nibble)
                                ;   MIDI: MIDI note number (0-127)
CH_FREQ_HI          equ $03     ; frequency high byte
                                ;   FM: OPM KeyFraction (bits 7-2, 6 bits)
                                ;   MIDI: unused
CH_VIB_DELTA_LO     equ $04     ; vibrato frequency delta low
CH_VIB_DELTA_HI     equ $05     ; vibrato frequency delta high
CH_VIB_ACCUM        equ $06     ; vibrato accumulator (init $80)
CH_FINETUNE         equ $07     ; fine-tune signed offset (ix+$07)
CH_VOLUME           equ $08     ; channel volume / TL base value (ix+$08)
                                ;   FM: OPM TL style 0=loud $7F=silent
                                ;   MIDI: inverted for velocity
CH_OCTAVE           equ $09     ; current octave 0-7 (ix+$09)
CH_PSG_MASK         equ $0A     ; PSG mixer mask (ix+$0a)
                                ;   FM: operator carrier mask index
                                ;   MIDI: unused
CH_PTR_LO           equ $0B     ; track/instrument data pointer low  (ix+$0b)
CH_PTR_HI           equ $0C     ; track/instrument data pointer high (ix+$0c)
CH_LOOP_LO          equ $0D     ; loop pointer low  (ix+$0d)
CH_LOOP_HI          equ $0E     ; loop pointer high (ix+$0e)
; $0F-$13 reserved / unused in our port
CH_INST_PTR_LO      equ $14     ; instrument table pointer low  (ix+$14) [B]
CH_INST_PTR_HI      equ $15     ; instrument table pointer high (ix+$15) [B]
; $16 unused
CH_FLAGS            equ $17     ; channel flags byte (ix+$17) [M]
                                ;   bit 0: channel inactive (1=skip)
                                ;   bit 1: portamento active
                                ;   bit 3: arpeggio active
                                ;   bit 5: effects active
                                ;   bit 6: vibrato enable
CH_DURATION         equ $18     ; note duration counter (ix+$18) [M]
CH_ENV_FLAGS        equ $19     ; envelope/effect flags (ix+$19) [M]
                                ;   bit 0: note currently playing
                                ;   bit 4: sustain/legato active
                                ;   bit 5: retrigger suppress
                                ;   bits 7-6: LFO depth
CH_PORT_THRESH      equ $1A     ; portamento threshold (ix+$1a) [M]

; --- Fields $1B-$1C differ between channel types ---
; Music channel ($11AA base): preset pointer
MUSIC_PRESET_LO     equ $1B     ; active preset data pointer low  (ix+$1b) [M]
MUSIC_PRESET_HI     equ $1C     ; active preset data pointer high (ix+$1c) [M]
; Instrument channel ($111A base): status flags
INST_STATUS         equ $1B     ; instrument channel status (ix+$1b) [I]
                                ;   bit 0: channel active
                                ;   bit 1: vibrato enable
                                ;   bits 7-6: panning bits
INST_DURATION       equ $1C     ; instrument duration counter (ix+$1c) [I]

; [B] Common from $1D onward
CH_NOTE_REG         equ $1D     ; note register / vibrato base (ix+$1d)
CH_ARP_S1_LO        equ $1E     ; arpeggio step 1 low [M] / unused [I]
INST_STEP_RATE      equ $1F     ; fractional step rate (ix+$1f) [I]
CH_ARP_S1_HI        equ $1F     ; arpeggio step 1 high [M]
INST_CH_INDEX       equ $20     ; channel index for address calculation [I]
CH_ARP_S2_LO        equ $20     ; arpeggio step 2 low [M]
INST_PREV_DUR       equ $21     ; previous duration value [I]
CH_ARP_S2_HI        equ $21     ; arpeggio step 2 high [M]
INST_FRAC_ACCUM     equ $22     ; fractional accumulator (ix+$22) [I]
CH_FREQ_BYTE        equ $22     ; frequency table byte [M]
INST_PRIORITY       equ $23     ; channel priority (ix+$23) [I]
CH_VIB_PARAMS       equ $23     ; vibrato parameters 6 bytes $23-$28 [M]
; Music channel only ($24 bytes and above)
CH_ARP_BASE         equ $2A     ; arpeggio base value 5 bytes $2A-$2E
CH_VIB_DEPTH        equ $2B     ; vibrato depth parameter
CH_ARP_INTERVAL     equ $2C     ; arpeggio interval
CH_ARP_CTR_INIT     equ $2D     ; arpeggio counter initialiser
CH_PAN_FLAGS        equ $2E     ; panning + vibrato direction flags
                                ;   bit 6: vibrato direction
                                ;   bit 7: vibrato invert
CH_ARP_COUNTER      equ $2F     ; arpeggio counter
CH_PORT_SPEED       equ $30     ; portamento speed
CH_PORT_TARGET      equ $31     ; portamento target
CH_PORT_BASE        equ $32     ; portamento base (copy of speed)
CH_LFO_DEPTH        equ $33     ; LFO depth register cache
CH_MIDI_MIXER       equ $34     ; MIDI pan / FM algorithm cache
CH_MIDI_SPEED       equ $35     ; MIDI portamento speed

; Channel block sizes
MUSIC_CH_SIZE       equ $36     ; 54 bytes per music channel block
INST_CH_SIZE        equ $24     ; 36 bytes per instrument channel block

; Channel counts
MUSIC_CH_COUNT      equ 9       ; total music channels (6 FM + 3 MIDI)
FM_MUSIC_COUNT      equ 6       ; FM music channels
MIDI_MUSIC_COUNT    equ 3       ; MIDI PSG replacement channels
INST_CH_COUNT       equ 4       ; instrument channels


; =============================================================================
; Duration lookup table
; Converts note duration index (upper nibble of note byte, 0-15) to tick count
; Equivalent of sub_0b56h — verify values against original Z80 table at $005F
; =============================================================================

; Duration lookup table 1 — offset $61, music sequencer (16 entries)
; Indexed by upper nibble of note byte (0-15)
snd_duration_table:
    dc.b    $10,$10,$10,$10,$30,$70,$70,$F0
    dc.b    $04,$04,$04,$04,$05,$05,$05,$05

; Duration lookup table 2 — offset $69, PSG noise / instrument channels (12 entries)
; Overlaps with tail of table 1 — lower indices share values
; On X68000 used for MIDI percussion note duration
snd_duration_table_2:
    dc.b    $04,$04,$04,$04,$05,$05,$05,$05
    dc.b    $06,$06,$06,$06





; =============================================================================
; Code section
; =============================================================================

;    org     $22000
    text
    even

; =============================================================================
; snd_init
; Initialise entire sound system
; Call once at startup after all assets are loaded into RAM
; =============================================================================

snd_init:
    ; Install OPM timer B interrupt handler
    ; Use DOS _INTVCS ($FF25) — correct way to set interrupt vectors
    ; (works in both user and supervisor mode)
    lea     snd_timer_irq,a0
    move.l  a0,-(sp)            ; handler address (push first)
    move.w  #VBLANK_VECTOR,-(sp) ; vector number $4D (push second)
    DOS     _INTVCS                 ; DOS _INTVCS
    addq.l  #6,sp
    move.l  d0,(saved_vblank_vec) ; save old handler returned in d0

    ; Initialise hardware
    DOS_SUPER
    bsr     opm_init
    bsr     adpcm_init
    bsr     midi_init

    ; Clear all channel blocks to zero
    bsr     snd_clear_all_channels

    ; Set initial channel configuration
    bsr     snd_assign_channels

    ; Set driver to idle state
    move.b  #$3F,(snd_status)
    move.b  #2,(snd_tempo_div)
    move.b  #$7F,(snd_tempo_base)  ; default tempo (confirmed from sub_0203h)
    clr.b   (snd_update_flag)
    clr.b   (snd_fade_flag)
    clr.b   (snd_fade_speed)
    clr.b   (snd_pause)
    clr.b   (snd_instrument)
    clr.b   (snd_sample)
    clr.l   (snd_adpcm_ptr)
    clr.l   (snd_adpcm_len)
    clr.b   (snd_midi_notes+0)
    clr.b   (snd_midi_notes+1)
    clr.b   (snd_midi_notes+2)

    ; NOTE: We stay in supervisor mode after snd_init returns.
    ; The interrupt handler (snd_timer_irq) runs in supervisor mode
    ; automatically since it's entered via an interrupt vector.
    ; The main program (soundtest.s) continues in supervisor mode too
    ; which is fine for a standalone game/utility.
    ; To return to user mode call: move.l (saved_ssp),-(sp) / dc.w $FF20
    rts


; =============================================================================
; opm_init
; Initialise YM2151 and start timer B for sequencer ticks
;
; Timer B frequency: OPM clock = 4MHz
;   Timer B period = 1024 * (256 - CLKB_value) OPM clocks
;   For ~60Hz: CLKB = 256 - (4000000 / (1024 * 60)) ≈ 256 - 65 = 191 = $BF
; =============================================================================

opm_init:
    ; Reset LFO
    move.b  #OPM_TEST,d0
    move.b  #$02,d1
    bsr     write_opm

    ; Set timer B value for ~60Hz tick rate
    move.b  #OPM_CLKB,d0
    move.b  #$BF,d1
    bsr     write_opm

    ; Enable timer B IRQ and start timer B
    ; $2A = bit5(reset B flag) + bit3(enable B IRQ) + bit1(start B)
    move.b  #OPM_TIMER_CTRL,d0
    move.b  #$2A,d1
    bsr     write_opm

    ; Set LFO frequency and waveform (sawtooth)
    move.b  #OPM_LFRQ,d0
    move.b  #$23,d1
    bsr     write_opm
    move.b  #OPM_CT_W,d0
    move.b  #$00,d1
    bsr     write_opm

    ; Silence all 32 operator slots — set TL to maximum attenuation ($7F)
    move.b  #OPM_TL,d0         ; register $60 = first TL slot
    move.b  #$7F,d1
    moveq   #31,d7              ; 32 slots total
.opm_tl_clear:
    bsr     write_opm
    addq.b  #1,d0
    dbf     d7,.opm_tl_clear

    ; Centre pan all 8 channels, no feedback, algorithm 0
    move.b  #OPM_RL_FB_CON,d0
    move.b  #$C0,d1             ; L+R output, FB=0, CON=0
    moveq   #7,d7
.opm_pan_init:
    bsr     write_opm
    addq.b  #1,d0
    dbf     d7,.opm_pan_init

    ; Key-off all channels (write channel number only, no operator bits)
    move.b  #OPM_KON,d0
    moveq   #7,d7
    moveq   #0,d1
.opm_koff_all:
    bsr     write_opm
    addq.b  #1,d1
    dbf     d7,.opm_koff_all

    rts


; =============================================================================
; write_opm
; Write to YM2151 register with busy-wait
; d0.b = register address
; d1.b = data value
; Clobbers: nothing
; Equivalent of write_to_channel_1to3_regs / write_to_channel_4to6_regs
; combined — no port selection needed on OPM
; =============================================================================

; =============================================================================
; write_opm
; Write to YM2151 register
; d0.b = register address
; d1.b = data value
; Clobbers: nothing
;
; NOTE: Reading $E90001 for busy-flag polling crashes in Human68k user mode
; (hardware register access requires supervisor mode). On real X68000 hardware
; at 10MHz the CPU is slow enough that the YM2151 is never busy between
; sequential writes, so no polling is needed. Two NOPs provide the minimum
; address-to-data setup time the chip requires.
;
; For a game running in supervisor mode (entered via DOS _SUPER $FF20 at
; startup), the busy-flag poll can be restored:
;   .busy: btst #7,(YM2151_STATUS) / bne.b .busy
; =============================================================================

write_opm:
    addq.l  #1,(opm_write_count)   ; debug instrumentation (soundtest.s)
.busy:
    btst.b  #7,(YM2151_STATUS)  ; bit 7 = busy flag
    bne.b   .busy
    move.b  d0,(YM2151_ADDR)   ; write register address
.busy2:
    btst    #7,(YM2151_STATUS)
    bne.b   .busy2
    move.b  d1,(YM2151_DATA)   ; write data
    rts


; =============================================================================
; write_opm_ch
; Write to OPM register with disable flag check
; Equivalent of sub_0086h (always writes) combined with ix+$01 check
; a4 = channel block, d0.b = register, d1.b = data
; =============================================================================

write_opm_ch:
    tst.b   (CH_DISABLE,a4)
    bne     .skip
    bsr     write_opm
.skip:
    rts


; =============================================================================
; adpcm_init
; Initialise OKI MSM6258 ADPCM chip
;
; Note on format: MD DAC used raw 8-bit unsigned PCM streamed by Z80
; MSM6258 uses OKI ADPCM format (4-bit compressed nibbles)
; MD samples must be converted to OKI ADPCM at startup (see adpcm_convert)
; =============================================================================

adpcm_init:
    move.b  #$00,(ADPCM_CTRL)  ; stop, clock /1024
    rts


; =============================================================================
; adpcm_convert
; Convert raw 8-bit unsigned PCM to OKI ADPCM format
; Call at startup for each sample before storing in RAM pool
;
; a0 = source: raw 8-bit unsigned PCM bytes
; a1 = destination: OKI ADPCM output buffer (half the size)
; d0.l = number of source bytes to convert
;
; OKI ADPCM encoding is a lossy 4:1 compression (8-bit → 4-bit)
; Each output byte contains two 4-bit ADPCM nibbles
; Simple linear predictor — for higher quality use offline conversion tool
; =============================================================================

adpcm_convert:
    movem.l d0-d7/a0-a2,-(sp)

    ; Initialise predictor state
    moveq   #0,d3               ; predictor (16-bit signed)
    moveq   #7,d4               ; step index (0-48)
    lea     adpcm_step_table,a2

    lsr.l   #1,d0               ; pairs of samples
    subq.l  #1,d0
.conv_loop:
    ; Sample 1 — high nibble
    moveq   #0,d1
    move.b  (a0)+,d1
    sub.w   #128,d1             ; unsigned → signed
    lsl.w   #6,d1               ; scale to 14-bit
    bsr     adpcm_encode_nibble
    move.b  d2,d5               ; save nibble (high)

    ; Sample 2 — low nibble
    moveq   #0,d1
    move.b  (a0)+,d1
    sub.w   #128,d1
    lsl.w   #6,d1
    bsr     adpcm_encode_nibble
    lsl.b   #4,d5
    or.b    d2,d5               ; combine nibbles
    move.b  d5,(a1)+            ; write output byte

    dbf     d0,.conv_loop

    movem.l (sp)+,d0-d7/a0-a2
    rts

; Encode one sample difference to 4-bit ADPCM nibble
; d1.w = sample value (signed 16-bit)
; d3.w = current predictor
; d4.b = step index
; a2 = step table pointer
; Returns: d2.b = encoded nibble, updates d3 and d4
adpcm_encode_nibble:
    move.w  d1,d6
    sub.w   d3,d6               ; difference = sample - predictor
    moveq   #0,d2               ; nibble = 0

    tst.w   d6
    bpl.b   .enc_pos
    neg.w   d6                  ; absolute difference
    move.b  #$08,d2             ; set sign bit

.enc_pos:
    ; Get current step size
    moveq   #0,d5
    move.b  d4,d5
    add.w   d5,d5               ; *2 for word table
    move.w  (a2,d5.w),d5       ; step size

    ; Encode magnitude bits 2-0
    move.w  d5,d7
    lsr.w   #2,d7               ; step/4
    cmp.w   d7,d6
    bcs.b   .bit2_done
    or.b    #$04,d2
    sub.w   d7,d6
.bit2_done:
    lsr.w   #1,d7               ; step/8 (was step/4, now /2 from that)
    cmp.w   d7,d6
    bcs.b   .bit1_done
    or.b    #$02,d2
    sub.w   d7,d6
.bit1_done:
    lsr.w   #1,d7
    cmp.w   d7,d6
    bcs.b   .bit0_done
    or.b    #$01,d2
.bit0_done:

    ; Update predictor
    move.w  d5,d7
    lsr.w   #3,d7
    btst    #2,d2
    beq.b   .no_add4
    add.w   d5,d7
    lsr.w   #1,d7               ; compensate
.no_add4:
    btst    #1,d2
    beq.b   .no_add2
    move.w  d5,d6
    lsr.w   #2,d6
    add.w   d6,d7
.no_add2:
    btst    #0,d2
    beq.b   .no_add1
    move.w  d5,d6
    lsr.w   #3,d6
    add.w   d6,d7
.no_add1:
    btst    #3,d2               ; sign bit
    beq.b   .enc_add
    sub.w   d7,d3               ; subtract from predictor
    bra.b   .enc_clamp
.enc_add:
    add.w   d7,d3               ; add to predictor

.enc_clamp:
    ; Clamp predictor to -32768..32767
    cmp.w   #32767,d3
    ble.b   .clamp_lo
    move.w  #32767,d3
.clamp_lo:
    cmp.w   #-32768,d3
    bge.b   .enc_index
    move.w  #-32768,d3

.enc_index:
    ; Update step index
    lea     adpcm_index_table,a1
    moveq   #0,d5
    move.b  d2,d5
    and.b   #$07,d5             ; magnitude bits only
    move.b  (a1,d5.w),d5       ; index delta
    ext.w   d5
    add.w   d5,d4               ; update index
    cmp.w   #0,d4
    bge.b   .idx_hi
    clr.w   d4
.idx_hi:
    cmp.w   #48,d4
    ble.b   .enc_done
    move.w  #48,d4
.enc_done:
    rts

; OKI ADPCM step size table (49 entries, words)
adpcm_step_table:
    dc.w    7,8,9,10,11,12,13,14
    dc.w    16,17,19,21,23,25,28,31
    dc.w    34,37,41,45,50,55,60,66
    dc.w    73,80,88,97,107,118,130,143
    dc.w    157,173,190,209,230,253,279,307
    dc.w    337,371,408,449,494,544,598,658
    dc.w    724

; OKI ADPCM index adjustment table (8 entries, signed bytes)
adpcm_index_table:
    dc.b    -1,-1,-1,-1,2,4,6,8


; =============================================================================
; midi_init
; Initialise MIDI port and MU1000EX
; =============================================================================
    even
midi_init:
    ; check midi is present first
    clr.b   midi_present
    btst    #1,(MIDI_STATUS)
    beq.b   .no_midi_board

    moveq   #1,d0
    move.b  d0,midi_present
    ; XG System On — resets MU1000EX to XG defaults
    lea     .xg_sysex,a0
    moveq   #.xg_sysex_end-.xg_sysex-1,d7
    bsr     send_midi_block

    ; Wait ~3 frames for MU1000EX reset (50ms minimum)
    move.l  #500000,d0
.delay:
    subq.l  #1,d0
    bne.b   .delay

    ; Set up PSG replacement channels
    bsr     midi_init_channels
.no_midi_board:
    rts

.xg_sysex:
    db    $F0,$43,$10,$4C,$00,$00,$7E,$00,$F7
.xg_sysex_end:
    db $00

midi_present:
    ds.b 1

; =============================================================================
; midi_init_channels
; Configure MU1000EX channels for PSG replacement
; Channels 1-3 (0-indexed 0-2): Square Lead patch 81
; Channel 10 (0-indexed 9): GM percussion
; =============================================================================
    even
midi_init_channels:
    moveq   #MIDI_MUSIC_COUNT-1,d7
    moveq   #MIDI_PSG0,d6
.ch_loop:
    ; Program Change: patch 81 (Square Lead) = 0-indexed 80
    move.b  d6,d0
    or.b    #$C0,d0
    bsr     send_midi_byte
    move.b  #80,d0
    bsr     send_midi_byte

    ; CC7 volume = max
    move.b  d6,d0
    or.b    #$B0,d0
    bsr     send_midi_byte
    move.b  #7,d0               ; CC7 channel volume
    bsr     send_midi_byte
    move.b  #127,d0
    bsr     send_midi_byte

    ; CC10 pan = centre
    move.b  d6,d0
    or.b    #$B0,d0
    bsr     send_midi_byte
    move.b  #10,d0              ; CC10 pan
    bsr     send_midi_byte
    move.b  #64,d0              ; centre
    bsr     send_midi_byte

    ; CC91 reverb = 0 (dry)
    move.b  d6,d0
    or.b    #$B0,d0
    bsr     send_midi_byte
    move.b  #91,d0              ; CC91 reverb
    bsr     send_midi_byte
    clr.b   d0
    bsr     send_midi_byte

    addq.b  #1,d6
    dbf     d7,.ch_loop

    ; Percussion channel: reverb off
    move.b  #MIDI_PERCUSSION,d0
    or.b    #$B0,d0
    bsr     send_midi_byte
    move.b  #91,d0
    bsr     send_midi_byte
    clr.b   d0
    bsr     send_midi_byte
    rts


; =============================================================================
; MIDI transmit routines
; =============================================================================

; Send one byte (d0.b) to MIDI output
send_midi_byte:
.wait:
    btst    #1,(MIDI_STATUS)
    beq.b   .wait
    move.b  d0,(MIDI_DATA)
    rts

; Send block of bytes: a0=source, d7=count-1
send_midi_block:
    move.b  (a0)+,d0
    bsr     send_midi_byte
    dbf     d7,send_midi_block
    rts

; MIDI Note On: d0.b=channel(0-indexed), d1.b=note, d2.b=velocity
midi_note_on:
    move.b  d0,-(sp)
    or.b    #$90,(sp)
    move.b  (sp)+,d0
    bsr     send_midi_byte
    move.b  d1,d0
    bsr     send_midi_byte
    move.b  d2,d0
    bsr     send_midi_byte
    rts

; MIDI Note Off: d0.b=channel, d1.b=note
midi_note_off:
    move.b  d0,-(sp)
    or.b    #$80,(sp)
    move.b  (sp)+,d0
    bsr     send_midi_byte
    move.b  d1,d0
    bsr     send_midi_byte
    clr.b   d0
    bsr     send_midi_byte
    rts

; MIDI CC: d0.b=channel, d1.b=controller, d2.b=value
midi_send_cc:
    move.b  d0,-(sp)
    or.b    #$B0,(sp)
    move.b  (sp)+,d0
    bsr     send_midi_byte
    move.b  d1,d0
    bsr     send_midi_byte
    move.b  d2,d0
    bsr     send_midi_byte
    rts

; MIDI Pitch Bend: d0.b=channel, d1.w=bend (0-16383, centre=8192)
midi_pitch_bend:
    move.b  d0,-(sp)
    or.b    #$E0,(sp)
    move.b  (sp)+,d0
    bsr     send_midi_byte
    move.w  d1,d0
    and.b   #$7F,d0             ; low 7 bits
    bsr     send_midi_byte
    move.w  d1,d0
    lsr.w   #7,d0
    and.b   #$7F,d0             ; high 7 bits
    bsr     send_midi_byte
    rts


; =============================================================================
; snd_clear_all_channels
; Zero all channel block memory
; =============================================================================

snd_clear_all_channels:
    lea     (snd_music_ch),a0
    move.w  #(MUSIC_CH_SIZE*MUSIC_CH_COUNT)-1,d0
.mc:
    clr.b   (a0)+
    dbf     d0,.mc
    lea     (snd_inst_ch),a0
    move.w  #(INST_CH_SIZE*INST_CH_COUNT)-1,d0
.ic:
    clr.b   (a0)+
    dbf     d0,.ic
    rts


; =============================================================================
; snd_assign_channels
; Set CH_CONFIG and CH_FLAGS for all channel blocks
; Equivalent of the channel number stamping in sub_0d1eh (without the gap)
; =============================================================================

snd_assign_channels:
    ; Music channels 0-5: FM
    ; Initial values confirmed from sub_02a9h / sub_02c0h:
    ;   CH_CONFIG     = 0-5 linear (no YM2612 port gap on OPM)
    ;   CH_OCTAVE     = 4   (middle octave — confirmed sub_02a9h)
    ;   CH_VOLUME     = $7F (silent — track sets volume via events)
    ;   CH_ENV_FLAGS  = $C0 (LFO depth bits 7-6 set, no note playing)
    ;   CH_PORT_THRESH= 1   (confirmed sub_02a9h ix+$1a=$01)
    ;   CH_DURATION   = 1   (expire on first tick → read first event)
    ;   CH_LFO_DEPTH  = $C0 (ix+$33=$C0, set in sub_0203h FM loop)
    lea     (snd_music_ch),a4
    moveq   #FM_MUSIC_COUNT-1,d7
    moveq   #0,d0
.fm_music:
    move.b  d0,(CH_CONFIG,a4)
    move.b  #1,(CH_FLAGS,a4)        ; inactive
    move.b  #1,(CH_DISABLE,a4)      ; disable until track loaded
    move.b  #4,(CH_OCTAVE,a4)       ; middle octave
    move.b  #$7F,(CH_VOLUME,a4)     ; silent
    move.b  #$C0,(CH_ENV_FLAGS,a4)  ; LFO depth bits
    move.b  #1,(CH_PORT_THRESH,a4)  ; portamento threshold
    move.b  #1,(CH_DURATION,a4)     ; expire immediately
    move.b  #$C0,(CH_LFO_DEPTH,a4)  ; ix+$33 = $C0
    lea     (MUSIC_CH_SIZE,a4),a4
    addq.b  #1,d0
    dbf     d7,.fm_music

    ; Music channels 6-8: MIDI (PSG replacement)
    ; PSG config bytes: $20,$21,$22 (bit 5 = MIDI/PSG flag)
    ; PSG initial ix+$0a (PSG_MASK) cycles: $F6,$ED,$DB (from sub_0203h rlca)
    moveq   #MIDI_MUSIC_COUNT-1,d7
    moveq   #0,d0
    move.b  #$F6,d3             ; initial PSG mask
.midi_music:
    move.b  d0,d1
    or.b    #$20,d1
    move.b  d1,(CH_CONFIG,a4)
    move.b  #1,(CH_FLAGS,a4)
    move.b  #1,(CH_DISABLE,a4)
    move.b  #4,(CH_OCTAVE,a4)
    move.b  #$7F,(CH_VOLUME,a4)
    move.b  #$C0,(CH_ENV_FLAGS,a4)
    move.b  #1,(CH_PORT_THRESH,a4)
    move.b  #1,(CH_DURATION,a4)
    move.b  d3,(CH_PSG_MASK,a4)     ; ix+$0a PSG mixer mask
    rol.b   #1,d3                   ; rlca equivalent: rotate for next channel
    lea     (MUSIC_CH_SIZE,a4),a4
    addq.b  #1,d0
    dbf     d7,.midi_music

    ; Instrument channels 0-3: FM on OPM channels 4-7
    lea     (snd_inst_ch),a4
    moveq   #INST_CH_COUNT-1,d7
    moveq   #4,d0
.fm_inst:
    move.b  d0,(CH_CONFIG,a4)
    clr.b   (INST_STATUS,a4)
    clr.b   (CH_DISABLE,a4)
    move.b  #4,(CH_OCTAVE,a4)
    move.b  #$7F,(CH_VOLUME,a4)
    lea     (INST_CH_SIZE,a4),a4
    addq.b  #1,d0
    dbf     d7,.fm_inst
    rts


; =============================================================================
; snd_timer_irq
; YM2151 timer B interrupt service routine
; Fires at ~60Hz — drives entire sound sequencer
; Equivalent of Z80 main polling loop at l0123h
; =============================================================================

snd_timer_irq:
    movem.l d0-d7/a0-a6,-(sp)

    addq.l  #1,(irq_counter)    ; debug instrumentation (soundtest.s)

    ; Acknowledge timer B in OPM (reset IRQ flag, restart timer)
    move.b  #OPM_TIMER_CTRL,d0
    move.b  #$2A,d1
    bsr     write_opm

    ; Acknowledge MFP interrupt
    bclr    #0,(MFP_ISRB)

    ; Check pause
    tst.b   (snd_pause)
    bne     .irq_exit

    ; Process instrument channels (timer B rate — every tick)
    bsr     snd_inst_tick

    ; Process music sequencer (tempo-divided rate)
    bsr     snd_music_tick

    ; Service ADPCM if active
    tst.b   (snd_sample)
    beq.b   .irq_exit
    bsr     adpcm_service

.irq_exit:
    movem.l (sp)+,d0-d7/a0-a6
    rte


; =============================================================================
; snd_music_tick
; Drive music sequencer — called every interrupt
; Equivalent of sub_0137h + sub_0325h
;
; IMPORTANT: sub_0137h in original is NOT the sequencer tick — it is the
; channel silence/reload handler called when SAMPLE_HANDSHAKE ($0010) is active.
; It silences all FM channels, silences PSG, then forces a full reload ($FF to l01c8h).
; The actual sequencer tick is sub_0325h, called from sub_01c9h (timer B handler).
; =============================================================================

snd_music_tick:
    ; --- sub_0137h equivalent ---
    ; Check SAMPLE_HANDSHAKE and update flag
    tst.b   (snd_sample)        ; $0010 equivalent
    beq.b   .no_silence         ; not active — skip silence

    ; Silence all active FM channels (sub_0137h inner loop)
    lea     (snd_music_ch),a4
    moveq   #FM_MUSIC_COUNT-1,d7
.silence_loop:
    ; Check if channel has a preset (ix+$1b/$1c non-zero)
    move.b  (MUSIC_PRESET_LO,a4),d0
    or.b    (MUSIC_PRESET_HI,a4),d0
    beq.b   .silence_next
    ; Temporarily clear disable flag and write TL=$7F to all operators
    move.b  (CH_DISABLE,a4),-(sp)
    clr.b   (CH_DISABLE,a4)
    bsr     snd_load_preset_ptr     ; a3 = preset data
    lea     ($08,a3),a2             ; iy+$08 → TL data base
    move.b  #$7F,d4                 ; e=$7F in original = max attenuation
    bsr     snd_write_tl_opm        ; silence all operators
    move.b  (sp)+,(CH_DISABLE,a4)  ; restore disable flag
.silence_next:
    lea     (MUSIC_CH_SIZE,a4),a4
    dbf     d7,.silence_loop

    ; Silence MIDI PSG channels (replaces PSG $9F/$BF/$DF/$FF writes)
    moveq   #MIDI_MUSIC_COUNT-1,d7
    moveq   #MIDI_PSG0,d6
.midi_silence:
    ; Send CC7 volume = 0 to silence MIDI channel
    move.b  d6,d0
    move.b  #7,d1               ; CC7 volume
    clr.b   d2
    bsr     midi_send_cc
    addq.b  #1,d6
    dbf     d7,.midi_silence

    ; Force full reload (ld a,$ff / ld (l01c8h),a)
    move.b  #$FF,(snd_update_flag)

.no_silence:
    ; --- sub_0325h equivalent (actual sequencer tick) ---

    ; Check if track load requested (snd_track non-zero = load pending)
    ; This check must come BEFORE the status check because loading
    ; the track is what transitions status from $3F (idle) to $00 (playing)
    tst.b   (snd_track)
    beq.b   .no_load
    bsr     snd_load_track      ; loads track, sets snd_status=$00
.no_load:

    ; Check driver status — $3F=idle (don't process), $00=playing (process)
    ; Mirrors Z80: or a / ret nz — return if status non-zero
    tst.b   (snd_status)
    bne     .tick_done          ; $3F = idle = nothing to do

    ; --- Tempo divider (mirrors l1390h) ---
    ; Divides IRQ rate by 2 — process sequencer every other tick
    subq.b  #1,(snd_tempo_div)
    bne     .tick_done
    move.b  #2,(snd_tempo_div)

    ; --- Fractional tempo accumulator (mirrors l1391h / l1391h+1) ---
    ; Add tempo_base to accumulator each divider tick
    ; When it overflows (carry) → time to advance the sequencer
    move.b  (snd_tempo_base),d0
    add.b   d0,(snd_tempo_frac)
    bcs.b   .tempo_carry
    clr.b   (snd_tempo_ovf)    ; no carry = no overflow = skip channel processing
    bra.b   .tick_done         ; come back next tick
.tempo_carry:
    move.b  #$FF,(snd_tempo_ovf)   ; overflow = time to process channels

    ; Process fade step if active
    tst.b   (snd_fade_speed)
    beq.b   .no_fade
    bsr     snd_fade_tick
    tst.b   (snd_fade_speed)   ; did fade complete (set status to idle)?
    beq     .tick_done         ; yes — don't process channels
.no_fade:

    ; --- Process all 9 music channel blocks ---
    ; Reached here only when tempo overflow occurred
    lea     (snd_music_ch),a4
    moveq   #MUSIC_CH_COUNT-1,d7
.ch_loop:
    bsr     snd_channel_tick
    lea     (MUSIC_CH_SIZE,a4),a4
    dbf     d7,.ch_loop

    ; Apply fade volume to FM channels if fading
    tst.b   (snd_fade_flag)
    beq.b   .tick_done
    bsr     snd_apply_fade_volume

.tick_done:
    rts


; =============================================================================
; snd_channel_tick
; Process one music channel for this sequencer tick
; a4 = pointer to music channel block (MUSIC_CH_BASE equivalent)
; Equivalent of sub_03d1h
; =============================================================================

snd_channel_tick:
    ; Skip if channel inactive (CH_FLAGS bit 0 = 1)
    btst    #0,(CH_FLAGS,a4)
    bne     .skip

    ; --- Decrement note duration (mirrors dec (ix+$18)) ---
    subq.b  #1,(CH_DURATION,a4)
    beq     snd_read_event      ; expired → read next event

    ; --- Check portamento threshold (mirrors cp (ix+$18)) ---
    move.b  (CH_PORT_THRESH,a4),d0
    cmp.b   (CH_DURATION,a4),d0
    bhi     .skip               ; above threshold

    ; --- Check sustain flag (mirrors bit 4,(ix+$19)) ---
    btst    #4,(CH_ENV_FLAGS,a4)
    bne     .skip

    ; --- Apply per-tick effects (mirrors l0878h / l0878h) ---
    bclr    #0,(CH_ENV_FLAGS,a4) ; clear note playing flag (l0878h)
    bsr     snd_apply_effects

.skip:
    rts


; =============================================================================
; snd_read_event
; Read and dispatch next event byte from track data stream
; a4 = channel block
; Equivalent of .l03f9h in sub_03d1h
; =============================================================================

snd_read_event:
    ; Load 32-bit stream pointer from channel block
    ; Stored as longword at CH_PTR_LO ($0B) — 4 bytes
    move.l  (CH_PTR_LO,a4),a5      ; a5 = track stream pointer (full 32-bit)

    move.b  (a5)+,d0            ; read event byte, advance pointer

    ; Dispatch by value range
    tst.b   d0
    bpl     snd_note_event      ; bit 7=0 → note byte ($00-$7F)

    ; Command byte
    btst    #6,d0
    beq.b   .range_80_bf        ; bit6=0, bit7=1 → preset ($80-$BF)

    ; $C0-$FF range
    cmp.b   #$D0,d0
    bcs.b   .range_c0_cf        ; $C0-$CF: relative volume
    cmp.b   #$D8,d0
    bcs.b   .range_d0_d7        ; $D0-$D7: set octave
    cmp.b   #$E0,d0
    bcs.b   .range_d8_df        ; $D8-$DF: portamento speed
    bra     snd_extended_cmd    ; $E0-$FF: extended commands

.range_80_bf:
    move.b  d0,d2
    and.b   #$3F,d2             ; preset index bits 5-0
    bsr     snd_save_stream_ptr
    bra     snd_load_preset

.range_c0_cf:
    bsr     snd_save_stream_ptr
    bra     snd_rel_volume

.range_d0_d7:
    and.b   #$07,d0             ; octave in bits 2-0
    move.b  d0,(CH_OCTAVE,a4)
    bra     snd_save_stream_ptr

.range_d8_df:
    move.b  (a5)+,d0            ; read second byte
    bsr     snd_duration_lookup
    move.b  d0,(CH_PORT_THRESH,a4)
    bra     snd_save_stream_ptr


; =============================================================================
; snd_save_stream_ptr
; Save current a5 stream pointer back to channel block
; =============================================================================

snd_save_stream_ptr:
    move.l  a5,(CH_PTR_LO,a4)  ; store full 32-bit pointer as longword
    rts


; =============================================================================
; snd_note_event
; Handle note byte (bit 7 = 0)
; d0.b = note byte: bits 7-4=duration index, bits 3-0=pitch
; a4 = channel block, a5 = stream pointer (after event byte)
; Equivalent of l068eh
; =============================================================================

snd_note_event:
    move.b  d0,d2               ; save full note byte

    ; Check for sustain modifier ($E7 following this note)
    bclr    #4,(CH_ENV_FLAGS,a4)
    cmp.b   #$E7,(a5)
    bne.b   .no_sustain
    bset    #4,(CH_ENV_FLAGS,a4)
.no_sustain:

    ; Get duration from upper nibble
    move.b  d2,d0
    lsr.b   #4,d0
    bsr     snd_duration_lookup
    move.b  d0,(CH_DURATION,a4)

    ; Get pitch from lower nibble
    move.b  d2,d0
    and.b   #$0F,d0

    ; Rest (pitch 0) — set duration only, apply effects
    beq.b   .rest

    ; NOP note (pitch $0F) — do nothing
    cmp.b   #$0F,d0
    beq     snd_save_stream_ptr

    ; Calculate and write frequency
    bsr     snd_calc_frequency  ; result in CH_FREQ_LO/HI

    ; Check retrigger suppress (ix+$19 bit 5)
    move.b  (CH_ENV_FLAGS,a4),d1
    bclr    #5,d1               ; test and clear
    move.b  d1,(CH_ENV_FLAGS,a4)
    btst    #5,d1
    bne.b   .skip_retrigger     ; suppressed — keep playing

    ; Initialise vibrato state
    move.b  (CH_VIB_PARAMS,a4),(CH_NOTE_REG,a4)
    clr.b   (CH_VIB_DELTA_LO,a4)
    clr.b   (CH_VIB_DELTA_HI,a4)
    move.b  #$80,(CH_VIB_ACCUM,a4)

    ; Write frequency to hardware
    bsr     snd_write_frequency

    ; Key on
    bsr     snd_key_on

.skip_retrigger:
    bclr    #1,(CH_ENV_FLAGS,a4)
    bset    #0,(CH_ENV_FLAGS,a4) ; mark note playing
    bra     snd_save_stream_ptr

.rest:
    bsr     snd_apply_effects
    bra     snd_save_stream_ptr


; =============================================================================
; snd_calc_frequency
; Calculate OPM KeyCode/KeyFraction or MIDI note from pitch + octave
; d0.b = pitch index (1-14, lower nibble of note byte)
; a4 = channel block
; Result stored in CH_FREQ_LO (KeyCode or MIDI note) and CH_FREQ_HI (KF)
; Equivalent of sub_07dbh FM path
;
; MD frequency table → OPM conversion:
;   MD stores: ix+$22 byte, F-number low, F-number high (with block/octave)
;   OPM uses:  KeyCode = (octave<<4)|note_nibble, KeyFraction (6 bits)
;   We use the pitch index to look up the OPM note nibble directly
;   The ix+$22 value is preserved in CH_FREQ_BYTE for arpeggio/vibrato
;   The octave from CH_OCTAVE is combined with the base block from the table
; =============================================================================

snd_calc_frequency:
    ; Check MIDI/PSG channel
    btst    #5,(CH_CONFIG,a4)
    bne     .snd_calc_midi_freq

    ; --- OPM/FM path ---
    ; Equivalent of sub_07dbh FM path:
    ;   dec a / ld b,a / add a,a / add a,b → a = (pitch-1) * 3
    ;   add a,$19 → index into FM freq table
    subq.b  #1,d0               ; base-0 pitch index (0-13)
    move.b  d0,d1
    add.b   d0,d0
    add.b   d1,d0               ; d0 = pitch_index * 3
    lea     md_fm_freq_table,a0
    adda.w  d0,a0               ; a0 = table entry for this pitch

    ; Read and store ix+$22 equivalent (CH_FREQ_BYTE)
    move.b  (a0)+,d1
    move.b  d1,(CH_FREQ_BYTE,a4)

    ; Read F-number low and high from table
    move.b  (a0)+,d2            ; F-number low byte
    move.b  (a0)+,d3            ; F-number high byte (block in bits 7-5)

    ; Apply signed fine-tune to F-number
    ; sub_07dbh: ld e,(ix+$07) / rla / sbc a,a / ld d,a → sign extend
    ;            add hl,de → add signed fine-tune to F-number word
    move.b  (CH_FINETUNE,a4),d4
    ext.w   d4                  ; sign extend to 16-bit
    move.w  d2,d5
    lsl.w   #8,d5               ; d5 = F-number as 16-bit (hi in upper, lo in lower)
    ; Actually F-num is 11-bit across two bytes — build as word
    ; F-hi bits 4-0 = F-num high 5 bits, F-lo = F-num low 8 bits
    ; F-num word = ((F-hi & $1F) << 8) | F-lo ... but stored reversed
    ; From sub_07dbh: ld l,a (first byte after ix+$22) / inc hl / ld h,(hl) / ld l,a
    ; So: l = table[1] = F-lo, h = table[2] = F-hi → hl = F-hi:F-lo as 16-bit
    move.w  d3,d5
    lsl.w   #8,d5
    or.w    d2,d5               ; d5 = F-hi:F-lo (same as Z80 hl)
    add.w   d4,d5               ; apply fine-tune

    ; Apply octave: sub_07dbh: ld a,(ix+$09) / add a,a*3 / or h → merge octave into F-hi
    move.b  (CH_OCTAVE,a4),d3
    lsl.b   #3,d3               ; octave << 3
    move.b  d5,d2               ; F-hi (upper byte of d5)
    lsr.w   #8,d5               ; d5.b = F-hi
    or.b    d3,d5               ; merge octave bits into F-hi
    ; d5.b = final [block][F-hi] byte (ix+$03 equivalent)
    ; d2 = F-lo byte (ix+$02 equivalent)

    ; Now convert YM2612 block/F-number → OPM KeyCode/KeyFraction
    ; Block (bits 7-5 of ix+$03) = octave base
    ; F-number determines semitone within octave
    ; Use pitch index + octave for KeyCode (cleaner than deriving from F-number)
    move.b  (CH_OCTAVE,a4),d3
    and.b   #$07,d3             ; octave 0-7

    ; Look up OPM note nibble from pitch index
    ; Pitch index is in d0 / 3 (recover original pitch)
    ; Easier: use the CH_FREQ_BYTE to find note — it encodes the base pitch
    ; For now use opm_note_table with original pitch index
    ; Recover pitch index: we divided and multiplied above, save it earlier next time
    ; Use CH_FREQ_BYTE value: $24=C, $26=C#, $28=D etc. → map to OPM nibble
    move.b  (CH_FREQ_BYTE,a4),d0
    bsr     freq_byte_to_opm_note   ; converts $24/$26 etc → OPM note nibble in d0.b

    ; Build KeyCode: (octave << 4) | note_nibble
    move.b  d3,d1
    lsl.b   #4,d1
    or.b    d0,d1
    move.b  d1,(CH_FREQ_LO,a4)  ; KeyCode

    ; Build KeyFraction from fine-tune
    move.b  (CH_FINETUNE,a4),d0
    ext.w   d0
    lsr.w   #2,d0               ; scale
    add.b   #$80,d0             ; centre
    and.b   #$FC,d0             ; bits 7-2 only
    move.b  d0,(CH_FREQ_HI,a4)  ; KeyFraction
    rts

.snd_calc_midi_freq:
    rts
; =============================================================================
; freq_byte_to_opm_note
; Convert MD frequency table ix+$22 byte to OPM note nibble
; The ix+$22 values from md_fm_freq_table are: $24,$26,$28,$2a,$2d,$30,$33,
;   $36,$39,$3c,$40,$44,$cb,$c0 (14 notes)
; These map to OPM note nibbles: C=0,C#=1,D=2,D#=4,E=5,F=6,F#=8,G=9,
;   G#=10,A=12,A#=13,B=14
; d0.b = ix+$22 value
; Returns: d0.b = OPM note nibble
; =============================================================================

freq_byte_to_opm_note:
    lea     .freq_byte_table,a0
    moveq   #13,d1              ; 14 entries
.search:
    cmp.b   (a0)+,d0
    beq.b   .found
    addq.l  #1,a0               ; skip OPM nibble
    dbf     d1,.search
    ; Not found — default to C
    clr.b   d0
    rts
.found:
    move.b  (a0),d0             ; OPM note nibble
    rts

; Table: pairs of [ix+$22 value, OPM note nibble]
.freq_byte_table:
    dc.b    $24,$00     ; C
    dc.b    $26,$01     ; C#
    dc.b    $28,$02     ; D
    dc.b    $2a,$04     ; D#
    dc.b    $2d,$05     ; E
    dc.b    $30,$06     ; F
    dc.b    $33,$08     ; F#
    dc.b    $36,$09     ; G
    dc.b    $39,$0A     ; G#
    dc.b    $3c,$0C     ; A
    dc.b    $40,$0D     ; A#
    dc.b    $44,$0E     ; B
    dc.b    $cb,$00     ; note 13 (verify)
    dc.b    $c0,$00     ; note 14 (verify)
    ; --- MIDI/PSG path ---
    subq.b  #1,d0               ; base-0 (0-13)

    ; Look up chromatic semitone offset
    lea     midi_note_offset,a0
    moveq   #0,d1
    move.b  (a0,d0.w),d1

    ; MIDI note = (octave + 1) * 12 + semitone_offset
    ; Octave 0-7 + offset gives MIDI notes 12-107 (C1-B7)
    move.b  (CH_OCTAVE,a4),d2
    addq.b  #1,d2
    mulu.w  #12,d2
    add.b   d1,d2
    move.b  d2,(CH_FREQ_LO,a4)
    clr.b   (CH_FREQ_HI,a4)
    rts


; =============================================================================
; snd_write_frequency
; Write calculated frequency to OPM or prepare MIDI note
; a4 = channel block
; Equivalent of l0833h (FM path only — PSG path dropped)
; Write order: KeyCode first ($28+ch), then KeyFraction ($30+ch)
; This mirrors the YM2612 requirement of writing $A4 before $A0
; =============================================================================

snd_write_frequency:
    ; Check disable flag
    tst.b   (CH_DISABLE,a4)
    bne     .wf_done

    ; Check MIDI channel
    btst    #5,(CH_CONFIG,a4)
    bne     .wf_done            ; MIDI: note stored in CH_FREQ_LO, sent at key-on

    ; --- OPM path ---
    move.b  (CH_CONFIG,a4),d2
    and.b   #$07,d2             ; OPM channel 0-7

    ; Apply vibrato delta to KeyFraction
    move.b  (CH_FREQ_HI,a4),d1  ; base KeyFraction
    add.b   (CH_VIB_DELTA_LO,a4),d1 ; + vibrato delta
    and.b   #$FC,d1             ; keep bits 7-2 only

    ; Write KeyCode first ($28+ch) — equivalent of writing $A4 on YM2612
    move.b  d2,d0
    add.b   #OPM_KC,d0          ; register $28 + channel
    move.b  (CH_FREQ_LO,a4),d1  ; KeyCode (octave+note, no vibrato on KC)
    bsr     write_opm

    ; Write KeyFraction second ($30+ch) — equivalent of writing $A0 on YM2612
    move.b  d2,d0
    add.b   #OPM_KF,d0          ; register $30 + channel
    move.b  (CH_FREQ_HI,a4),d1
    add.b   (CH_VIB_DELTA_LO,a4),d1
    and.b   #$FC,d1
    bsr     write_opm

    ; Write panning/LFO ($20+ch) — equivalent of $B4+ch on YM2612
    move.b  d2,d0
    add.b   #OPM_RL_FB_CON,d0
    move.b  (CH_LFO_DEPTH,a4),d1 ; contains algorithm + LFO depth
    or.b    #$C0,d1              ; ensure L+R output always set
    bsr     write_opm

.wf_done:
    rts


; =============================================================================
; snd_key_on
; Trigger note-on for FM or MIDI channel
; a4 = channel block
; Equivalent of sub_075ah → key-on register write
; OPM key-on uses register $08:
;   bits 6-3: operator mask (C2=6, M2=5, C1=4, M1=3)
;   bits 2-0: channel 0-7
; YM2612 → OPM operator mask: right-shift by 1
;   YM2612 $28: C2=7, M2=6, C1=5, M1=4 → OPM: C2=6, M2=5, C1=4, M1=3
; =============================================================================

snd_key_on:
    tst.b   (CH_DISABLE,a4)
    bne     .kon_done

    btst    #5,(CH_CONFIG,a4)
    bne     snd_midi_key_on

    ; --- OPM key-on ---
    move.b  (CH_CONFIG,a4),d0
    and.b   #$07,d0             ; channel 0-7

    ; Get operator mask from instrument data
    ; Default = all operators = OPM_KON_ALL ($78)
    ; The instrument loader patches this from the preset operator mask
    ; For now use all-operators default
    move.b  #OPM_KON_ALL,d1
    or.b    d0,d1               ; merge channel

    move.b  #OPM_KON,d0
    bsr     write_opm

.kon_done:
    rts

snd_midi_key_on:
    movem.l a2,-(SP)
    ; Get MIDI PSG channel index (0-2 from channel number 6-8)
    move.b  (CH_CONFIG,a4),d0
    and.b   #$07,d0
    sub.b   #FM_MUSIC_COUNT,d0  ; 6-8 → 0-2

    ; Send note-off for previous note if playing
    lea     (snd_midi_notes),a2
    move.b  (a2,d0.w),d1
    beq.b   .no_prev
    bsr     midi_note_off
.no_prev:

    ; Convert volume (TL style 0=loud, $7F=silent) to MIDI velocity
    move.b  (CH_VOLUME,a4),d2
    not.b   d2                  ; invert
    lsr.b   #1,d2               ; scale $FF→$7F to $7F→$40 range
    and.b   #$7F,d2

    ; Store note and send note-on
    move.b  (CH_FREQ_LO,a4),d1
    move.b  d1,(a2,d0.w)
    bsr     midi_note_on
    movem.l (SP)+,a2    
    rts


; =============================================================================
; snd_key_off
; Trigger note-off for FM or MIDI channel
; a4 = channel block
; Equivalent of the key-off write in sub_087ch (FM path)
; =============================================================================

snd_key_off:
    btst    #5,(CH_CONFIG,a4)
    bne     snd_midi_key_off

    ; OPM key-off: write channel with no operator bits = all operators off
    move.b  (CH_CONFIG,a4),d0
    and.b   #$07,d0             ; channel only
    move.b  d0,d1               ; data = channel, operator bits all 0 = key-off
    move.b  #OPM_KON,d0
    bsr     write_opm
    rts

snd_midi_key_off:
    movem.l a2,-(SP)
    lea     (snd_midi_notes),a2
    move.b  (CH_CONFIG,a4),d0
    and.b   #$07,d0
    sub.b   #FM_MUSIC_COUNT,d0
    move.b  (a2,d0.w),d1
    beq.b   .koff_done
    bsr     midi_note_off
    clr.b   (a2,d0.w)
.koff_done:
    rts


; =============================================================================
; snd_write_tl_opm
; Write total level (volume) to all 4 OPM operators for one FM channel
; Applies volume only to carrier operators — modulators unchanged
; Equivalent of sub_1061h
;
; a4 = channel block
; a2 = pointer to 4 TL bytes in preset data (M1, M2, C1, C2)
; d4.b = combined volume offset (global + channel, already calculated)
;        = (snd_vol_accum >> 1) + CH_VOLUME, clamped $7F
;
; OPM operator slot = (op_index * 8) + channel
; op_index: 0=M1, 1=M2, 2=C1, 3=C2
; Step between operators is $08 on OPM (vs $04 on YM2612)
;
; Carrier mask lookup — which operators carry output (algorithm-dependent)
; Only carriers receive the volume offset to preserve timbre during fade
; Equivalent of the 'd' register bit mask in sub_1061h
; =============================================================================

snd_write_tl_opm:
    ; Get OPM channel number
    move.b  (CH_CONFIG,a4),d5
    and.b   #$07,d5

    ; Get algorithm from cached value in CH_MIDI_MIXER bits 2-0
    move.b  (CH_MIDI_MIXER,a4),d1
    and.b   #$07,d1             ; algorithm 0-7

    ; Load carrier mask for this algorithm
    lea     opm_carrier_mask,a0
    move.b  (a0,d1.w),d3        ; d3 = carrier mask bits 3-0

    ; Write 4 operators
    moveq   #3,d7               ; loop counter (4 operators)
    moveq   #0,d6               ; operator index 0-3

.tl_loop:
    ; Slot = (op_index * 8) + channel
    move.b  d6,d0
    lsl.b   #3,d0               ; op_index * 8
    add.b   d5,d0               ; + channel
    add.b   #OPM_TL,d0          ; + $60 = TL register address

    ; Read base TL from preset data
    move.b  (a2)+,d1            ; TL value for this operator

    ; Check if carrier (bit in d3, MSB first via shift)
    lsl.b   #1,d3               ; shift MSB into carry
    bcc.b   .modulator          ; carry=0 → modulator, use TL unchanged

    ; Carrier: apply combined volume offset
    ; sub_1061h: add e (volume) to TL, clamp to $7F
    add.b   d4,d1
    bpl.b   .tl_write
    move.b  #$7F,d1             ; clamp at max attenuation
    ;bra.b   .tl_write

.modulator:
    ; Modulator: TL unchanged — timbre preserved during fade

.tl_write:
    and.b   #$7F,d1             ; ensure 7-bit TL value
    bsr     write_opm_ch        ; write with disable check

    addq.b  #1,d6
    dbf     d7,.tl_loop
    rts


; =============================================================================
; snd_calc_combined_volume
; Calculate combined volume: (global_vol >> 1) + channel_vol, clamped $7F
; Equivalent of sub_08afh volume calculation
; a4 = channel block
; Returns: d4.b = combined TL offset
; =============================================================================

snd_calc_combined_volume:
    move.b  (snd_vol_accum),d4
    lsr.b   #1,d4               ; global >> 1 (half resolution for smooth fade)
    add.b   (CH_VOLUME,a4),d4   ; + channel volume
    cmp.b   #$7F,d4
    bls.b   .vol_ok
    move.b  #$7F,d4
.vol_ok:
    rts


; =============================================================================
; snd_load_preset_ptr
; Load IY equivalent — get preset data pointer into a3
; Equivalent of load_iy_index (formerly sub_0b3fh)
; Reads MUSIC_PRESET_LO/HI from music channel block into a3
; a4 = music channel block (MUSIC_CH_BASE)
; Returns: a3 = pointer to current preset data
; =============================================================================

snd_load_preset_ptr:
    moveq   #0,d0
    move.b  (MUSIC_PRESET_HI,a4),d0
    lsl.l   #8,d0
    move.b  (MUSIC_PRESET_LO,a4),d0
    movea.l d0,a3               ; a3 = preset data pointer (IY equivalent)
    rts


; =============================================================================
; snd_write_fm_patch
; Write complete FM patch (all operators) to OPM registers
; a4 = channel block
; a3 = pointer to preset/patch data
;
; Patch data format (from Z80 instrument table, 29 bytes per patch):
;   Based on sub_0d1eh copying to channel block and sub_1061h reading iy+$04
;   TL data is at preset_base + $0C (after sub_08afh adds 8 to IY then reads +$04)
;
; YM2612 → YM2151 register mapping:
;   YM2612 $30+: DT/MUL  → OPM $40+: DT1/MUL   (format compatible)
;   YM2612 $40+: TL      → OPM $60+: TL         (7-bit, same meaning)
;   YM2612 $50+: RS/AR   → OPM $80+: KS/AR      (compatible)
;   YM2612 $60+: AM/DR   → OPM $A0+: AMS-EN/D1R (bit 7 meaning differs)
;   YM2612 $70+: SR      → OPM $C0+: DT2/D2R    (DT2 bits 7-6, set 0)
;   YM2612 $80+: SL/RR   → OPM $E0+: D1L/RR     (compatible)
;   YM2612 $90+: SSG-EG  → no OPM equivalent     (omit)
;   YM2612 $B0+: FB/ALG  → OPM $20+: RL/FB/CON  (add pan bits L+R)
;
; Operator order in patch data: M1, M2, C1, C2 (4 operators)
; Each operator: 6 bytes (DT/MUL, TL, KS/AR, AM/DR, DT2/SR, SL/RR)
; FB/ALG: 1 byte after all operators
; Total: 4*6 + 1 = 25 bytes minimum (adjust based on actual patch table format)
; =============================================================================

snd_write_fm_patch:
    ; Get channel number
    move.b  (CH_CONFIG,a4),d5
    and.b   #$07,d5

    ; Calculate combined volume for TL writes
    bsr     snd_calc_combined_volume    ; result in d4.b

    ; Cache algorithm for carrier mask (at FB/ALG offset in patch)
    ; Read FB/ALG byte (last byte of patch, at offset 24)
    move.b  (24,a3),d0
    and.b   #$07,d0             ; algorithm bits 2-0
    move.b  (CH_MIDI_MIXER,a4),d1
    and.b   #$F8,d1
    or.b    d0,d1
    move.b  d1,(CH_MIDI_MIXER,a4) ; cache algorithm in CH_MIDI_MIXER

    ; Write 4 operators
    moveq   #3,d7               ; 4 operators
    moveq   #0,d6               ; operator index 0=M1,1=M2,2=C1,3=C2
    movea.l a3,a2               ; a2 = patch data pointer

.patch_op_loop:
    ; Slot address = (op_index * 8) + channel
    move.b  d6,d0
    lsl.b   #3,d0
    add.b   d5,d0

    ; --- DT1/MUL → OPM $40+slot ---
    move.b  d0,d3
    add.b   #OPM_DT1_MUL,d3
    move.b  d3,d0
    move.b  (a2)+,d1            ; DT/MUL byte from patch
    bsr     write_opm_ch

    ; --- TL → OPM $60+slot ---
    ; TL handled separately with carrier/volume logic
    move.b  d6,d0
    lsl.b   #3,d0
    add.b   d5,d0
    add.b   #OPM_TL,d0
    move.b  (a2)+,d1            ; base TL from patch
    ; Apply volume to carriers (check carrier mask)
    lea     opm_carrier_mask,a0
    move.b  (CH_MIDI_MIXER,a4),d2
    and.b   #$07,d2
    move.b  (a0,d2.w),d2        ; carrier mask
    ; Shift mask to check current operator
    move.w  d6,d3
    lsl.b   d3,d2               ; shift left by op_index puts op bit at MSB area
    ; Bit 3 of carrier mask is M1 (op 0), check (3-op_index) bit
    move.b  #3,d3
    sub.b   d6,d3               ; 3,2,1,0 for ops 0,1,2,3
    btst    d3,d2               ; test carrier bit for this operator
    beq.b   .tl_modulator       ; not a carrier
    add.b   d4,d1               ; apply combined volume
    bpl.b   .tl_ok
    move.b  #$7F,d1
.tl_ok:
.tl_modulator:
    and.b   #$7F,d1
    bsr     write_opm_ch

    ; --- KS/AR → OPM $80+slot ---
    move.b  d6,d0
    lsl.b   #3,d0
    add.b   d5,d0
    add.b   #OPM_KS_AR,d0
    move.b  (a2)+,d1
    bsr     write_opm_ch

    ; --- AMS-EN/D1R → OPM $A0+slot ---
    ; YM2612 AM/DR: bit 7=AM enable, bits 4-0=DR
    ; OPM AMS-EN/D1R: bit 7=AMS enable, bits 4-0=D1R — compatible
    move.b  d6,d0
    lsl.b   #3,d0
    add.b   d5,d0
    add.b   #OPM_AMS_D1R,d0
    move.b  (a2)+,d1
    bsr     write_opm_ch

    ; --- DT2/D2R → OPM $C0+slot ---
    ; YM2612 SR maps to OPM D2R (bits 4-0)
    ; OPM DT2 (bits 7-6): set to 0 (no DT2 detuning)
    move.b  d6,d0
    lsl.b   #3,d0
    add.b   d5,d0
    add.b   #OPM_DT2_D2R,d0
    move.b  (a2)+,d1
    and.b   #$1F,d1             ; keep only D2R bits 4-0, DT2=0
    bsr     write_opm_ch

    ; --- D1L/RR → OPM $E0+slot ---
    ; YM2612 SL/RR compatible with OPM D1L/RR
    move.b  d6,d0
    lsl.b   #3,d0
    add.b   d5,d0
    add.b   #OPM_D1L_RR,d0
    move.b  (a2)+,d1
    bsr     write_opm_ch

    addq.b  #1,d6
    dbf     d7,.patch_op_loop

    ; --- FB/ALG → OPM $20+channel ---
    ; YM2612 $B0: bits 5-3=feedback, bits 2-0=algorithm
    ; OPM $20:   bits 5-3=feedback, bits 2-0=algorithm (compatible)
    ; Add panning bits 7-6 (L+R = $C0)
    move.b  d5,d0
    add.b   #OPM_RL_FB_CON,d0
    move.b  (a2)+,d1            ; FB/ALG byte
    and.b   #$3F,d1             ; keep FB+ALG only
    or.b    #$C0,d1             ; add L+R output enable
    bsr     write_opm_ch

    ; Re-enable channel (clear disable flag — equivalent of sub_0d63h finale)
    clr.b   (CH_DISABLE,a4)
    rts


; =============================================================================
; snd_apply_effects
; Per-tick effect updates: vibrato, portamento, arpeggio
; a4 = channel block
; Equivalent of l0878h onwards
; =============================================================================

snd_apply_effects:
    ; Vibrato
    btst    #6,(CH_FLAGS,a4)
    beq.b   .no_vib

    ; Advance vibrato accumulator
    move.b  (CH_VIB_ACCUM,a4),d0
    add.b   (CH_VIB_DELTA_LO,a4),d0
    move.b  d0,(CH_VIB_ACCUM,a4)
    bsr     snd_write_frequency     ; rewrite with updated delta

.no_vib:
    ; Portamento
    btst    #1,(CH_FLAGS,a4)
    beq.b   .no_port
    bsr     snd_apply_portamento

.no_port:
    ; Arpeggio
    btst    #3,(CH_FLAGS,a4)
    beq.b   .no_arp
    bsr     snd_apply_arpeggio

.no_arp:
    rts


; =============================================================================
; snd_apply_portamento
; Slide pitch toward target each tick
; a4 = channel block
; Equivalent of portamento section in Z80 driver
; =============================================================================

snd_apply_portamento:
    ; Only FM channels have portamento
    btst    #5,(CH_CONFIG,a4)
    bne     .port_done

    ; Advance toward target KeyFraction
    move.b  (CH_FREQ_HI,a4),d0  ; current KF
    move.b  (CH_PORT_TARGET,a4),d1 ; target

    btst    #7,d1               ; bit 7 = direction flag (set by $EC command)
    beq.b   .port_down

    ; Sliding up
    add.b   (CH_PORT_SPEED,a4),d0
    cmp.b   d1,d0
    bcs.b   .port_write
    move.b  d1,d0               ; reached target
    bclr    #1,(CH_FLAGS,a4)    ; disable portamento
    bra.b   .port_write

.port_down:
    sub.b   (CH_PORT_SPEED,a4),d0
    cmp.b   d1,d0
    bcc.b   .port_write
    move.b  d1,d0
    bclr    #1,(CH_FLAGS,a4)

.port_write:
    move.b  d0,(CH_FREQ_HI,a4)
    bsr     snd_write_frequency

.port_done:
    rts


; =============================================================================
; snd_apply_arpeggio
; Step through arpeggio pattern
; a4 = channel block
; =============================================================================

snd_apply_arpeggio:
    subq.b  #1,(CH_ARP_COUNTER,a4)
    bne.b   .arp_done

    ; Reload counter
    move.b  (CH_ARP_CTR_INIT,a4),(CH_ARP_COUNTER,a4)

    ; Toggle step
    btst    #4,(CH_FLAGS,a4)
    bne.b   .arp_step2

    move.b  (CH_ARP_S1_LO,a4),(CH_FREQ_HI,a4)
    bset    #4,(CH_FLAGS,a4)
    bra.b   .arp_write

.arp_step2:
    move.b  (CH_ARP_S2_LO,a4),(CH_FREQ_HI,a4)
    bclr    #4,(CH_FLAGS,a4)

.arp_write:
    bsr     snd_write_frequency

.arp_done:
    rts


; =============================================================================
; snd_fade_tick
; Process one fade step per tempo tick
; Equivalent of sub_039ah
; =============================================================================

snd_fade_tick:
    tst.b   (snd_fade_flag)
    beq     .fd_done

    ; Accumulate fade rate
    move.b  (snd_fade_speed),d0
    add.b   d0,(snd_fade_accum)
    bcc     .fd_done            ; no overflow — not time for step yet

    ; Apply fade step: use snd_ch_count as step size (mirrors $0007 usage)
    move.b  (snd_ch_count),d0
    and.b   #$7F,d0             ; 7-bit step
    add.b   d0,(snd_vol_accum)

    ; Check if fully faded (overflow = silent)
    tst.b   (snd_vol_accum)
    bpl     .fd_done

    ; Fade complete — silence and reset
    clr.b   (snd_fade_speed)
    move.b  #$3F,(snd_status)   ; return to idle
    bsr     snd_silence_all
    move.b  #$FF,(snd_vol_accum)
    clr.b   (snd_fade_flag)

.fd_done:
    rts


; =============================================================================
; snd_apply_fade_volume
; Apply current global volume offset to all active FM channels
; Equivalent of l08cch (the fake-return-address fade handler)
; =============================================================================

snd_apply_fade_volume:
    lea     (snd_music_ch),a4
    moveq   #FM_MUSIC_COUNT-1,d7
.fv_loop:
    btst    #0,(CH_FLAGS,a4)    ; skip inactive
    bne.b   .fv_next
    bsr     snd_calc_combined_volume ; d4 = combined TL
    bsr     snd_load_preset_ptr      ; a3 = preset data
    ; Point a2 to TL data in preset (at offset $0C = after 8-byte header + $04)
    lea     ($0C,a3),a2
    bsr     snd_write_tl_opm
.fv_next:
    lea     (MUSIC_CH_SIZE,a4),a4
    dbf     d7,.fv_loop
    rts


; =============================================================================
; snd_silence_all
; Key-off all OPM channels and send MIDI note-offs
; =============================================================================

snd_silence_all:
    movem.l a2,-(SP)
    lea     (snd_midi_notes),a2
    move.b  #OPM_KON,d0
    moveq   #7,d7
    moveq   #0,d1
.sil_opm:
    bsr     write_opm           ; channel N, no operator bits = key-off
    addq.b  #1,d1
    dbf     d7,.sil_opm
    tst.b   midi_present
    beq.b   .exit
    moveq   #MIDI_MUSIC_COUNT-1,d7
    moveq   #0,d0
.sil_midi:
    move.b  (a2,d0.w),d1
    beq.b   .sil_next
    bsr     midi_note_off
    clr.b   (a2,d0.w)
.sil_next:
    addq.b  #1,d0
    dbf     d7,.sil_midi
.exit
    movem.l (SP)+,a2
    rts


; =============================================================================
; snd_load_track
; Load track data and initialise music channel blocks
; Equivalent of sub_0203h
; Called when snd_track is non-zero
; =============================================================================

snd_load_track:
    ; Save channel disable states (save_fm_channel_data_byte_1 equivalent)
    ; Only FM channels (6) are saved — confirmed from sub_0203h
    lea     (snd_music_ch),a0
    lea     (snd_saved_disable),a1
    moveq   #FM_MUSIC_COUNT-1,d7
.save_loop:
    move.b  (CH_DISABLE,a0),(a1)+
    lea     (MUSIC_CH_SIZE,a0),a0
    dbf     d7,.save_loop

    ; sub_01dfh equivalent — reset driver state
    clr.b   (snd_vol_accum)
    clr.b   (snd_fade_flag)
    clr.b   (snd_fade_speed)
    clr.b   (snd_fade_accum)

    ; Clear and reassign all channel blocks
    bsr     snd_clear_all_channels
    bsr     snd_assign_channels

    ; Restore FM channel disable states (restore_fm_channel_data_byte_1 equiv)
    lea     (snd_music_ch),a0
    lea     (snd_saved_disable),a1
    moveq   #FM_MUSIC_COUNT-1,d7
.restore_loop:
    move.b  (a1)+,(CH_DISABLE,a0)
    lea     (MUSIC_CH_SIZE,a0),a0
    dbf     d7,.restore_loop

    ; Resolve track pointer from bank+track index
    ; Formula: table_index = (bank * 16) + (track - 1)
    ; snd_track is 1-based (dec a in sub_0203h makes it base-0 for table lookup)
    moveq   #0,d0
    move.b  (snd_bank),d0
    lsl.w   #4,d0               ; bank * 16 slots
    move.b  (snd_track),d1
    and.w   #$FF,d1
    subq.w  #1,d1               ; base-0 (matches dec a in sub_0203h)
    add.w   d1,d0
    lsl.w   #2,d0               ; * 4 (longword pointer)
    lea     (snd_track_table),a0
    move.l  (a0,d0.w),a5        ; a5 = absolute track data address in RAM
    move.l  a5,(snd_track_ptr)

    ; --- Parse track header (confirmed from sub_0203h) ---
    ; Track header layout (little-endian words in Z80 original,
    ; stored as absolute RAM pointers in our track table conversion):
    ;
    ; word 0:   LFO setting → OPM $18 (LFRQ) + $1B (waveform)
    ; word 1-9: per-channel stream offsets (9 channels: 6 FM + 3 PSG/MIDI)
    ; word 10-13: FM preset table base addresses (4 entries → l139ah+1 area)
    ;
    ; In Z80: offsets are bank-relative, added to $8000 (M68K_MEM_SPACE)
    ; In X68000: snd_track_table already contains absolute pointers,
    ; but the header words are still bank-relative offsets needing base added

    ; Word 0: LFO setting
    ; Z80: write (iy+$01) to YM2612 reg $22 (LFO enable/freq)
    ; X68000: map to OPM registers $18 (LFRQ) and $1B (CT/waveform)
    move.w  (a5)+,d0            ; read LFO word (little-endian)
    ; Low byte → OPM LFRQ ($18)
    move.b  d0,d1
    move.b  #OPM_LFRQ,d0
    bsr     write_opm
    ; High byte → OPM CT/waveform ($1B) if non-zero
    lsr.w   #8,d0               ; get high byte
    beq.b   .no_lfo_wave
    move.b  d0,d1
    move.b  #OPM_CT_W,d0
    bsr     write_opm
.no_lfo_wave:

    ; Words 1-9: per-channel stream pointers
    ; Z80: each word is offset within bank, added to $8000
    ; X68000: add to track base address (already resolved to RAM)
    lea     (snd_music_ch),a4
    move.l  (snd_track_ptr),a3  ; a3 = bank base for offset resolution
    moveq   #MUSIC_CH_COUNT-1,d7
.ch_init:
    ; Read channel offset word (little-endian)
    move.b  (a5)+,d0            ; low byte
    move.b  (a5)+,d1            ; high byte
    lsl.w   #8,d1
    or.w    d0,d1               ; d1 = offset

    ; Resolve to absolute RAM address: bank_base + offset
    move.l  a3,d0
    ; Strip to bank base (mask to 32KB boundary)
    and.l   #$FFFF8000,d0       ; align to bank start
    and.l   #$00007FFF,d1       ; ensure offset is within bank
    add.l   d1,d0               ; d0 = absolute channel data address

    ; Store as full 32-bit longword pointer at CH_PTR_LO
    move.l  d0,(CH_PTR_LO,a4)

    ; Also set loop pointer to same address (sub_02c0h sets both equal)
    move.l  d0,(CH_LOOP_LO,a4)

    ; Activate channel
    bclr    #0,(CH_FLAGS,a4)
    clr.b   (CH_DISABLE,a4)

    lea     (MUSIC_CH_SIZE,a4),a4
    dbf     d7,.ch_init

    ; Words 10-13: FM preset table base addresses
    ; Z80: stored to l139ah+1 area (4 words = 8 bytes)
    ; X68000: stored to snd_fm_preset_ptr (use first entry as main table)
    ; Read 4 words, resolve addresses, store first as snd_fm_preset_ptr
    moveq   #3,d7
    lea     (snd_fm_preset_ptr),a1
.preset_ptrs:
    move.b  (a5)+,d0
    move.b  (a5)+,d1
    lsl.w   #8,d1
    or.w    d0,d1               ; offset
    move.l  a3,d0
    and.l   #$FFFF8000,d0
    and.l   #$00007FFF,d1
    add.l   d1,d0               ; absolute address
    move.l  d0,(a1)+            ; store pointer
    dbf     d7,.preset_ptrs

    ; --- sub_02e0h equivalent: silence all FM channels ---
    bsr     snd_silence_all_opm

    ; Reset sequencer state (confirmed from sub_0203h)
    clr.b   (snd_status)        ; $00 = playing
    clr.b   (snd_tempo_frac)    ; l1391h+1 = 0
    clr.b   (snd_tempo_ovf)     ; l1391h+2 = 0
    clr.b   (snd_fade_flag)     ; l1394h = 0
    clr.b   (snd_fade_accum)    ; l1396h = 0
    move.b  #$7F,(snd_tempo_base) ; l1391h = $7F (default tempo)

    ; Clear track load request
    clr.b   (snd_track)
    rts


; =============================================================================
; snd_silence_all_opm
; Silence all OPM channels and reset frequency registers
; Equivalent of sub_02e0h (FM portion only — PSG replaced by MIDI silence)
; =============================================================================

snd_silence_all_opm:
    ; Set TL = $7F (max attenuation) for all 32 operator slots
    move.b  #OPM_TL,d0
    move.b  #$7F,d1
    moveq   #31,d7
.tl_loop:
    bsr     write_opm
    addq.b  #1,d0
    dbf     d7,.tl_loop

    ; Reset KeyCode and KeyFraction to 0 for all 8 channels
    move.b  #OPM_KC,d0
    clr.b   d1
    moveq   #7,d7
.kc_loop:
    bsr     write_opm
    addq.b  #1,d0
    dbf     d7,.kc_loop

    move.b  #OPM_KF,d0
    clr.b   d1
    moveq   #7,d7
.kf_loop:
    bsr     write_opm
    addq.b  #1,d0
    dbf     d7,.kf_loop

    ; Key-off all channels
    move.b  #OPM_KON,d0
    moveq   #7,d7
    clr.b   d1
.koff_loop:
    bsr     write_opm
    addq.b  #1,d1
    dbf     d7,.koff_loop

    ; Silence MIDI PSG channels (replaces PSG $9F/$BF/$DF/$FF writes)
    moveq   #MIDI_MUSIC_COUNT-1,d7
    moveq   #MIDI_PSG0,d6
.midi_sil:
    move.b  d6,d0
    move.b  #7,d1               ; CC7 volume
    clr.b   d2
    bsr     midi_send_cc
    addq.b  #1,d6
    dbf     d7,.midi_sil
    rts


; =============================================================================
; snd_extended_cmd
; Handle $E0-$FF music command range
; d0.b = full command byte, a4 = channel block, a5 = stream pointer (post-cmd)
; Second byte already consumed into d1.b for most commands
; Equivalent of l0427h dispatch table in sub_03d1h
; =============================================================================

snd_extended_cmd:
    move.b  (a5)+,d1            ; read second byte
    move.b  d0,d2
    and.b   #$1F,d2             ; lower 5 bits = command index 0-31
    lsl.w   #2,d2               ; * 4 for longword table
    lea     .ext_table,a0
    move.l  (a0,d2.w),a1
    jsr     (a1)
    bra     snd_save_stream_ptr

.ext_table:
    dc.l    .ecmd_E0_tempo      ; $E0 set tempo
    dc.l    .ecmd_E1_finetune   ; $E1 set fine-tune
    dc.l    .ecmd_E2_vibrato    ; $E2 set vibrato
    dc.l    .ecmd_E3_oct_dn     ; $E3 octave down (single byte)
    dc.l    .ecmd_E4_oct_up     ; $E4 octave up (single byte)
    dc.l    .ecmd_E5_volume     ; $E5 set volume
    dc.l    .ecmd_E6_arpeggio   ; $E6 set arpeggio
    dc.l    .ecmd_E7_sustain    ; $E7 sustain on (single byte)
    dc.l    .ecmd_E8_nop        ; $E8 NOP (single byte)
    dc.l    .ecmd_E9_noise      ; $E9 PSG noise → MIDI percussion
    dc.l    .ecmd_EA_mixer      ; $EA PSG mixer → MIDI CC10 pan
    dc.l    .ecmd_EB_port       ; $EB portamento enable/disable
    dc.l    .ecmd_EC_portgt     ; $EC portamento target (3 bytes)
    dc.l    .ecmd_ED_lfo        ; $ED LFO depth high (single byte)
    dc.l    .ecmd_EE_lfo        ; $EE LFO depth mid (single byte)
    dc.l    .ecmd_EF_lfo        ; $EF LFO depth low (single byte)
    ; $F0-$FF: from second dispatch table in original (l0427h beyond index 15)
    ; Extend here as those routines are identified
    dc.l    .ecmd_nop_2b        ; $F0
    dc.l    .ecmd_nop_2b        ; $F1
    dc.l    .ecmd_nop_2b        ; $F2
    dc.l    .ecmd_nop_2b        ; $F3
    dc.l    .ecmd_nop_2b        ; $F4
    dc.l    .ecmd_nop_2b        ; $F5
    dc.l    .ecmd_nop_2b        ; $F6
    dc.l    .ecmd_nop_2b        ; $F7
    dc.l    .ecmd_nop_2b        ; $F8
    dc.l    .ecmd_nop_2b        ; $F9
    dc.l    .ecmd_nop_2b        ; $FA
    dc.l    .ecmd_nop_2b        ; $FB
    dc.l    .ecmd_nop_2b        ; $FC
    dc.l    .ecmd_nop_2b        ; $FD
    dc.l    .ecmd_nop_2b        ; $FE
    dc.l    .ecmd_nop_2b        ; $FF

; --- $E0: set tempo (l04a9h) ---
; a = second_byte + 6, stored as tempo base
.ecmd_E0_tempo:
    add.b   #6,d1
    move.b  d1,(snd_tempo_base)
    rts

; --- $E1: set fine-tune (l04afh) ---
.ecmd_E1_finetune:
    move.b  d1,(CH_FINETUNE,a4)
    rts

; --- $E2: set vibrato (l04b3h) ---
; d1=0 → disable. d1≠0 → enable and copy 6 bytes (d1 + 5 stream bytes)
.ecmd_E2_vibrato:
    bclr    #6,(CH_FLAGS,a4)
    tst.b   d1
    beq.b   .vib_done
    bset    #6,(CH_FLAGS,a4)
    move.b  d1,(CH_VIB_PARAMS,a4)
    lea     (CH_VIB_PARAMS+1,a4),a1
    move.b  (a5)+,(a1)+
    move.b  (a5)+,(a1)+
    move.b  (a5)+,(a1)+
    move.b  (a5)+,(a1)+
    move.b  (a5)+,(a1)+
    bclr    #1,(CH_ENV_FLAGS,a4)
.vib_done:
    rts

; --- $E3: octave down (l04d6h) — single byte, back up stream ---
.ecmd_E3_oct_dn:
    subq.l  #1,a5
    subq.b  #1,(CH_OCTAVE,a4)
    rts

; --- $E4: octave up (l04dbh) — single byte ---
.ecmd_E4_oct_up:
    subq.l  #1,a5
    addq.b  #1,(CH_OCTAVE,a4)
    rts

; --- $E5: set volume (l04e0h / l04e3h) ---
.ecmd_E5_volume:
    move.b  d1,(CH_VOLUME,a4)
    btst    #5,(CH_CONFIG,a4)
    bne.b   .vol_midi
    ; FM: calculate combined volume and write TL
    bsr     snd_calc_combined_volume    ; d4.b = combined TL
    bsr     snd_load_preset_ptr         ; a3 = preset
    lea     ($0C,a3),a2
    bsr     snd_write_tl_opm
    rts
.vol_midi:
    ; MIDI: send CC11 expression
    move.b  (CH_CONFIG,a4),d0
    and.b   #$07,d0
    sub.b   #FM_MUSIC_COUNT,d0  ; MIDI PSG index 0-2
    move.b  d1,d2
    not.b   d2
    lsr.b   #1,d2
    and.b   #$7F,d2             ; convert TL to MIDI velocity
    move.b  #11,d1              ; CC11 expression
    bsr     midi_send_cc
    rts

; --- $E6: set arpeggio (l04edh) ---
; d1=0 → disable. d1≠0 → load 5-byte pattern from arp table
.ecmd_E6_arpeggio:
    bclr    #3,(CH_FLAGS,a4)
    tst.b   d1
    beq.b   .arp_done_cmd
    bset    #3,(CH_FLAGS,a4)
    subq.b  #1,d1               ; base-0 index
    moveq   #0,d0
    move.b  d1,d0
    mulu.w  #5,d0               ; 5 bytes per pattern
    move.l  (snd_arp_table),a0
    adda.l  d0,a0
    lea     (CH_ARP_BASE,a4),a1
    move.b  (a0)+,(a1)+
    move.b  (a0)+,(a1)+
    move.b  (a0)+,(a1)+
    move.b  (a0)+,(a1)+
    move.b  (a0)+,(a1)+
    ; If note playing, recalculate
    btst    #0,(CH_ENV_FLAGS,a4)
    beq.b   .arp_done_cmd
    move.b  (CH_FREQ_LO,a4),d0
    and.b   #$0F,d0             ; extract note nibble
    bsr     snd_calc_frequency
.arp_done_cmd:
    rts

; --- $E7: sustain on (l052ch) — single byte ---
.ecmd_E7_sustain:
    subq.l  #1,a5
    bset    #5,(CH_ENV_FLAGS,a4)
    rts

; --- $E8: NOP (l0530h) — single byte ---
.ecmd_E8_nop:
    subq.l  #1,a5
    rts

; --- $E9: PSG noise → MIDI percussion (l0532h) ---
; Only for MIDI channels (bit 5 of CH_CONFIG)
.ecmd_E9_noise:
    btst    #5,(CH_CONFIG,a4)
    beq.b   .e9_done            ; FM channel — ignore
    ; Map noise parameter to GM drum note
    move.b  d1,d0
    lsr.b   #3,d0
    and.b   #$07,d0
    lea     midi_noise_map,a0
    move.b  (a0,d0.w),d1        ; GM note number
    move.b  #MIDI_PERCUSSION,d0
    move.b  #100,d2             ; velocity
    bsr     midi_note_on
.e9_done:
    rts

; --- $EA: PSG mixer → MIDI CC10 pan (l054ah) ---
.ecmd_EA_mixer:
    btst    #5,(CH_CONFIG,a4)
    beq.b   .ea_done            ; FM — ignore
    move.b  (CH_CONFIG,a4),d0
    and.b   #$07,d0
    sub.b   #FM_MUSIC_COUNT,d0
    ; Convert PSG mixer pan bits to MIDI pan (0/64/127)
    move.b  d1,d2
    and.b   #$C0,d2
    lsr.b   #1,d2               ; rough scale to MIDI range
    move.b  #10,d1              ; CC10 pan
    bsr     midi_send_cc
.ea_done:
    rts

; --- $EB: portamento enable/disable (l056bh) ---
.ecmd_EB_port:
    bclr    #1,(CH_FLAGS,a4)
    tst.b   d1
    beq.b   .eb_done
    btst    #5,(CH_CONFIG,a4)   ; MIDI: ignore portamento
    bne.b   .eb_done
    bset    #1,(CH_FLAGS,a4)
    move.b  d1,(CH_PORT_SPEED,a4)
    move.b  d1,(CH_MIDI_SPEED,a4)
.eb_done:
    rts

; --- $EC: portamento target (sub_0594h) — 3 bytes total ---
.ecmd_EC_portgt:
    btst    #5,(CH_CONFIG,a4)
    bne.b   .ec_midi
    ; FM portamento target
    clr.b   (CH_PORT_TARGET,a4)
    tst.b   d1
    beq.b   .ec_done
    move.b  d1,(CH_PORT_SPEED,a4)
    move.b  (a5)+,d1            ; read third byte
    bset    #7,d1               ; set direction flag
    move.b  d1,(CH_PORT_TARGET,a4)
    btst    #0,(CH_ENV_FLAGS,a4)
    beq.b   .ec_done
    bsr     snd_write_frequency
    bra.b   .ec_done
.ec_midi:
    tst.b   d1
    beq.b   .ec_done
    addq.l  #1,a5               ; skip third byte
.ec_done:
    rts

; --- $ED/$EE/$EF: LFO depth (l05b0h) — single byte ---
.ecmd_ED_lfo:
.ecmd_EE_lfo:
.ecmd_EF_lfo:
    subq.l  #1,a5               ; single byte command
    btst    #5,(CH_CONFIG,a4)
    bne.b   .lfo_midi
    ; FM: extract LFO depth from command bits 7-6, write to OPM $20+ch
    move.b  d0,d1               ; d0 = original command byte
    ;rrca    #2,d1               ; rotate bits 7-6 to bits 5-4... not valid 68k
    ror     #2,d1               ; rotate bits 7-6 to bits 5-4... not valid 68k
    ; Correct approach: command byte is in d0 from snd_extended_cmd
    ; bits 7-6 of the full command byte encode depth
    ; In 68k: use lsr then mask
    move.b  d0,d1
    and.b   #$C0,d1             ; extract bits 7-6
    move.b  (CH_ENV_FLAGS,a4),d2
    and.b   #$3F,d2
    or.b    d1,d2
    move.b  d2,(CH_ENV_FLAGS,a4)
    move.b  d2,(CH_LFO_DEPTH,a4)
    move.b  (CH_CONFIG,a4),d0
    and.b   #$07,d0
    add.b   #OPM_RL_FB_CON,d0
    move.b  (CH_LFO_DEPTH,a4),d1
    or.b    #$C0,d1             ; L+R output
    bsr     write_opm_ch
    rts
.lfo_midi:
    ; MIDI: send CC1 modulation wheel (approximate LFO depth)
    move.b  (CH_CONFIG,a4),d0
    and.b   #$07,d0
    sub.b   #FM_MUSIC_COUNT,d0
    move.b  d0,-(sp)
    move.b  d2,d2               ; reuse d2
    lsr.b   #5,d2               ; scale bits 7-6 to 0/2/4/6 range... approx
    lsl.b   #4,d2               ; → 0/32/64/96 MIDI range
    move.b  (sp)+,d0
    move.b  #1,d1               ; CC1 modulation
    bsr     midi_send_cc
    rts

; --- NOP for unimplemented commands ($F0-$FF, 2-byte) ---
.ecmd_nop_2b:
    rts


; =============================================================================
; snd_load_preset
; Load FM or MIDI preset from preset table ($80-$BF command handler)
; d2.b = preset index (bits 5-0)
; a4 = channel block, a5 = stream pointer
; Equivalent of l05dbh (FM) / l0618h (PSG/MIDI)
; =============================================================================

snd_load_preset:
    btst    #5,(CH_CONFIG,a4)
    bne     .midi_preset

    ; --- FM preset: 36-byte entries ---
    moveq   #0,d0
    move.b  d2,d0
    mulu.w  #INST_CH_SIZE,d0    ; index * 36
    move.l  (snd_fm_preset_ptr),a3
    adda.l  d0,a3               ; a3 = FM preset entry

    ; Store preset pointer in channel block (MUSIC_PRESET_LO/HI)
    move.l  a3,d0
    move.b  d0,(MUSIC_PRESET_LO,a4)
    lsr.l   #8,d0
    move.b  d0,(MUSIC_PRESET_HI,a4)

    ; Load vibrato from preset byte 0
    move.b  (a3)+,d1
    bsr     .load_vib

    ; Skip 6 bytes to portamento data (offset 7 from preset base)
    addq.l  #6,a3

    ; Load portamento target (sub_0594h equivalent)
    move.b  (a3)+,d1
    tst.b   d1
    beq.b   .no_port_preset
    move.b  d1,(CH_PORT_SPEED,a4)
    move.b  (a3)+,d1
    bset    #7,d1
    move.b  d1,(CH_PORT_TARGET,a4)
    bra.b   .port_preset_done
.no_port_preset:
    clr.b   (CH_PORT_TARGET,a4)
    addq.l  #1,a3
.port_preset_done:

    ; Load instrument patch (sub_1022h equivalent)
    addq.l  #1,a3               ; skip one byte
    bsr     snd_write_fm_patch  ; a3 points to patch data

    ; Apply FM parameters (sub_08afh equivalent)
    bsr     snd_calc_combined_volume
    lea     ($0C,a3),a2
    bsr     snd_write_tl_opm
    rts

.midi_preset:
    ; --- MIDI preset: 16-byte entries ---
    moveq   #0,d0
    move.b  d2,d0
    lsl.w   #4,d0               ; index * 16
    move.l  (snd_midi_preset_ptr),a3
    adda.l  d0,a3

    ; Store preset pointer
    move.l  a3,d0
    move.b  d0,(MUSIC_PRESET_LO,a4)
    lsr.l   #8,d0
    move.b  d0,(MUSIC_PRESET_HI,a4)

    ; Load vibrato from byte 0
    move.b  (a3)+,d1
    bsr     .load_vib

    ; Skip to MIDI mixer byte (offset 14 from preset base — mirrors l0618h $0E)
    lea     (13,a3),a3
    move.b  (a3)+,d1
    move.b  d1,(CH_MIDI_MIXER,a4)

    ; Apply MIDI pan from mixer bits 5-4
    move.b  (CH_CONFIG,a4),d0
    and.b   #$07,d0
    sub.b   #FM_MUSIC_COUNT,d0
    move.b  d1,d2
    and.b   #$3F,d2
    lsl.b   #1,d2               ; scale to MIDI pan range
    move.b  #10,d1              ; CC10
    bsr     midi_send_cc
    rts

; Load vibrato from d1 into channel block
; d1=0 → disable, d1≠0 → enable and copy 5 more bytes from preset (a3)
.load_vib:
    bclr    #6,(CH_FLAGS,a4)
    tst.b   d1
    beq.b   .lv_done
    bset    #6,(CH_FLAGS,a4)
    move.b  d1,(CH_VIB_PARAMS,a4)
    lea     (CH_VIB_PARAMS+1,a4),a1
    move.b  (a3)+,(a1)+
    move.b  (a3)+,(a1)+
    move.b  (a3)+,(a1)+
    move.b  (a3)+,(a1)+
    move.b  (a3)+,(a1)+
.lv_done:
    rts


; =============================================================================
; snd_rel_volume
; Relative volume change command ($C0-$CF)
; d0.b = command byte (lower nibble = signed offset -8..+7)
; a4 = channel block
; Equivalent of l0658h
; =============================================================================

snd_rel_volume:
    move.b  (CH_VOLUME,a4),d2   ; current volume
    move.b  d0,d3
    and.b   #$0F,d3             ; lower nibble

    ; Sign-extend 4-bit to 8-bit via shift
    lsl.b   #4,d3
    asr.b   #4,d3               ; signed 4-bit → signed 8-bit

    bpl.b   .rv_pos
    ; Negative offset: increase TL (quieter on FM)
    sub.b   d3,d2               ; d2 = d2 - negative = increase
    bpl.b   .rv_clamp
    clr.b   d2
    bra.b   .rv_clamp
.rv_pos:
    ; Positive offset: decrease TL (louder on FM), with $04 bias (from l0658h)
    add.b   #4,d3
    sub.b   d3,d2
    bpl.b   .rv_clamp
    move.b  #$7F,d2
.rv_clamp:
    move.b  d2,(CH_VOLUME,a4)

    ; Apply to hardware
    btst    #5,(CH_CONFIG,a4)
    bne.b   .rv_midi

    ; FM: write TL
    bsr     snd_calc_combined_volume
    bsr     snd_load_preset_ptr
    lea     ($0C,a3),a2
    bsr     snd_write_tl_opm
    rts

.rv_midi:
    ; MIDI: CC11 expression
    move.b  (CH_CONFIG,a4),d0
    and.b   #$07,d0
    sub.b   #FM_MUSIC_COUNT,d0
    move.b  d2,d3
    not.b   d3
    lsr.b   #1,d3
    and.b   #$7F,d3
    move.b  d3,d2
    move.b  #11,d1
    bsr     midi_send_cc
    rts


; =============================================================================
; snd_duration_lookup
; Convert duration index to tick count
; d0.b = index (0-15, upper nibble of note byte pre-shifted)
; Returns d0.b = tick count
; Equivalent of sub_0b56h
; =============================================================================

snd_duration_lookup:
    lea     snd_duration_table,a0
    and.b   #$0F,d0
    move.b  (a0,d0.w),d0
    rts


; =============================================================================
; Instrument channel system
; Equivalent of l0d97h + sub_0dbeh
; =============================================================================

; snd_inst_tick
; Process all instrument channels — called every timer B interrupt
; Equivalent of l0d97h
snd_inst_tick:
    ; Check for instrument trigger
    tst.b   (snd_instrument)
    beq.b   .no_trigger
    bsr     snd_load_instrument
.no_trigger:

    ; Process all 4 instrument channel blocks
    lea     (snd_inst_ch),a4
    moveq   #INST_CH_COUNT-1,d7
.inst_loop:
    bsr     snd_inst_channel_tick
    lea     (INST_CH_SIZE,a4),a4
    dbf     d7,.inst_loop
    rts


; =============================================================================
; snd_inst_channel_tick
; Process one instrument channel tick
; a4 = instrument channel block (INST_CH_BASE)
; Equivalent of sub_0dbeh
; =============================================================================

snd_inst_channel_tick:
    ; Check active flag (INST_STATUS bit 0)
    btst    #0,(INST_STATUS,a4)
    beq     .ict_done

    ; Advance fractional step accumulator (ix+$1f / ix+$22)
    move.b  (INST_STEP_RATE,a4),d0
    add.b   d0,(INST_FRAC_ACCUM,a4)
    bcc     .ict_done           ; no overflow — skip this tick

    ; Decrement duration counter (ix+$1c)
    subq.b  #1,(INST_DURATION,a4)
    bne.b   .ict_effects        ; not expired → effects only

    ; Duration expired — read next event
    bsr     snd_inst_read_event
    rts

.ict_effects:
    ; Apply pitch update (l0f45h equivalent — vibrato/LFO update)
    bsr     snd_inst_pitch_update

.ict_done:
    rts


; =============================================================================
; snd_inst_read_event
; Read and dispatch next event from instrument channel data
; a4 = instrument channel block
; Equivalent of event dispatch in sub_0dbeh / l0ec8h
; =============================================================================

snd_inst_read_event:
    ; Load 32-bit stream pointer as longword from channel block
    move.l  (CH_PTR_LO,a4),a5

    move.b  (a5)+,d0            ; read event byte
    move.b  d0,d2

    ; Check lower nibble for command vs note
    move.b  d0,d1
    and.b   #$0F,d1
    cmp.b   #$0F,d1
    bne.b   .inst_note          ; lower != $0F → note/duration event

    ; Command: upper nibble = index
    move.b  (a5)+,d1            ; read second byte
    lsr.b   #4,d2               ; upper nibble of original byte = command index
    and.b   #$0F,d2
    lsl.w   #2,d2               ; * 4 for table
    lea     .inst_cmd_table,a0
    move.l  (a0,d2.w),a1
    jsr     (a1)
    bra     .save_inst_ptr

.inst_note:
    ; l0ec8h: note/duration event
    ; Positive byte → use previous duration
    ; Negative byte → fetch new duration from stream
    move.b  (INST_PREV_DUR,a4),d1  ; previous duration
    tst.b   d0
    bpl.b   .use_prev
    move.b  (a5)+,d1               ; fetch new duration
.use_prev:
    move.b  d1,(INST_DURATION,a4)
    move.b  d1,(INST_PREV_DUR,a4)
    ; Note event could trigger key-on here — add when note format confirmed

.save_inst_ptr:
    ; Save updated stream pointer as full 32-bit longword
    move.l  a5,(CH_PTR_LO,a4)
    rts

; Instrument command dispatch table (l00b2h_table equivalent)
.inst_cmd_table:
    dc.l    .ic_set_rate        ; $X0 set step rate
    dc.l    .ic_pan_cmd         ; $X1 panning
    dc.l    .ic_pan_cmd         ; $X2 panning
    dc.l    .ic_pan_cmd         ; $X3 panning
    dc.l    .ic_load_patch      ; $X4 load FM patch (29 bytes)
    dc.l    .ic_set_vol         ; $X5 set volume
    dc.l    .ic_load_vib        ; $X6 load vibrato (5 bytes)
    dc.l    .ic_vib_on          ; $X7 vibrato enable
    dc.l    .ic_vib_off         ; $X8 vibrato disable
    dc.l    .ic_pan_from_reg    ; $X9 set panning from snd_pan
    dc.l    .ic_expr_from_reg   ; $XA set expression from snd_expression
    dc.l    .ic_finetune        ; $XB set fine-tune
    dc.l    .ic_nop             ; $XC NOP (dec hl / ret)
    dc.l    .ic_nop             ; $XD NOP
    dc.l    .ic_nop             ; $XE NOP
    dc.l    .ic_stop            ; $XF stop channel (l0eb4h / sub_0eb5h)

; --- $X0: set step rate (l0e02h) ---
.ic_set_rate:
    move.b  d1,(INST_STEP_RATE,a4)
    rts

; --- $X1/$X2/$X3: panning from command bits (l0e06h) ---
; Panning encoded in upper nibble of command byte × 4, bits 7-6 result
.ic_pan_cmd:
    move.b  d2,d0               ; command byte (upper nibble used)
    ; Original: add a,a / add a,a / and $C0 on full byte
    add.b   d0,d0
    add.b   d0,d0
    and.b   #$C0,d0             ; extract panning bits
    move.b  (INST_STATUS,a4),d1
    and.b   #$3F,d1
    or.b    d0,d1
    move.b  d1,(INST_STATUS,a4)
    ; Write to OPM $20+ch
    move.b  (CH_CONFIG,a4),d0
    and.b   #$03,d0
    add.b   #OPM_RL_FB_CON,d0
    move.b  d1,d1
    or.b    #$C0,d1             ; ensure L+R
    bsr     write_opm
    rts

; --- $X4: load FM patch (l0e22h) ---
; Patch entry = 29 bytes at inst_table + (index * 29)
.ic_load_patch:
    moveq   #0,d0
    move.b  d1,d0
    mulu.w  #29,d0
    move.l  (snd_inst_table),a3
    adda.l  d0,a3
    ; Store loop pointer (instrument patch address)
    move.l  a3,d0
    move.b  d0,(CH_LOOP_LO,a4)
    lsr.l   #8,d0
    move.b  d0,(CH_LOOP_HI,a4)
    ; Write patch to OPM
    bsr     snd_write_fm_patch
    ; Apply volume (sub_0ffdh equivalent)
    bsr     snd_calc_combined_volume
    lea     ($0C,a3),a2
    bsr     snd_write_tl_opm
    rts

; --- $X5: set volume (l0e5ch) ---
.ic_set_vol:
    move.b  d1,(CH_VOLUME,a4)
    bsr     snd_calc_combined_volume
    ; Load patch pointer from CH_LOOP_LO/HI
    moveq   #0,d0
    move.b  (CH_LOOP_HI,a4),d0
    lsl.l   #8,d0
    move.b  (CH_LOOP_LO,a4),d0
    movea.l d0,a3
    lea     ($0C,a3),a2
    bsr     snd_write_tl_opm
    rts

; --- $X6: load vibrato data (l0e62h) ---
; Copy 5 bytes from stream to channel block at +$15
.ic_load_vib:
    bset    #1,(INST_STATUS,a4)
    lea     ($15,a4),a1
    move.b  (a5)+,(a1)+
    move.b  (a5)+,(a1)+
    move.b  (a5)+,(a1)+
    move.b  (a5)+,(a1)+
    move.b  (a5)+,(a1)+
    bclr    #2,(INST_STATUS,a4)
    rts

; --- $X7: vibrato enable (l0e7ch) ---
.ic_vib_on:
    bset    #1,(INST_STATUS,a4)
    rts

; --- $X8: vibrato disable (l0e82h) ---
.ic_vib_off:
    bclr    #1,(INST_STATUS,a4)
    rts

; --- $X9: panning from snd_pan register (l0e88h) ---
.ic_pan_from_reg:
    move.b  (snd_pan),d0
    and.b   #$03,d0
    lsl.b   #6,d0               ; scale bits 1-0 to bits 7-6
    move.b  (INST_STATUS,a4),d1
    and.b   #$3F,d1
    or.b    d0,d1
    move.b  d1,(INST_STATUS,a4)
    move.b  (CH_CONFIG,a4),d0
    and.b   #$03,d0
    add.b   #OPM_RL_FB_CON,d0
    or.b    #$C0,d1
    bsr     write_opm
    rts

; --- $XA: expression from snd_expression (l0ea6h) ---
.ic_expr_from_reg:
    move.b  (snd_expression),(CH_PORT_TARGET,a4)    ; ix+$1e
    rts

; --- $XB: set fine-tune (l0eaeh) ---
.ic_finetune:
    move.b  d1,(CH_FINETUNE,a4)
    rts

; --- $XC/$XD/$XE: NOP (l0eb2h) ---
.ic_nop:
    rts

; --- $XF: stop channel (l0eb4h / sub_0eb5h) ---
.ic_stop:
    bclr    #0,(INST_STATUS,a4)     ; clear active flag
    clr.b   (INST_PRIORITY,a4)      ; clear priority ($23)
    bsr     snd_key_off             ; key-off OPM
    rts


; =============================================================================
; snd_inst_pitch_update
; Per-tick vibrato/LFO update for instrument channels
; Equivalent of l0f45h
; =============================================================================

snd_inst_pitch_update:
    ; Check vibrato enable (INST_STATUS bit 1)
    btst    #1,(INST_STATUS,a4)
    beq.b   .ipu_done

    ; Advance vibrato and update frequency
    move.b  (CH_VIB_ACCUM,a4),d0
    add.b   (CH_VIB_DELTA_LO,a4),d0
    move.b  d0,(CH_VIB_ACCUM,a4)
    bsr     snd_write_frequency

.ipu_done:
    rts


; =============================================================================
; snd_load_instrument
; Trigger instrument across 4 instrument channels
; Equivalent of sub_0cach
; Called when snd_instrument is non-zero
; =============================================================================

snd_load_instrument:
    move.b  (snd_instrument),d2 ; save with bit 7
    clr.b   (snd_instrument)   ; acknowledge

    move.b  d2,d0
    and.b   #$7F,d0             ; strip bit 7 for index

    ; Check for stop-all ($7F)
    cmp.b   #$7F,d0
    beq     snd_stop_all_inst

    ; Calculate table entry (3 bytes per entry: op_mask, addr_lo, addr_hi)
    subq.b  #1,d0               ; base-0 index
    moveq   #0,d1
    move.b  d0,d1
    mulu.w  #3,d1
    move.l  (snd_inst_table),a0
    adda.l  d1,a0               ; a0 = table entry

    ; Read operator mask
    move.b  (a0)+,d3
    btst    #7,d2               ; original bit 7 set?
    beq.b   .mask_ok
    move.b  #$FF,d3             ; override — all operators
.mask_ok:

    ; Resolve instrument data pointer (2-byte offset from table base)
    move.b  (a0)+,d0
    move.b  (a0)+,d1
    lsl.w   #8,d1
    or.w    d0,d1               ; 16-bit offset
    move.l  (snd_inst_table),a0
    movea.w d1,a1
    adda.l  a0,a1               ; a1 = instrument data

    ; Skip first byte (sub-count)
    addq.l  #1,a1

    ; Load 4 instrument channels
    lea     (snd_inst_ch),a4
    moveq   #INST_CH_COUNT-1,d7
.inst_load_loop:
    ; Read 16-bit channel data offset
    move.b  (a1)+,d0
    move.b  (a1)+,d1
    lsl.w   #8,d1
    or.w    d0,d1

    ; Check priority: skip if operator mask < channel priority
    cmp.b   (INST_PRIORITY,a4),d3
    bcs.b   .inst_skip

    ; Resolve channel instrument data
    move.l  (snd_inst_table),a0
    movea.w d1,a2
    adda.l  a0,a2               ; a2 = channel instrument data

    ; Load patch into channel block
    bsr     snd_load_inst_patch
    bset    #0,(INST_STATUS,a4) ; set active

.inst_skip:
    lea     (INST_CH_SIZE,a4),a4
    dbf     d7,.inst_load_loop
    rts

snd_stop_all_inst:
    ; Stop all active instrument channels (l0d80h equivalent)
    lea     (snd_inst_ch),a4
    moveq   #INST_CH_COUNT-1,d7
.stop_loop:
    btst    #0,(INST_STATUS,a4)
    beq.b   .stop_next
    bclr    #0,(INST_STATUS,a4)
    clr.b   (INST_PRIORITY,a4)
    bsr     snd_key_off
.stop_next:
    lea     (INST_CH_SIZE,a4),a4
    dbf     d7,.stop_loop
    rts


; =============================================================================
; snd_load_inst_patch
; Load instrument patch data into channel block and write to OPM
; Equivalent of sub_0d1eh + sub_0d63h
; a4 = instrument channel block
; a2 = instrument patch data pointer
; =============================================================================

snd_load_inst_patch:
    ; Copy patch data into channel block (INST_CH_SIZE bytes)
    movea.l a4,a3
    movea.l a2,a0
    move.w  #INST_CH_SIZE-1,d0
.copy:
    move.b  (a0)+,(a3)+
    dbf     d0,.copy

    ; Channel number was set in snd_assign_channels — preserve it
    ; (sub_0d1eh patched channel number — we do this at assign time instead)

    ; Write FM patch to OPM
    movea.l a2,a3               ; a3 = patch data
    bsr     snd_write_fm_patch

    ; Write panning: centre ($C0) to OPM $20+ch (sub_0d63h)
    move.b  (CH_CONFIG,a4),d0
    and.b   #$03,d0
    add.b   #OPM_RL_FB_CON,d0
    move.b  #$C0,d1
    bsr     write_opm

    ; Clear disable flag — channel now ready (sub_0d63h finale)
    clr.b   (CH_DISABLE,a4)
    rts


; =============================================================================
; ADPCM service
; Called from interrupt when snd_sample = $FF
; MSM6258 handles its own timing — CPU only needs to detect completion
; =============================================================================

adpcm_service:
    ; Check for data remaining
    tst.l   (snd_adpcm_len)
    beq.b   .done

    ; Feed next byte to MSM6258 data port
    move.l  (snd_adpcm_ptr),a0
    move.b  (a0)+,(ADPCM_DATA)
    move.l  a0,(snd_adpcm_ptr)
    subq.l  #1,(snd_adpcm_len)
    bne.b   .active

    ; Sample complete — stop chip
    move.b  #$00,(ADPCM_CTRL)
    clr.b   (snd_sample)
    rts

.active:
    rts

.done:
    ; Stop chip and clear flag
    move.b  #$00,(ADPCM_CTRL)
    clr.b   (snd_sample)
    rts


; =============================================================================
; snd_play_sample
; Start ADPCM sample playback
; a0 = pointer to OKI ADPCM sample data (pre-converted from raw PCM)
; d0.l = sample length in bytes
; =============================================================================

snd_play_sample:
    ; Stop any current playback
    move.b  #$00,(ADPCM_CTRL)

    ; Set pointers and length
    move.l  a0,(snd_adpcm_ptr)
    move.l  d0,(snd_adpcm_len)

    ; Set active flag BEFORE starting chip (mirrors MD ordering)
    move.b  #$FF,(snd_sample)

    ; Start MSM6258: bit3=start, bits1-0=clock /512
    ; /512 with 8MHz OPM clock ≈ 15.6kHz sample rate
    move.b  #$09,(ADPCM_CTRL)
    rts


; =============================================================================
; Public API
; Game code calls these instead of writing to Z80 shared RAM
; =============================================================================

; snd_cmd_play_music
; Start a music track
; d0.b = bank (0/1), d1.b = track index (1-based)
; Setting snd_track non-zero signals the sequencer to load on next tick.
; Do NOT set snd_update_flag — that path bypasses track loading.
snd_cmd_play_music:
    move.b  d0,(snd_bank)
    move.b  d1,(snd_track)      ; non-zero = track load pending
    clr.b   (snd_update_flag)   ; clear any pending force update
    rts

; snd_cmd_stop_music
; Stop music with fade-out
; d0.b = fade speed (accumulation rate)
; d1.b = fade step size (= ch_count value)
snd_cmd_stop_music:
    move.b  d0,(snd_fade_speed)
    move.b  d1,(snd_ch_count)
    move.b  #1,(snd_fade_flag)
    rts

; snd_cmd_pause
; Pause or resume music
; d0.b = 0=resume, 1=pause
snd_cmd_pause:
    move.b  d0,(snd_pause)
    rts

; snd_cmd_play_instrument
; Trigger an instrument
; d0.b = index (bits 6-0), bit 7 = force all operators
snd_cmd_play_instrument:
    move.b  d0,(snd_instrument)
    rts

; snd_cmd_set_pan
; Set panning for instrument channels
; d0.b = pan value (bits 1-0: 00=centre, 01=right, 10=left, 11=both)
snd_cmd_set_pan:
    move.b  d0,(snd_pan)
    rts

; snd_cmd_set_expression
; Set expression / velocity
; d0.b = value (0-127)
snd_cmd_set_expression:
    move.b  d0,(snd_expression)
    rts

; snd_cmd_play_sample
; Play an ADPCM sample
; a0 = pointer to OKI ADPCM data, d0.l = length
snd_cmd_play_sample:
    bsr     snd_play_sample
    rts

; snd_cmd_is_idle
; Check if music driver is idle
; Returns: Z flag set = idle ($3F status), Z clear = busy
snd_cmd_is_idle:
    cmp.b   #$3F,(snd_status)
    rts

; snd_cmd_is_inst_ready
; Check if instrument driver is ready for new trigger
; Returns: Z flag set = ready, Z clear = busy
snd_cmd_is_inst_ready:
    tst.b   (snd_instrument)    ; zero = no pending trigger
    rts

; =============================================================================
; RAM variables
; Placed at sound driver RAM base — adjust org as needed
; =============================================================================
    bss
    even

; --- Communication interface (mirrors Z80 $A000xx layout) ---
snd_bank:           ds.b    1       ; track bank select (0/1)
snd_track:          ds.b    1       ; track index to load (0=none)
snd_fade_speed:     ds.b    1       ; fade accumulation rate
snd_ch_count:       ds.b    1       ; active channels $07 or $09 (used as fade step)
snd_status:         ds.b    1       ; $3F=idle $00=busy
snd_vol_accum:      ds.b    1       ; global volume accumulator (internal)
                    ds.b    1       ; unused ($000A)
snd_pause:          ds.b    1       ; $00=play $01=pause
                    ds.b    4       ; unused ($000C-$000F)
snd_sample:         ds.b    1       ; ADPCM: $FF=active $00=stopped
                    ds.b    1       ; unused ($0011)
snd_instrument:     ds.b    1       ; instrument trigger
snd_pan:            ds.b    1       ; panning value (bits 1-0)
snd_expression:     ds.b    1       ; expression / velocity

; --- Sequencer internal state ---
snd_update_flag:    ds.b    1       ; $FF=force track reload (mirrors l01c8h)
snd_tempo_div:      ds.b    1       ; tempo divider counter (mirrors l1390h)
snd_tempo_base:     ds.b    1       ; tempo base value (mirrors l1391h)
snd_tempo_frac:     ds.b    1       ; fractional accumulator (mirrors l1391h+1)
snd_tempo_ovf:      ds.b    1       ; overflow flag (mirrors l1391h+2)
snd_fade_flag:      ds.b    1       ; fade enable (mirrors l1394h)
snd_fade_accum:     ds.b    1       ; fade step accumulator (mirrors l1396h)
snd_psg_mixer:      ds.b    1       ; global MIDI/PSG mixer state (mirrors l1397h)

; --- Track and asset pointers (replace Z80 bank+offset system) ---
    align 4
snd_track_ptr:      ds.l    1       ; current track base pointer
snd_track_table:    ds.l    32      ; pointers to decompressed track data in RAM
snd_inst_table:     ds.l    1       ; pointer to instrument/patch table in RAM
snd_arp_table:      ds.l    1       ; pointer to arpeggio pattern table in RAM
snd_fm_preset_ptr:  ds.l    1       ; FM preset table base
snd_midi_preset_ptr: ds.l   1       ; MIDI/PSG preset table base

; --- Channel state blocks ---
; Music channels: MUSIC_CH_BASE equivalent
snd_music_ch:       ds.b    MUSIC_CH_SIZE*MUSIC_CH_COUNT

; Instrument channels: INST_CH_BASE equivalent
snd_inst_ch:        ds.b    INST_CH_SIZE*INST_CH_COUNT

; --- ADPCM state ---
    align 4
snd_adpcm_ptr:      ds.l    1       ; pointer to current ADPCM sample data
snd_adpcm_len:      ds.l    1       ; remaining bytes in current sample

; Saved interrupt vector (set by snd_init via _INTVCS, restored by cleanup)
saved_vblank_vec:   ds.l    1

; --- MIDI note tracking (for note-off) ---
snd_midi_notes:     ds.b    3       ; current note per MIDI PSG channel (0-2)

; --- Saved channel disable states (across track changes) ---
snd_saved_disable:  ds.b    MUSIC_CH_COUNT