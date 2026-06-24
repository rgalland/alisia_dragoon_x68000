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
;                       Processed by snd_process_music at tempo-divided rate
;   Instrument channels: base INST_CH_BASE ($111A equiv)
;                       4 FM channels, 36 bytes ($24) each
;                       Processed by snd_process_sfx at timer B rate
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
;   snd_bank        — track bank (0/1) → index into snd_track_table ($0004)
;   snd_track       — track index to load ($0005)
;   snd_fade_speed  — fade rate, non-zero starts fade ($0006)
;   snd_fade_step   — active channel count $07 or $09 ($0007)
;   snd_status      — $3F=idle $00=busy, read by game ($0008)
;   snd_vol_accum   — volume accumulator, internal ($0009)
;   snd_pause       — $00=play $01=pause ($000B)
;   snd_sample      — $FF=ADPCM active $00=stopped ($0010)
;   snd_z80_tmr     — content of the z80 register ($0011)
;   snd_instrument  — instrument trigger: bits6-0=index bit7=all ops ($0012)
;   snd_pan         — panning value bits1-0 ($0013)
;   snd_expression  — expression/velocity ($0014)
;   snd_re_lock:    — reentrancy lock ($0016)
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
OPM_LR_FB_CON       equ $20         ; ch 0-7: L/R pan + feedback + algorithm
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

; =============================================================================
; FM frequency table — confirmed from verified Z80 binary
; 3 bytes per note: [ix+$22 value] [F-number low] [F-number high with block]
; 12 entries — one chromatic octave (C through B), confirmed against the
; verified Z80 source (immediately followed there by psg_freq_table at
; offset $3D, leaving no room for additional FM entries)
; Used by snd_calc_frequency to preserve CH_BASE_NOTE for other code that
; reads it; pitch→OPM KeyCode is derived from chromatic index + CH_OCTAVE
; directly, not from these F-number/block values (see snd_calc_frequency)
; =============================================================================
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
; OPM KeyCode note-nibble table
; THis will need to be used instead of values from the table above
; =============================================================================
opm_note_table:     ; TODO - find a way to convert original freq table to OPM notes+fraction
    dc.b    $00         ; index 0  C#
    dc.b    $01         ; index 1  D
    dc.b    $02         ; index 2  D#
    dc.b    $04         ; index 3  E
    dc.b    $05         ; index 4  F
    dc.b    $06         ; index 5  F#
    dc.b    $08         ; index 6  G
    dc.b    $09         ; index 7  G#
    dc.b    $0A         ; index 8  A
    dc.b    $0C         ; index 9  A#
    dc.b    $0D         ; index 10 B
    dc.b    $0E         ; index 11 C


; YM2612 → YM2151 key-on operator attenuation flags indexed by algo value:
opm_attenuation_table:
    dc.b    %00000001   ; algo 0: C2 only
    dc.b    %00000001   ; algo 1: C2 only
    dc.b    %00000001   ; algo 2: C2 only
    dc.b    %00000001   ; algo 3: C2 only
    dc.b    %00000011   ; algo 4: C1+C2
    dc.b    %00000111   ; algo 5: M2+C1+C2
    dc.b    %00000111   ; algo 6: M2+C1+C2
    dc.b    %00001111   ; algo 7: all operators

; PSG frequency table — confirmed from verified Z80 binary
; 3 bytes per note, PSG period values (descending = higher pitch)
; Used by sub_07dbh PSG path (add $3D offset)
; Not needed for X68000 port (PSG replaced by MIDI) — kept for reference
md_psg_freq_table:
    dc.b    $cb,$5c,$0d     ; note 1  C
    dc.b    $c0,$9c,$0c     ; note 2  C#
    dc.b    $b5,$e7,$0b     ; note 3  D
    dc.b    $ab,$3c,$0b     ; note 4  D#
    dc.b    $a1,$9a,$0a     ; note 5  E
    dc.b    $98,$02,$0a     ; note 6  F
    dc.b    $8f,$72,$09     ; note 7  F#
    dc.b    $87,$ea,$08     ; note 8  G
    dc.b    $80,$6a,$08     ; note 9  G#
    dc.b    $78,$f1,$07     ; note 10 A
    dc.b    $72,$7f,$07     ; note 11 A#
    dc.b    $6b,$13,$07     ; note 12 B


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


; -----------------------------------------------------------------------
; [M] MUSIC channel block
; -----------------------------------------------------------------------
CH_CONFIG           equ $00     ; [B] ix+$00 — channel configuration byte
                                ;   bits 7-6: LR
                                ;   bit 5   : 1=MIDI/PSG 0=FM
                                ;   bits 2-0: channel number
                                ;     FM: 0-5 (linear, no YM2612 port gap)
                                ;     MIDI: 0-2 (PSG channel index)
CH_DISABLE          equ $01     ; [B] ix+$01 — disable flag: non-zero
                                ; suppresses hw writes. Set during channel
                                ; init, cleared when ready.
;CH_FREQ_LO          equ $02     ; [B] ix+$02 — frequency low byte
                                ;   FM: OPM KeyCode (octave<<4 | note_nibble)
                                ;   MIDI: MIDI note number (0-127)
;CH_FREQ_HI          equ $03     ; [B] ix+$03 — frequency high byte
                                ;   FM: OPM KeyFraction (bits 7-2, 6 bits)
                                ;   MIDI: unused
CH_FREQ             equ $02     ; big endian word to replace CH_FREQ_LO and CH_FREQ_HI
CH_OCT_KC           equ $02     ; octave on 3 bits + key code on 4 bits, bit 7 not used
CH_KEY_FRAC         equ $03     ; key fraction on 6 bits, bits 1-0 are used
;CH_VIB_DELTA_LO     equ $04     ; [B] ix+$04 — vibrato frequency delta low
;CH_VIB_DELTA_HI     equ $05     ; [B] ix+$05 — vibrato frequency delta high
CH_VIB_DELTA        equ $04     ; big endian word to replace CH_VIB_DELTA_LO and CH_VIB_DELTA_HI
CH_VIB_ACCUM        equ $06     ; [B] ix+$06 — vibrato accumulator (init $80)
CH_FINETUNE         equ $07     ; [B] ix+$07 — fine-tune signed offset
CH_VOLUME           equ $08     ; [B] ix+$08 — channel volume / TL base value
                                ;   FM: OPM TL style 0=loud $7F=silent
                                ;   MIDI: inverted for velocity
CH_OCTAVE           equ $09     ; [B] ix+$09 — current octave 0-7
CH_FM_LR_FB_ALGO    equ $0A     ; [B] ix+$0A — feedback and algo value for FM channels
CH_PSG_MASK         equ $0A     ; [B] ix+$0A — PSG mixer mask for PSG channels (MIDI: unused)
;CH_PTR_LO           equ $0B     ; [B] ix+$0B — stream data ptr low - replaced by LW ptr
;CH_PTR_HI           equ $0C     ; [B] ix+$0C — stream data ptr high - replaced by LW ptr
;CH_LOOP_LO          equ $0D     ; [B] ix+$0D — loop ptr low - replaced by LW ptr
;CH_LOOP_HI          equ $0E     ; [B] ix+$0E — loop ptr high - replaced by LW ptr
;CH_TMP_INST_PTR_HI  equ $0f     ; unused word ptr, use CH_TMP_INST_PTR instead
;CH_TMP_INST_PTR_LO  equ $10     ; unused word ptr, use CH_TMP_INST_PTR instead

CH_COUNTER_SLOT0    equ $11     ; [M] ix+$11 — counter/index array slot 0
CH_COUNTER_SLOT1    equ $12     ; [M] ix+$12 — counter/index array slot 1
CH_COUNTER_SLOT2    equ $13     ; [M] ix+$13 — counter/index array slot 2
CH_COUNTER_SLOT3    equ $14     ; [M] ix+$14 — counter/index array slot 3
CH_COUNTER_BASE     equ $11     ; [M] base offset for indexed access:
                                ; (CH_COUNTER_BASE,a4,dN.w) with dN = 0-3
;CH_INST_PTR_HI      equ $15     ; unused word ptr, use CH_INST_PTR instead
;CH_INST_PTR_LO      equ $16     ; unused word ptr, use CH_INST_PTR instead
CH_FLAGS            equ $17     ; [B?] ix+$17 — channel flags byte
                                ;   bit 0: channel inactive (1=skip)
                                ;   bit 1: portamento active
                                ;   bit 3: arpeggio active
                                ;   bit 5: effects active
                                ;   bit 6: vibrato enable
CH_DURATION         equ $18     ; [B?] ix+$18 — note duration counter
CH_FX_FLAGS         equ $19     ; [B?] ix+$19 — envelope/effect flags
                                ;   bit 0: note currently playing
                                ;   bit 1: ??
                                ;   bit 4: sustain/legato active
                                ;   bit 5: retrigger suppress
                                ;   bits 7-6: LR
CH_FX_DURATION      equ $1A     ; [B?] ix+$1A — portamento threshold
;MUSIC_PRESET_LO     equ $1B     ; [M] ix+$1B — active preset data ptr low
;MUSIC_PRESET_HI     equ $1C     ; [M] ix+$1C — active preset data ptr high
CH_NOTE_REG         equ $1D     ; [B] ix+$1D — note register (b6-4=OCTAVE,b3-0=NOTE / vibrato base)
;CH_ARP_S1_LO        equ $1E     ; [M] ix+$1E — arpeggio step 1 low
;CH_ARP_S1_HI        equ $1F     ; [M] ix+$1F — arpeggio step 1 high
CH_ARP_S1           equ $1E     ; [M] ix+$1e/ix+$1f — arpeggio step 1
;CH_ARP_S2_LO        equ $20     ; [M] ix+$20 — arpeggio step 2 low
;CH_ARP_S2_HI        equ $21     ; [M] ix+$21 — arpeggio step 2 high
CH_ARP_S2           equ $20     ; [M] ix+$20/ix+$21 — arpeggio step 2
CH_BASE_NOTE        equ $22     ; [M] ix+$22 — frequency table byte
CH_VIB_PARAMS       equ $23     ; [M] ix+$23 — vibrato parameters, 6 bytes
CH_ARP_M1           equ $24     ; [M] ix+$24 — arp multiplier 1
CH_ARP_M2           equ $25     ; [M] ix+$24 — arp multiplier 2
CH_ARP_M3           equ $26     ; [M] ix+$24 — arp multiplier 3
CH_ARP_M4           equ $27     ; [M] ix+$24 — arp multiplier 4
CH_ARP_M5           equ $28     ; [M] ix+$24 — arp multiplier 5
CH_ARP_COUNTER2     equ $29     ; [M] ix+$29 — arpeggio counter
CH_ARP_BASE         equ $2A     ; [M] ix+$2A — arpeggio base value, 5 bytes
                                ; ($2A-$2E inclusive)
CH_VIB_DEPTH        equ $2B     ; [M] ix+$2B — vibrato depth parameter
CH_ARP_INTERVAL     equ $2C     ; [M] ix+$2C — arpeggio interval
CH_ARP_CTR_INIT     equ $2D     ; [M] ix+$2D — arpeggio counter initialiser
CH_PAN_FLAGS        equ $2E     ; [M] ix+$2E — panning + vibrato direction
                                ;   bit 6: vibrato direction
                                ;   bit 7: vibrato invert
CH_ARP_COUNTER      equ $2F     ; [M] ix+$2F — arpeggio counter
CH_PORT_SPEED       equ $30     ; [M] ix+$30 — portamento speed
CH_PORT_TARGET      equ $31     ; [M] ix+$31 — portamento target
CH_PORT_BASE        equ $32     ; [M] ix+$32 — portamento base (copy of speed)
CH_FM_AMS_PMS       equ $33     ; [M] ix+$33 —
CH_MIDI_MIXER       equ $34     ; [M] ix+$34 — MIDI pan / FM algorithm cache
CH_MIDI_SPEED       equ $35     ; [M] ix+$35 — MIDI portamento speed
                                ; (last byte of the original 54-byte
                                ; Z80 music channel block, ix+$00..ix+$35)
CH_STREAM_PTR       equ $36     ; pointer to replace +$0b and +$0c
CH_LOOP_PTR         equ $3a     ; pointer to replace +$0d and +$0e
CH_TMP_INST_PTR     equ $3e     ; pointer to replace +$0f and +$10
CH_INST_PTR         equ $42     ; pointer to replace +$15 and +$16
CH_PRESET_PTR       equ $46     ; [M] replaces ix+$1B and ix+$1C

MUSIC_CH_SIZE       equ $4C     ; was $36 (original Z80 size)

; -----------------------------------------------------------------------
; [I] INSTRUMENT channel block
; -----------------------------------------------------------------------
INST_VIB_CALC       equ $0F     ; [I] vibrato calc scratch — exact role
                                ; still loose; confirmed only as written
                                ; by l0f45h's multiply+double sequence
;INST_VIB_RESULT_LO  equ $10     ; [I] vibrato calc result low byte
;INST_VIB_RESULT_HI  equ $11     ; [I] vibrato calc result high byte
INST_VIB_RESULT     equ $10     ; [I] big endian word to replace INST_VIB_RESULT_LO and INST_VIB_RESULT_HI
;INST_VIB_RESULT2_LO equ $12     ; [I] second vibrato calc result low byte
;INST_VIB_RESULT2_HI equ $13     ; [I] second vibrato calc result high byte
INST_VIB_RESULT2    equ $12     ; [I] big endian word to replace INST_VIB_RESULT2_LO and INST_VIB_RESULT2_HI

INST_BASE_NOTE      equ $14     ; [I] set in the inst note routine from note table
INST_VIB_PARAM      equ $15     ; [I] vibrato parameter
INST_VIB_PARAM2     equ $16     ; [I] vibrato parameter 2
INST_DURATION1      equ $17     ; [I]
INST_DURATION2      equ $18     ; [B?] ix+$18 — note duration counter
INST_DUR_VAR        equ $19     ; [I] duration variation, b7=duration select, b6-0=value
INST_VIB_SUBCOUNTER equ $1A     ; [I] vibrato sub-counter, decremented
INST_STATUS         equ $1B     ; [I] ix+$1B — instrument channel status
                                ;   bit 0: channel active
                                ;   bit 1: vibrato enable
                                ;   bits 7-6: panning bits
INST_DURATION       equ $1C     ; [I] ix+$1C — instrument duration counter
INST_OCTAVE_NOTE    equ $1D     ; [B] ix+$1D — octave/note index (b6-4=OCTAVE,b3-0=NOTE IDX)
INST_VOL_VAR        equ $1E     ; [I] ix+$1E — volume variation to apply to the volume register +$08
INST_STEP_RATE      equ $1F     ; [I] ix+$1F — fractional step rate
INST_CH_IDX         equ $20     ; [I] ix+$20 — channel index for address calc
INST_PREV_DUR       equ $21     ; [I] ix+$21 — previous duration value
INST_FRAC_ACCUM     equ $22     ; [I] ix+$22 — fractional accumulator
INST_OP_MASK        equ $23     ; [I] ix+$23 — channel priority
                                ; (this is the LAST byte used in the
                                ; original 36-byte instrument block —
                                ; everything from here down is [M]-only)

INST_CH_SIZE        equ $42     ; was $24 (original Z80 size)

; Channel counts
MUSIC_CH_COUNT      equ 9       ; total music channels (6 FM + 3 MIDI)
FM_MUSIC_COUNT      equ 6       ; FM music channels
MIDI_MUSIC_COUNT    equ 3       ; MIDI PSG replacement channels
INST_CH_COUNT       equ 4       ; instrument channels
PRESET_COUNT        equ 4       ; presets stored after the 9 channel indices

; =============================================================================
; Duration lookup table
; Converts note duration index (upper nibble of note byte, 0-15) to tick count
; Equivalent of sub_0b56h — verify values against original Z80 table at $005F
; =============================================================================

psg_noise_table:
    dc.b    $04,$04,$04,$04,$05,$05,$05,$05
    dc.b    $06,$06,$06,$06

; =============================================================================
; Code section
; =============================================================================
    text
    even

; =============================================================================
; snd_init
; Initialise entire sound system
; Call once at startup after all assets are loaded into RAM
; =============================================================================
snd_init:
    ; Switch to supervisor mode for hardware register access
    ; DOS _SUPER ($FF20): push 0 to enter supervisor mode
    ; Returns old SSP in d0 (save for restore on exit)
    ; Without this, reading/writing hardware registers at $E9xxxx
    ; crashes with a bus error in Human68k user mode
    DOS_SUPER
    move.l  d0,(saved_ssp)     ; save old SSP

    ; init to values set by default in MD Z80 binary file which
    ; are not set in software apart from M68K copying binary code
    ; db $00, $01, $00, $10, $ff  ; $0004-$0008
    ; db defs 10                     ; $0009-$0012
    ; db $03, $00, $00, $ff       ; $0013-$0016
    clr.b   (snd_bank)          ; ($0004)
    move.b  #$10,(snd_fade_step)    ; ($0007)
    move.b  #$3,(snd_pan)       ; ($0013)
    clr.b   (snd_expression)    ; ($0014)
    clr.b   (snd_op_mask)       ; ($0015)
    move.b  #$ff,(snd_re_lock); ; ($0016)

    bsr     init_driver_interface
    ; other driver variables to be initialised only on start up in software
    clr.b   (snd_sample_update_flag)
    clr.b   (snd_pause)
    clr.b   (snd_instrument)
    clr.b   (snd_sample)
    clr.l   (snd_adpcm_ptr)
    clr.l   (snd_adpcm_len)
    clr.b   (snd_midi_notes+0)
    clr.b   (snd_midi_notes+1)
    clr.b   (snd_midi_notes+2)

    ; populate default data in instrument blocks
    bsr     init_inst_blocks

    ; Initialise hardware (now in supervisor mode — safe to access $E9xxxx)
    bsr     opm_init
    bsr     adpcm_init
    bsr     midi_init

    ; Install YM2151 timer interrupt handler
    ; Use DOS _INTVCS ($FF25) — correct way to set interrupt vectors
    ; CRITICAL: the YM2151's timer A/B IRQ output is wired to the MFP's
    ; dedicated "FM Audio source" line at vector $43 — NOT MFP Timer-A
    ; ($4D) or Timer-B ($48), which are separate, never-started, internal
    ; MFP timers. Installing on the wrong vector means write_opm works
    ; fine (confirms hardware access/supervisor mode is correct) but the
    ; interrupt never reaches snd_timer_irq, so irq_counter stays at zero.
    lea     snd_timer_irq,a0
    move.l  a0,-(sp)              ; handler address (push first)
    move.w  #FM_IRQ_VECTOR,-(sp)  ; vector number $43 (push second)
    DOS     _INTVCS
    addq.l  #6,sp
    move.l  d0,(saved_vblank_vec) ; save old handler returned in d0

    ; Enable and unmask the FM Audio source interrupt at the MFP level.
    ; Installing the vector alone is not enough — the MFP itself must
    ; also be told to generate and pass through this interrupt.
    ; FM Audio source = GPIP3 = bit 3 of Interrupt Enable/Mask register B
    bset    #3,(MFP_IERB)       ; enable GPIP3 interrupt generation
    bset    #3,(MFP_IMRB)       ; unmask GPIP3 so it reaches the CPU
    bclr    #3,(MFP_ISRB)       ; clear any stale pending flag

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
    move.l  d7,-(sp)
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
    move.b  #OPM_LR_FB_CON,d0
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
    move.l  (sp)+,d7
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
;   .busy: btst.b #7,(YM2151_STATUS) / bne.b .busy
; =============================================================================
write_opm:
    addq.l  #1,(opm_write_count)   ; debug instrumentation (soundtest.s)
.busy:
    btst.b  #7,(YM2151_STATUS)  ; bit 7 = busy flag
    bne.b   .busy
    move.b  d0,(YM2151_ADDR)   ; write register address
.busy2:
    btst.b  #7,(YM2151_STATUS)
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

    even

; =============================================================================
; midi_init
; Initialise MIDI port and MU1000EX
; =============================================================================
midi_init:
    ; check midi is present first
    clr.b   midi_present
    btst.b  #1,(MIDI_STATUS)
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
    move.l  d7,-(sp)
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
    move.l  (sp)+,d7
    rts


; =============================================================================
; MIDI transmit routines
; Send block of bytes: a0=source, d7=count-1
; =============================================================================
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

; Send one byte (d0.b) to MIDI output
send_midi_byte:
    tst.b   midi_present
    beq.b   .no_midi_board
.wait:
    btst.b  #1,(MIDI_STATUS)
    beq.b   .wait
    move.b  d0,(MIDI_DATA)
.no_midi_board:
    rts


; =============================================================================
; snd_clear_all_channels
; Zero all channel block memory
; part of Z80 code: init_driver_interface - $01df
; =============================================================================
snd_clear_all_channels:
    movem.l d0,-(sp)
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
    movem.l (sp)+,d0
    rts

; =============================================================================
; init_inst_blocks
; Set CH_CONFIG/INST_CH_IDX and INST_OP_MASK with dynamics values
; all other values are constants
; Equivalent of the channel number stamping in $0d1e (without the gap)
; =============================================================================
init_inst_blocks:
    movem.l d7,-(sp)
    lea     (snd_inst_ch),a4
    moveq   #INST_CH_COUNT-1,d7
    moveq   #INST_CH_COUNT,d0
.inst_init:
    bsr     init_inst_block
    subq.b  #$1,d0  ; dec channel index (will be 4-1)
    lea     (MUSIC_CH_SIZE,a4),a4   ; next inst block
    dbf     d7,.inst_init
    movem.l (sp)+,d7
    rts

; d0 = channel index
; a4 = inst block pointer
init_inst_block:
    ; will populate the inst block with constants and a couple of
    move.b  d0,(CH_CONFIG,a4)
    move.b  #$7f,(CH_VOLUME,a4)
    move.b  #$04,(CH_OCTAVE,a4)
    move.b  #$02,(INST_DURATION1,a4)
    move.b  #$02,(INST_DURATION2,a4)
    move.b  #$01,(INST_VIB_SUBCOUNTER,a4)
    move.b  #$c0,(INST_STATUS,a4)
    move.b  #$01,(INST_DURATION,a4)
    move.b  #$40,(INST_OCTAVE_NOTE,a4)
    move.b  #$7f,(INST_STEP_RATE,a4)
    move.b  d0,(INST_CH_IDX,a4)     ; +$20 in original tmp table
    move.b  #$01,(INST_PREV_DUR,a4)
    move.b  #$ff,(INST_FRAC_ACCUM,a4)
    move.b  (snd_op_mask),d1
    move.b  d1,(INST_OP_MASK,a4)
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

    ; Acknowledge MFP interrupt — FM Audio source is GPIP3 = bit 3 of ISRB
    ; (vector $43 maps to interrupt control/status register B, bit 3)
    bclr    #3,(MFP_ISRB)

    ; Check pause
    tst.b   (snd_pause)
    bne     .irq_exit

    ; IRQ akin to TIMER B - process music and inst channels
    bsr     snd_process_music
    bsr     snd_process_sfx
    bsr     snd_process_samples

    bsr     snd_load_instrument
    ; Service ADPCM if active
    tst.b   (snd_sample)
    beq.b   .irq_exit
    bsr     adpcm_service

.irq_exit:
    movem.l (sp)+,d0-d7/a0-a6
    rte

; =============================================================================
; snd_process_samples
; called every interrupt
; Equivalent of sub_0137h
; =============================================================================
snd_process_samples:
    move.l  d7,-(sp)
    tst.b   (snd_sample_update_flag)
	bne     .update_sample		; jump if sample needs to be loaded
	tst.b   (snd_sample)        ; $0010 equivalent
    beq     .no_sample          ; nothing to do, leave
    ; Silence all active FM channels (sub_0137h inner loop)
    lea     (snd_music_ch),a4
    moveq   #FM_MUSIC_COUNT-1,d7
.update_loop:
    ; Check if channel has a preset (ix+$1b/$1c non-zero)
    movea   (CH_PRESET_PTR,a4),a2
    ; Temporarily clear disable flag and write TL=$7F to all operators
    move.b  (CH_DISABLE,a4),-(sp)
    clr.b   (CH_DISABLE,a4)
    adda.w  #$8,a2                  ; data source
    move.b  #$7F,d4                 ; e=$7F in original = max attenuation
    bsr     snd_write_tl_opm        ; silence all operators
    move.b  (sp)+,(CH_DISABLE,a4)  ; restore disable flag
.silence_next:
    lea     (MUSIC_CH_SIZE,a4),a4
    dbf     d7,.update_loop
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
    move.b  #$ff,(snd_sample_update_flag)   ; force reload for next time
    beq.b   .no_sample
.update_sample: ; copy FM and PSG sounds
	tst.b   (snd_sample)        ; $0010 equivalent
    bne     .no_sample          ; leave in this case if a new sample is requested
    ; Silence all active FM channels (sub_0137h inner loop)
    lea     (snd_music_ch),a4
    moveq   #FM_MUSIC_COUNT-1,d7
.volume_loop:
    bsr     snd_calc_combined_volume
    bsr     snd_write_tl_opm
.set_volume_next
    dbf     d7,.volume_loop
    ; Silence MIDI PSG channels (replaces PSG $9F/$BF/$DF/$FF writes)
    moveq   #MIDI_MUSIC_COUNT-1,d7
    moveq   #MIDI_PSG0,d6
.midi_volume:
    bsr     snd_calc_combined_volume
    move.b  d4,d2
    eori.b  #$ff,d2
    andi.b  #$7f,d2
    ; Send CC7 volume to silence MIDI channel
    move.b  d6,d0
    move.b  #7,d1               ; CC7 volume
    bsr     midi_send_cc
.set_midi_volume_next
    dbf     d7,.midi_volume
	clr.b   (snd_sample_update_flag)
.no_sample
    move.l  (sp)+,d7
    rts

; =============================================================================
; snd_process_music
; Drive music sequencer — called every interrupt
; Equivalent of $0325
; =============================================================================
snd_process_music:
    move.l  d7,-(sp)
    tst.b   (snd_sample_update_flag)
    bne     .tick_done
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
    move.b  (snd_tempo_base),d0
    add.b   d0,(snd_tempo_frac)
    bcs.b   .tempo_carry
    clr.b   (snd_tempo_ovf)    ; no carry = duration decrements this call
    bra.b   .check_loop_gate
.tempo_carry:
    move.b  #$ff,(snd_tempo_ovf)   ; overflow = duration skipped this call
.check_loop_gate:
    not.b   (snd_fade_flag)
    bne     .check_fade     ; if flag is set
    tst.b   (snd_tempo_ovf)
    beq     .check_fade     ; or if no ovf
    bra     .tick_done
    ; Process fade step if active
.check_fade:
    tst.b   (snd_fade_speed)
    beq.b   .no_fade_tick
    bsr     snd_fade_tick
    tst.b   (snd_fade_speed)   ; did fade complete (set status to idle)?
    beq     .tick_done         ; yes — don't process channels
.no_fade_tick:

    ; --- Process all 9 music channel blocks ---
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
    move.l  (sp)+,d7
    rts


; =============================================================================
; snd_channel_tick
; Process one music channel for this sequencer tick
; a4 = pointer to music channel block (MUSIC_CH_BASE equivalent)
; Equivalent of sub_03d1h
; =============================================================================
snd_channel_tick:
    ; Skip if channel inactive (CH_FLAGS bit 0 = 1)
    btst.b  #0,(CH_FLAGS,a4)
    bne     .skip

    tst.b   (snd_tempo_ovf)
    bne     .check_fade
    ; --- Decrement note duration (mirrors dec (ix+$18)) ---
    subq.b  #1,(CH_DURATION,a4)
    beq     .read_next_event
    ; --- Check portamento threshold (mirrors cp (ix+$1A)) ---
    move.b  (CH_FX_DURATION,a4),d0
    cmp.b   (CH_DURATION,a4),d0
    bhi     .check_fade
    ; --- Check sustain flag (mirrors bit 4,(ix+$19)) ---
    btst.b  #4,(CH_FX_FLAGS,a4)
    bne     .check_fade
    bsr     snd_rst_flag_key_off
    bra     .check_fade
.read_next_event:
    bsr     snd_read_event      ; expired → read next event
.check_fade:
    tst.b   (snd_fade_flag)
    bne     snd_apply_effects
.skip:
    rts


; =============================================================================
; snd_read_event
; Read and dispatch next event byte from track data stream
; a4 = channel block
; Equivalent of .l03f9h in sub_03d1h
; =============================================================================
snd_read_event:
    ; Load 32-bit stream pointer from channel block (aligned field)
    movea.l (CH_STREAM_PTR,a4),a5  ; a5 = track stream pointer (full 32-bit)
.read_data_stream:
    move.b  (a5)+,d0            ; read event byte, advance pointer
    ; Dispatch by value range
    bmi     .exec_cmd
    move.l a5,(CH_STREAM_PTR,a4)    ; save ptr
    bra     .snd_note_handler        ; bit 7=0 → note byte ($00-$7F)
.exec_cmd:
    ; Command byte
    btst    #6,d0
    beq.b   .range_80_bf        ; bit6=0, bit7=1 → preset ($80-$BF)

    ; $C0-$FF range
    cmp.b   #$d0,d0
    bcs.b   .range_c0_cf        ; $C0-$CF: relative volume
    cmp.b   #$d8,d0
    bcs.b   .range_d0_d7        ; $D0-$D7: set octave
    cmp.b   #$e0,d0
    bcs.b   .range_d8_df        ; $D8-$DF: portamento speed
    bsr     snd_extended_cmd    ; $E0-$FF: extended commands
    bra     .read_data_stream

.range_80_bf:
    move.b  d0,d2
    and.b   #$3F,d2             ; preset index bits 5-0
    bsr     snd_load_preset     ; only called here - protect stream pointer (a5)
    bra     .read_data_stream

.range_c0_cf:
    bsr     snd_rel_volume      ; only called here - protect stream pointer (a5)
    bra     .read_data_stream

.range_d0_d7:
    and.b   #$07,d0             ; octave in bits 2-0
    move.b  d0,(CH_OCTAVE,a4)
    bra     .read_data_stream

.range_d8_df:
    bsr     snd_duration_lookup
    move.b  d0,(CH_FX_DURATION,a4)  ; save value read from routine
    bra     .read_data_stream

; =============================================================================
; snd_note_handler
; Handle note byte (bit 7 = 0)
; d0.b = note byte: bits 7-4=duration index, bits 3-0=pitch
; a4 = channel block, a5 = stream pointer (after event byte)
; Equivalent of l068eh
; =============================================================================
.snd_note_handler:
    ; Check for sustain modifier ($E7 following this note)
    bclr.b  #4,(CH_FX_FLAGS,a4)
    cmp.b   #$e7,(a5)
    bne.b   .no_sustain
    bset.b  #4,(CH_FX_FLAGS,a4)
.no_sustain:
    ; Get duration from upper nibble
    move.b  d0,d2   ; save d0 for later
    lsr.b   #4,d0
    bsr     snd_duration_lookup
    move.b  d0,(CH_DURATION,a4)
    ; Get pitch from lower nibble
    move.b  d2,d0
    andi.b  #$0f,d0
    ; Rest (pitch 0) — set duration only, apply effects
    beq.b   .rest
    ; NOP note (pitch $0F) — do nothing
    cmp.b   #$0F,d0
    beq     .leave_note_handler
    ; Calculate and write frequency
    bsr     snd_calc_frequency

    ; Check retrigger suppress (ix+$19 bit 5)
    bclr.b  #$5,(CH_FX_FLAGS,a4)
    bne.b   .skip_retrigger     ; suppressed — keep playing

    ; Initialise vibrato state
    move.b  (CH_VIB_PARAMS,a4),(CH_NOTE_REG,a4)
    clr.w   (CH_VIB_DELTA,a4)
    move.b  #$80,(CH_VIB_ACCUM,a4)

    ; Panning followed by Key on
    bsr     snd_write_panning
    bsr     snd_setup_vib_arp
    bclr.b  #1,(CH_FX_FLAGS,a4)
    bset.b  #0,(CH_FX_FLAGS,a4) ; mark note playing
    btst.b  #$5,(CH_CONFIG,a4)
    bne     .leave_note_handler ; bit 5 set = PSG channel TODO
    ; FM path:
    bsr     snd_key_on
.skip_retrigger:
    bsr     snd_write_frequency
    bra     .leave_note_handler
.rest:
    bsr     snd_rst_flag_key_off
.leave_note_handler:
    rts


; =============================================================================
; snd_calc_frequency
; Calculate OPM KeyCode/KeyFraction or MIDI note from pitch + octave
; d0.b = pitch index (1-12, lower nibble of note byte; 13/14 never occur
;   on the FM path — md_fm_freq_table only has 12 chromatic entries.
;   Pitch values 13/14 are PSG-only on the original Z80 and have no FM
;   meaning, so they are not handled here.)
; a4 = channel block
; Result stored in CH_FREQ:
;   FM:   high byte = OPM KeyCode   ((octave<<4) | note_nibble)
;         low byte  = OPM KeyFraction (bits 5-0 only are meaningful)
;   MIDI: low byte  = MIDI note number (0-127)
; Equivalent of sub_07dbh
;
; FM path — no YM2612 F-number math is used. OPM pitch is selected
; directly from the pitch index and CH_OCTAVE:
;   chromatic_index (0-11) = pitch - 1, adjusted by fine-tune semitone
;     carry (see below), then wrapped into 0-11 with octave carry
;   KeyCode     = (octave << 4) | opm_note_table[chromatic_index]
;   KeyFraction = 6-bit fractional remainder from fine-tune
;
; CH_FINETUNE (signed byte, ix+$07 on the Z80) was a raw addend to the
; YM2612 F-number there; F-number deltas between adjacent semitones in
; md_fm_freq_table are NOT constant (they range ~39 to ~68 across one
; octave), so there is no single exact "F-number units per semitone"
; ratio to preserve faithfully. OPM also has no F-number concept, so a
; literal numeric port isn't possible here. Instead, CH_FINETUNE is
; reinterpreted as a signed fixed-point semitone offset, split via a
; single arithmetic shift:
;     semitone_carry = finetune asr FINETUNE_UNITS_SHIFT   (signed)
;     key_fraction    = finetune and (2^FINETUNE_UNITS_SHIFT - 1)
; With FINETUNE_UNITS_SHIFT=6 (64 units/semitone), the full signed byte
; range covers about -2..+2 semitones, which matches the order of
; magnitude of what large fine-tune values produced on the original
; YM2612 F-number (see comment above). This is a calibration choice,
; not a measured hardware constant — listen against the original Mega
; Drive mix and adjust FINETUNE_UNITS_SHIFT if the sweep feels too
; wide or too narrow. A right-shift was chosen over a divide so this
; stays a 2-instruction operation.
;
; CH_BASE_NOTE is still populated from md_fm_freq_table for any other
; code that reads it (e.g. arpeggio); it no longer feeds the pitch
; calculation itself.
; =============================================================================

FINETUNE_UNITS_SHIFT    equ 6       ; 2^6 = 64 finetune units per semitone
FINETUNE_FRAC_MASK      equ $3F     ; (1 << FINETUNE_UNITS_SHIFT) - 1
; d0 = key code, base-0 (0-11)
snd_inst_calc_frequency:
    andi.w  #$000f,d0
    subq.b  #1,d0                ; d0 = chromatic index, base-0 (0-11)
    ; Check MIDI/PSG channel
    btst.b  #5,(CH_CONFIG,a4)
    bne     .snd_calc_midi_freq
    lea     opm_note_table,a0
    move.b  (a0,d0.w),d1        ; d1 = opm note
    move.b  d1,(INST_BASE_NOTE,a4)
    move.b  (CH_OCTAVE,a4),d4   ; d4 = working octave
    lsl.b   #4,d4               ; move to bit4
    or.b    d4,d1               ; d4 = result
    move.b  d4,(CH_OCT_KC,a4)     ; store result
    clr.b   (CH_KEY_FRAC,a4)
.snd_calc_midi_freq
    rts

; d0 = key code, base-0 (0-11)
snd_calc_frequency:
snd_opm_calc_freq:  ; TODO make sure freq reg contains octave, note, fraction
    andi.w  #$000f,d0
    subq.b  #1,d0                ; d0 = chromatic index, base-0 (0-11)
    ; Check MIDI/PSG channel
    btst.b  #5,(CH_CONFIG,a4)
    bne     .snd_calc_midi_freq
    lea     opm_note_table,a0
    move.b  (a0,d0.w),d1        ; d1 = opm note
    move.b  d1,(CH_BASE_NOTE,a4)
    move.b  (CH_OCTAVE,a4),d4   ; d4 = working octave
    lsl.b   #4,d4               ; move to bit4
    or.b    d4,d1               ; d4 = result
    move.b  d4,(CH_OCT_KC,a4)     ; store result
    clr.b   (CH_KEY_FRAC,a4)
.snd_calc_midi_freq
    rts


snd_opn2_calc_frequency: ;
    subq.b  #1,d0                ; d0 = chromatic index, base-0 (0-11)
    ; Check MIDI/PSG channel
    btst.b  #5,(CH_CONFIG,a4)
    bne     .snd_calc_midi_freq
    ; --- OPM/FM path ---
    andi.w  #$000f,d0
    move.b  d0,d5                ; d5 = chromatic index, kept clean for later
    add.b   d0,d0
    add.b   d5,d0                ; d0 = chromatic_index * 3
    lea     md_fm_freq_table,a0
    move.b  (0,a0,d0.w),d1
    move.b  d1,(CH_BASE_NOTE,a4)
    move.b  (1,a0,d0.w),d1      ; freq lsb
    move.b  (2,a0,d0.w),d2      ; freq msb
    lsl.w   #8,d2
    move.b  d1,d2               ; save result into d2
    ; add fine tuning
    move.b  (CH_FINETUNE,a4),d3 ; d2 = signed fine-tune byte
    ext.w   d3                  ; sign-extend
    add.w   d3,d2               ; d2 = result
    ; add octave
    move.b  (CH_OCTAVE,a4),d4   ; d4 = working octave
    lsl.w   #8,d4               ; move to MSB
    lsl.w   #3,d4               ; left shift by 3 again
    or.w    d4,d2               ; d2 = result
    move.w  d2,(CH_FREQ,a4)     ; store result
    rts

.snd_calc_midi_freq:
    ; --- MIDI/PSG path ---
    subq.b  #1,d0                ; base-0 (0-11)
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
    andi.w  #$00ff,d2
    move.w  d2,(CH_FREQ,a4)
    rts


; =============================================================================
; snd_wrap_keycode
; Wrap a signed chromatic index into 0-11 with octave carry, and build
; the resulting OPM KeyCode. Shared by snd_calc_frequency (fine-tune)
; and snd_apply_vibrato (per-tick vibrato), since both need the same
; non-contiguous-KC-table-aware wraparound.
; In:  d5.w = signed chromatic index (may be outside 0-11)
;      d4.b = working octave (0-7 going in; carry may push it out of
;             range — see caller note on octave-0 underflow)
; Out: d1.b = OPM KeyCode ((octave<<4)|note_nibble)
;      d5.w = wrapped chromatic index (0-11)
;      d4.b = wrapped, clamped octave (0-7)
; Clobbers: a0
; =============================================================================
snd_wrap_keycode:
    ; Bounded loop, not a generic signed divide — callers only ever
    ; produce a carry of roughly -2..+2, so this never iterates more
    ; than a handful of times.
.wrap_down:
    cmp.w   #0,d5
    bge.b   .wrap_up
    addi.w  #12,d5
    subq.b  #1,d4
    bra.b   .wrap_down
.wrap_up:
    cmpi.w  #11,d5
    ble.b   .wrap_done
    subi.w  #12,d5
    addq.b  #1,d4
    bra.b   .wrap_up
.wrap_done:
    andi.b  #$07,d4              ; clamp octave to OPM's 3-bit range (0-7)
                                  ; NOTE: this truncates rather than
                                  ; floor/ceiling-clamps, so an octave-0
                                  ; note with a large negative carry will
                                  ; wrap to octave 7 instead of stopping
                                  ; at 0. Flagged as a known edge case,
                                  ; not yet fixed (see fine-tune writeup).

    ; Build KeyCode: (octave << 4) | opm_note_table[chromatic_index]
    lea     opm_note_table,a0
    move.b  (a0,d5.w),d1         ; d1 = note nibble
    lsl.b   #4,d4
    or.b    d4,d1                ; d1 = KeyCode
    rts


; =============================================================================
; snd_write_frequency
; Write calculated frequency to OPM or prepare MIDI note (l073ah)
; a4 = channel block
; Equivalent of l0833h (FM path only — PSG path dropped)
; Write order: KeyCode first ($28+ch), then KeyFraction ($30+ch)
; This mirrors the YM2612 requirement of writing $A4 before $A0
; TODO add vibrato variation here
; the YM2612 sends octave and freq so no need to convert to full freq
; =============================================================================
snd_write_frequency:
    ; Check MIDI channel
    btst.b  #5,(CH_CONFIG,a4)
    bne     .wf_done            ; MIDI: note stored in CH_FREQ, sent at key-on

    ; --- OPM path ---
    move.b  (CH_CONFIG,a4),d2
    and.b   #$07,d2             ; OPM channel 0-7

    ;move.w  (CH_FREQ,a4),d3
    ; add vibrato
    ;add.w   (CH_VIB_DELTA,a4),d3
    ; Write KeyCode first ($28+ch) — equivalent of writing $A4 on YM2612
    move.b  d2,d0
    add.b   #OPM_KC,d0          ; register $28 + channel
    ;move.w  d3,d1               ; d3 = KeyFraction
    ;lsr.w   #$8,d1
    move.b  (CH_OCT_KC,a4),d1     ; for testing
    bsr     write_opm
    ; Write KeyFraction second ($30+ch) — equivalent of writing $A0 on YM2612
    move.b  d2,d0
    add.b   #OPM_KF,d0          ; register $30 + channel
    ;move.w  d3,d1               ; d3 = KeyFraction (low byte) for second reg
    move.b  (CH_KEY_FRAC,a4),d1     ; for testing
    bsr     write_opm

.wf_done:
    rts

; $073a - write panning to YM2612
snd_write_panning:  ; was a macro in the Z80 code
    ; Check MIDI channel
    btst.b  #5,(CH_CONFIG,a4)
    bne     .wp_done
    ; Write panning/LFO ($38+ch) — equivalent of $B4+ch on YM2612 - ($073a)
    move.b  (CH_PORT_SPEED,a4),(CH_PORT_BASE,a4)
    move.b  (CH_FM_LR_FB_ALGO,a4),d1
    andi.b  #$c0,d1 ; LR is retained in CH_FM_LR_FB_ALGO
    bsr     save_and_write_opm_panning_ch
.wp_done:
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

    btst.b  #5,(CH_CONFIG,a4)
    beq.b   .fm_key_on
    bsr     snd_midi_key_on
    bra     .kon_done

.fm_key_on:
    ; --- OPM key-on ---
    move.b  (CH_CONFIG,a4),d1
    and.b   #$07,d1             ; channel 0-7
    ; Get operator mask from instrument data
    ; Default = all operators = OPM_KON_ALL ($78)
    ori.b   #OPM_KON_ALL,d1
    move.b  #OPM_KON,d0
    bsr     write_opm_ch

.kon_done:
    rts


snd_midi_key_on:
    movem.l a2,-(SP)
    ; Get MIDI PSG channel index (0-2 from channel number 6-8)
    move.b  (CH_CONFIG,a4),d0
    and.w   #$0007,d0
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
    and.b   #$7f,d2

    ; Store note and send note-on
    move.w  (CH_FREQ,a4),d1
    move.b  d1,(a2,d0.w)
    bsr     midi_note_on
    movem.l (SP)+,a2    
    rts


; =============================================================================
; snd_key_off
; Trigger note-off for FM or MIDI channel
; a4 = channel block
; snd_rst_flag_key_off: equivalent to $0878 in Z80 code
; snd_key_off:  equivalent to $087c
; will modify d0 and d1 to write to OPM
; =============================================================================
snd_rst_flag_key_off:   ; called 3 times in original code
    bclr.b  #0,(CH_FX_FLAGS,a4)
snd_key_off:
    btst.b  #5,(CH_CONFIG,a4)
    bne     .snd_midi_key_off
    ; OPM key-off: write channel with no operator bits = all operators off
    move.b  (CH_CONFIG,a4),d0
    and.b   #$07,d0             ; channel only
    move.b  d0,d1               ; data = channel, operator bits all 0 = key-off
    move.b  #OPM_KON,d0
    bsr     write_opm
    rts

.snd_midi_key_off:
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
    movem.l (SP)+,a2
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
    movem.l d7,-(sp)
    ; Get algorithm from cached value in CH_MIDI_MIXER bits 2-0
    move.b  (CH_FM_LR_FB_ALGO,a4),d1
    and.w   #$0007,d1           ; keep algo only
    ; Load carrier mask for this algorithm
    lea     opm_attenuation_table,a0
    move.b  (a0,d1.w),d3        ; d3 = carrier mask bits 3-0
    ; Load FM chan and prepare register
    move.b  (CH_CONFIG,a4),d0
    and.b   #$07,d0
    add.b   #OPM_TL,d0          ; + $60 = TL register address
    ; Write 4 operators from preset TL location
    lea     ($4,a2),a2           ; TL value for this operator
    moveq   #3,d7               ; loop counter (4 operators)
.tl_loop:
    ; Read base TL from preset data
    move.b  (a2)+,d1            ; TL value for this operator
    btst    d7,d3               ; test operator attenuation bit
    beq     .tl_write           ; set → modulator, otherwise use TL unchanged
    add.b   d4,d1
    bpl.b   .tl_write
    move.b  #$7F,d1             ; clamp at max attenuation
.tl_write:
    bsr     write_opm_ch        ; write with disable check
    addq.b  #8,d0               ; next operator
    dbf     d7,.tl_loop
    movem.l (sp)+,d7
    rts

; =============================================================================
; snd_inst_ch_reset
; d0 = channel to reset
; save a4 as it will be overriden to access the channel block
; =============================================================================
snd_inst_ch_reset:     ;  $108f:
    movem.l  d7/a4,-(sp)
    mulu.w  #MUSIC_CH_SIZE,d0
    lea     (snd_music_ch),a4   ; point at channel base
    adda.w  d0,a4               ; and add block offset
    clr.b   (CH_DISABLE,a4)
    bsr     snd_rst_flag_key_off

    move.b  (CH_FM_AMS_PMS,a4),d1
    ; prepare OPM_PMS_AMS value
    ror.b   #$4,d1
    ; prepare first register
    move.b  (CH_CONFIG,a4),d2
    andi.b  #$07,d2
    move.b  d2,d0
    addi.b  #OPM_PMS_AMS,d0
    bsr     write_opm
    ; prepare OPM_LR_FB_CON value
    move.b  d2,d0
    addi.b  #OPM_LR_FB_CON,d0
    move.b  (CH_FM_LR_FB_ALGO,a4),d1
    bsr     write_opm

    ; start from $40 to $ff to set all operators to $ff
    move.b  d2,d0
    addi.b  #OPM_DT1_MUL,d0
    move.b  #$ff,d1
    move.w  #(24-1),d7      ; 24 operators from $40-$ff
.clear_fm_operators
    bsr     write_opm_ch
    addq.b  #$8,d2
    dbf     d7,.clear_fm_operators

    ; test pointer is present
    tst.l   (CH_PRESET_PTR,a4)
    beq     .leave
    tst.b   (snd_sample_update_flag)
    bne     .leave
    btst.b  #$0,(CH_FLAGS,a4)
    bne     .leave
    movea   (CH_PRESET_PTR,a4),a3
    adda.w  #$8,a3
    bsr     snd_write_fm_patch
    bsr     snd_calc_combined_volume
.leave
    movem.l  (sp)+,a4/d7
    rts

; =============================================================================
; snd_calc_combined_volume
; Calculate combined volume: (global_vol >> 1) + channel_vol, clamped $7F
; Equivalent of sub_08afh volume calculation
; a4 = channel block
; Returns: d4.b = combined TL offset
; =============================================================================
snd_calc_combined_volume:
    movea   (CH_PRESET_PTR,a4),a2
    adda.w  #$8,a2                 ; preset FM reg data source
    move.b  (snd_vol_accum),d4
    lsr.b   #1,d4               ; global >> 1 (half resolution for smooth fade)
    add.b   (CH_VOLUME,a4),d4   ; + channel volume
    cmp.b   #$7F,d4
    bls.b   .vol_ok
    move.b  #$7F,d4
.vol_ok:
    bsr     snd_write_tl_opm
    rts


; =============================================================================
; snd_write_fm_patch
; Write complete FM patch (all operators) to OPM registers
; a4 = channel block
; a3 = pointer to preset/patch data
;
; Patch data format (from Z80 instrument table, 29 bytes per patch):
; Based on $1022 in Z80 code
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
; YM2612 operator bytes in blocks of 6 for 6 channels in the following order:
; DT/MUL($30), TL($40), RS/AR($50), AM/DR($60), DT2/SR($70), SL/RR($80), SSG-EG($90)
; last register is FB/ALG: only requires 1 byte
; YM2151 operators will need to be saved in this order
; DT1/MUL($40), TL($60), KS/AR($80), AME/D1R($A0), DT2/D2R($C0), D1L/RR($E0), LR/FB/CON($20) <-- only for last byte
; last register is FB/ALG: only requires 1 byte
; Total: 4*6 + 1 = 25 bytes minimum (adjust based on actual patch table format)
; =============================================================================
snd_write_fm_patch:
    move.l  d7,-(sp)
    ; Get channel number
    move.b  (CH_CONFIG,a4),d5
    and.b   #$07,d5
    ; Turn volume off first $60-$7f
    move    d5,d0
    addi.b  #OPM_TL,d0
    move.b  #$7F,d1
    moveq   #(4-1),d7
.tl_loop:
    bsr     write_opm_ch
    addi.b  #$8,d0
    dbf     d7,.tl_loop
    ; MUL/DET   $40
    move    d5,d0
    addi.b  #OPM_DT1_MUL,d0
    moveq   #(4-1),d7
.muldt_loop:
    move.b  (a3)+,d1            ; DT/MUL byte from patch
    bsr     write_opm_ch
    addi.b  #$8,d0
    dbf     d7,.muldt_loop
    ; KS/AR   $80
    adda.w  #$4,a5      ; skip TL values
    move    d5,d0
    addi.b  #OPM_KS_AR,d0
    moveq   #(16-1),d7
.opm_reg:
    move.b  (a3)+,d1            ; DT/MUL->_KS/AR->AME/D1R->DT2/D2R->D1L/RR bytes from patch
    bsr     write_opm_ch
    addi.b  #$8,d0
    dbf     d7,.opm_reg
    adda.w  #$4,a5      ; skip SSG/EG
    ; FB ALGO
    move    d5,d0
    addi.b  #OPM_LR_FB_CON,d0
    move.b  (a3)+,d1
    ori.b   #$c0,d1     ; force LR to 1 during intialisation
    move.b  d1,(CH_FM_LR_FB_ALGO,a4)
    bsr     write_opm_ch
    move.l  (sp)+,d7
    rts

; =============================================================================
; snd_apply_effects  - $08cc in Z80 code
; Slide pitch toward target each tick
; a4 = channel block
; Equivalent of portamento section l08cch in Z80 driver
; =============================================================================
snd_apply_effects:
    ; Only FM channels have portamento
    tst.b   (snd_fade_ovf)
    beq     .next
    bsr     set_chan_volume
.next:
    bsr     snd_apply_portamento
    bsr     snd_apply_arpeggio
    rts


; =============================================================================
; save_and_write_opm_panning_ch
; d1: LR, AMS, PMS value to be saved to block register and written to
; enabled OPM registers
; YM2612 write this all at once to $B4+ (LR, AMS, PMS)but OPM needs to be
; adapted as these bits are split over 2 registers: OPM_LR_FB_CON/OPM_PMS_AMS
; =============================================================================
save_and_write_opm_panning_ch:
    ; save new value to block
    andi.b  #$3f,(CH_FM_LR_FB_ALGO,a4)
    move.b  d1,d3   ; save current reg value
    andi.b  #$c0,d3 ; keep LR
    or.b    d3,(CH_FM_LR_FB_ALGO,a4)
    andi.b  #$3f,d1
    move.b  d1,(CH_FM_AMS_PMS,a4)
    ; prepare OPM_PMS_AMS value
    ror.b   #$4,d1
    ; prepare first register
    move.b  (CH_CONFIG,a4),d2
    andi.b  #$07,d2
    move.b  d2,d0
    addi.b  #OPM_PMS_AMS,d0
    bsr     write_opm_ch
    ; prepare OPM_LR_FB_CON value
    move.b  d2,d0
    addi.b  #OPM_LR_FB_CON,d0
    move.b  (CH_FM_LR_FB_ALGO,a4),d1
    bra     write_opm_ch


; =============================================================================
; write_opm_panning
; d1: LR, AMS, PMS value value to be OPM registers
; YM2612 write this all at once to $B4+ (LR, AMS, PMS)but OPM needs to be
; adapted as these bits are split over 2 registers: OPM_LR_FB_CON/OPM_PMS_AMS
;
; =============================================================================
write_opm_panning:
    move.b  d1,d3   ; save current reg value
    andi.b  #$3f,d1 ; keep PMS AMS
    ; prepare OPM_PMS_AMS value
    ror.b   #$4,d1
    ; prepare first register
    move.b  (CH_CONFIG,a4),d2
    andi.b  #$07,d2
    move.b  d2,d0
    addi.b  #OPM_PMS_AMS,d0
    bsr     write_opm_ch
    ; prepare OPM_LR_FB_CON value
    move.b  d2,d0
    addi.b  #OPM_LR_FB_CON,d0
    ; prpare value
    andi.b  #$c0,d3 ; keep LR
    move.b  (CH_FM_LR_FB_ALGO,a4),d1
    andi.b  #$3f,d1 ; keep FB and ALGO
    or.b    d3,d1   ; add LR
    bra     write_opm_ch


snd_apply_portamento:
    btst.b  #5,(CH_CONFIG,a4)
    bne.b   .port_done  ; for PSG

    btst.b  #7,(CH_PORT_TARGET,a4)               ; bit 7 = direction flag (set by $EC command)
    beq.b   .port_down
    subq.b  #$1,(CH_PORT_BASE,a4)
    bne.b   .port_down
    move.b  (CH_FM_LR_FB_ALGO,a4),d0
    andi.b  #$c0,d0
    move.b  (CH_PORT_TARGET,a4),d1
    andi.b  #$3f,d1     ; AMS PMS
    or.b    d0,d1       ; add LR
    ; update OPM pan register
    bsr     save_and_write_opm_panning_ch
.port_down:
    ; Portamento
    btst.b  #1,(CH_FLAGS,a4)
    beq.b   .port_done
    subq.b  #$1,(CH_MIDI_SPEED,a4)  ; dec ix+$35 — MIDI portamento speed
    bne     .port_done
    ; reload counter
    move.b  (CH_MIDI_MIXER,a4),(CH_MIDI_SPEED,a4)   ;reload with ix+$34
    move.b  (CH_FX_FLAGS,a4),d0
    move.b  d0,d1
    andi.b  #$c0,d1
    cmpi.b  #$c0,d1
    beq     .l0921h
    ori.b   #$c0,d0
    eori.b  #$04,d0
    bra     .l092dh
.l0921h
    andi.b  #$3f,d0
    btst    #$2,d0
    beq     .l092bh
    ori.b   #$40,d0
    bra     .l092dh
.l092bh:
    ori.b   #$80,d0
.l092dh:
    move.b  d0,(CH_FX_FLAGS,a4)
    andi.b  #$c0,d0     ; LR
    move.b  (CH_FM_AMS_PMS,a4),d1
    andi.b  #$3f,d1
    or.b    d0,d1
    bsr     save_and_write_opm_panning_ch
.port_done:
    rts


; =============================================================================
; snd_apply_arpeggio (around $094b in Z80 code)
; Step through arpeggio pattern
; a4 = channel block
; =============================================================================
snd_apply_arpeggio:
    move.l  d0,-(sp)
    btst.b  #5,(CH_CONFIG,a4)
    bne     .arp_done
    btst.b  #$0,(CH_FX_FLAGS,a4)
    beq     .arp_done
    move.b  (CH_FLAGS,a4),d2
    btst    #$3,d2
    beq     .l09aah
	btst    #$2,d2
    bne     .l09aah
	; dec arp counter 1
    subq.b  #1,(CH_ARP_COUNTER,a4)
    bne     .arp_done
    ; Reload counter
    move.b  (CH_ARP_CTR_INIT,a4),d1
    move.b  d1,d0
    andi.b  #$1f,d0
    move.b  d0,(CH_ARP_COUNTER,a4)
    ; dec arp counter 2
    subq.b  #1,(CH_ARP_COUNTER2,a4)
    bne.b   .l09a2h
	btst    #$5,d1
	bne     .l098fh
	bset    #$2,d2
    move.b  d2,(CH_FLAGS,a4)
    bra     .l09aah
.l098fh:
    move.b  (CH_ARP_CTR_INIT,a4),(CH_ARP_COUNTER2,a4)
    eor.b   #$20,d2
    btst    #5,d2
    bne     .l099eh       ; and skip next if set
	eor.b   #$10,d2
.l099eh:
	move.b  d2,(CH_FLAGS,a4)
.l09a2h:
	btst    #4,d2
    bne     .l0a6fh
	bra     .l0a4dh
.l09aah:
	btst    #6,d2
    beq     .arp_done
    subq.b  #1,(CH_NOTE_REG,a4)
    bne     .arp_done
    btst.b  #$1,(CH_FX_FLAGS,a4)
    bne     .l0a26h		;09b5
    btst.b  #$5,(CH_CONFIG,a4)
    bne     .l09dbh		;09bb
    moveq   #0,d0
    moveq   #0,d1
    move.b  (CH_BASE_NOTE,a4),d0
    move.b  (CH_ARP_M1,a4),d1
    mulu.w  d0,d1
    move.w  d1,(CH_ARP_S1,a4)
    moveq   #0,d1
    move.b  (CH_ARP_M2,a4),d1
    mulu.w  d0,d1
    move.w  d1,(CH_ARP_S2,a4)
    bra     .l0a09h		    ;09d8
.l09dbh:
	moveq   #0,d0
    moveq   #0,d1
    move.b  (CH_BASE_NOTE,a4),d0
    move.b  (CH_ARP_M1,a4),d1
    mulu.w  d0,d1
    moveq   #0,d3
    move.b  (CH_ARP_M2,a4),d3
    mulu.w  d0,d3
    move.b  (CH_OCTAVE,a4),d0
    andi.w  #$00ff,d0
    beq     .l09fdh
    .l09f3h:    ; d1 = de, d3 = hl
        ror.w   #1,d1
        ror.w   #1,d3
        dbf  d0,.l09f3h
.l09fdh:
    move.w  d3,(CH_ARP_S2,a4)
    move.w  d1,(CH_ARP_S1,a4)
 .l0a09h:
	bset    #7,d2
    move.b  (CH_ARP_M4,a4),d0
    btst.b  #7,(CH_ARP_M5,a4)
    bne     .l0a19h	;0a12
	bclr    #7,d2
    move.b  (CH_ARP_M3,a4),d0
.l0a19h:
    lsr.b   #1,d0
    move.b  d0,(CH_ARP_COUNTER2,a4)
    move.b  #$80,(CH_VIB_ACCUM,a4)
	bset.b  #1,(CH_FX_FLAGS,a4)
.l0a26h:
	move.b  (CH_ARP_M5,a4),d0
    andi.b  #$1f,d0
    move.b  d0,(CH_NOTE_REG,a4)
    subq.b  #1,(CH_ARP_COUNTER2,a4)
    bne     .l0a46h
	btst    #7,d2
	beq     .l0a3eh
	bclr    #7,d2
	move.b  (CH_ARP_M3,a4),d0
    bra     .l0a43h		;0a3c
.l0a3eh:
	bset    #7,d2
    move.b  (CH_ARP_M4,a4),d0
.l0a43h:
	move.b  d0,(CH_ARP_COUNTER2,a4)
.l0a46h:
	move.b  d2,(CH_FLAGS,a4)
	btst    #7,d2
    bne     .l0a6fh	;0a4b
.l0a4dh:
    move.w  (CH_ARP_S1,a4),d0
    moveq   #$0,d2
    move.b  (CH_VIB_ACCUM,a4),d2
    add.w   d2,d0
    move.b  d0,(CH_VIB_ACCUM,a4)
    and.w   #$ff00,d0
    beq     .arp_done
    lsr.w   #$8,d0
    add.w   d0,(CH_VIB_DELTA,a4)
    ;bsr     snd_apply_vibrato
    bsr     snd_write_frequency
    bra     .arp_done
.l0a6fh:
	move.w  (CH_ARP_S2,a4),d0
    moveq   #$0,d2
    move.b  (CH_VIB_ACCUM,a4),d2
    sub.w   d2,d0
    move.b  d0,(CH_VIB_ACCUM,a4)
    and.w   #$ff00,d0
    beq     .arp_done
    lsr.w   #$8,d0
    sub.w   d0,(CH_VIB_DELTA,a4)   ; was (CH_VIB_DELTA,a2) — see note above
    ;bsr     snd_apply_vibrato
	bsr     snd_write_frequency
.arp_done:
    move.l  (sp)+,d0
    rts


; =============================================================================
; snd_setup_vib_arp
; Compute arpeggio step sizes (CH_ARP_S1/S2) and initial vibrato delta
; from CH_VIB_DEPTH, then initialise arpeggio counters.
; a4 = channel block. Gated on CH_FLAGS bit 3 (arpeggio enable) by the
; caller, exactly as the Z80 gates entry to sub_075fh via sub_075ah.
; Equivalent of sub_075fh.
;
; CH_ARP_S1/S2 double as vibrato's rise/fall step sizes when arpeggio
; itself isn't stepping through a pattern — see snd_apply_arpeggio's
; shared .l0a4dh/.l0a6fh tail, which both arpeggio and vibrato funnel
; through. Without this routine those fields were never populated for
; the vibrato case (only snd_apply_arpeggio's own arpeggio-pattern
; branch wrote them, via a different multiplier pair).
;
; arp_step1 = CH_BASE_NOTE * CH_ARP_INTERVAL (FM path — no PSG octave
; shift needed on OPM). vib_delta = round(arp_step1 * CH_VIB_DEPTH / 256),
; derived and verified against the Z80's bit-serial multiply/carry
; sequence (5000 random cases, zero mismatches) earlier in this project;
; reduces to a single 16x8 multiply plus a rounding-carry check on 68000,
; no need to replicate the Z80's H*E bit-serial routine.
; =============================================================================
snd_setup_vib_arp:
    btst.b  #3,(CH_FLAGS,a4)
    beq.b   .no_vib_arp_setup

    bclr.b  #2,(CH_FLAGS,a4)        ; res 2,(ix+CH_FLAGS) — clear flag 2

    ; arp_step1 = CH_BASE_NOTE * CH_ARP_INTERVAL (FM path only — PSG's
    ; octave right-shift has no OPM equivalent and PSG is MIDI on X68000)
    moveq   #0,d0
    move.b  (CH_BASE_NOTE,a4),d0
    moveq   #0,d1
    move.b  (CH_ARP_INTERVAL,a4),d1
    mulu.w  d1,d0                   ; d0 = arp_step1 (16-bit result fits:
                                     ; max 255*255 = 65025)
    move.w  d0,(CH_ARP_S1,a4)
    move.w  d0,(CH_ARP_S2,a4)

    ; vib_delta = round(arp_step1 * CH_VIB_DEPTH / 256)
    moveq   #0,d1
    move.b  (CH_VIB_DEPTH,a4),d1
    mulu.w  d1,d0                   ; d0 = arp_step1 * vib_depth (32-bit)
    move.l  d0,d3
    lsr.l   #8,d3                   ; d3 = product >> 8 (pre-rounding)
    move.b  d0,d2                   ; d2.b = low byte of the product
    addi.b  #$80,d2                 ; ld a,l / add a,$80 — this single op
                                     ; both produces the vibrato
                                     ; accumulator init value (d2 itself,
                                     ; truncated to a byte) AND sets the
                                     ; carry flag exactly when the
                                     ; rounding should bump vib_delta
    move.b  d2,(CH_VIB_ACCUM,a4)
    bcc.b   .no_round_carry
    addq.w  #1,d3
.no_round_carry:

    btst.b  #7,(CH_PAN_FLAGS,a4)    ; bit 7,(ix+$2e) — invert flag
    beq.b   .no_invert
    neg.w   d3                      ; negate for inverted vibrato
.no_invert:
    move.w  d3,(CH_VIB_DELTA,a4)

    ; Vibrato direction flag: CH_FLAGS bit 4, from CH_PAN_FLAGS bit 6
    move.b  (CH_FLAGS,a4),d4
    bclr    #4,d4
    btst.b  #6,(CH_PAN_FLAGS,a4)
    beq.b   .no_dir
    bset    #4,d4
.no_dir:
    move.b  d4,(CH_FLAGS,a4)

    ; Initialise arpeggio counters
    move.b  (CH_ARP_BASE,a4),(CH_ARP_COUNTER,a4)
    move.b  (CH_ARP_CTR_INIT,a4),(CH_ARP_COUNTER2,a4)

    bset.b  #5,(CH_FLAGS,a4)        ; set arpeggio active flag
.no_vib_arp_setup
    rts


; =============================================================================
; snd_apply_vibrato
; =============================================================================
snd_apply_vibrato:
    move.w  (CH_FREQ,a4),d0 ; d0 = STABLE base (KeyCode<<8)|KeyFraction
    move.b  d0,d2                ; d2 = base KeyFraction (0-63)
    move.b  d0,d4                ; d4 = base KeyCode
    lsr.b   #4,d4                ; d4 = base octave
    move.b  d0,d5
    andi.b  #$0F,d5               ; d5 = base note nibble (with gaps)

    ; Recover a contiguous chromatic index (0-11) from the note nibble,
    ; since opm_note_table's values skip 3/7/11 and aren't directly
    ; usable as an index themselves.
    bsr     snd_note_nibble_to_index   ; d5(nibble) -> d5(0-11 index)

    ; Split CH_VIB_DELTA the same way CH_FINETUNE is split
    move.w  (CH_VIB_DELTA,a4),d1
    move.w  d1,d3
    asr.w   #FINETUNE_UNITS_SHIFT,d3   ; d3 = signed semitone carry
    add.w   d2,d1                      ; fold low bits in before masking,
                                        ; so KeyFraction accumulates with
                                        ; full precision over many ticks
    move.w  d1,d2
    asr.w   #FINETUNE_UNITS_SHIFT,d2   ; extra carry from the addition above
    add.w   d2,d3                      ; d3 = total semitone carry
    move.w  d1,d2
    andi.w  #FINETUNE_FRAC_MASK,d2     ; d2 = new 0-63 KeyFraction

    add.w   d3,d5                      ; d5 = chromatic index + total carry
    bsr     snd_wrap_keycode           ; d5,d4 -> d1 = new KeyCode

    lsl.w   #8,d1
    or.w    d2,d1
    move.w  d1,(CH_FREQ,a4)
    rts

; =============================================================================
; snd_note_nibble_to_index
; Convert an OPM note nibble (with gaps at 3/7/11) back to a contiguous
; chromatic index (0-11), i.e. the inverse of opm_note_table.
; In:  d5.b = OPM note nibble (0,1,2,4,5,6,8,9,10,12,13,14)
; Out: d5.w = chromatic index (0-11)
; Clobbers: a0, d6
; =============================================================================
snd_note_nibble_to_index:
    movem.l d6,-(SP)
    lea     opm_note_table,a0
    moveq   #11,d6
.search:
    cmp.b   (a0,d6.w),d5
    beq.b   .found
    dbf     d6,.search
    moveq   #0,d6                ; not found — default to C (shouldn't happen)
.found:
    move.w  d6,d5
    movem.l (SP)+,d6
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

    ; Apply fade step: use snd_fade_step as step size (mirrors $0007 usage)
    move.b  (snd_fade_step),d0
    and.b   #$7F,d0             ; 7-bit step
    add.b   d0,(snd_vol_accum)
    bpl     .fd_done

    ; Fade complete — silence and reset
    clr.b   (snd_fade_speed)
    move.b  #$3F,(snd_status)   ; return to idle
    bsr     snd_silence_all_opm
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
    movem.l d7,-(SP)
    lea     (snd_music_ch),a4
    moveq   #FM_MUSIC_COUNT-1,d7
.fv_loop:
    btst.b  #0,(CH_FLAGS,a4)    ; skip inactive
    bne.b   .fv_next
    ; FM: calculate combined volume and write TL
    bsr     snd_calc_combined_volume ; d4 = combined TL
    bsr     snd_write_tl_opm
.fv_next:
    lea     (MUSIC_CH_SIZE,a4),a4
    dbf     d7,.fv_loop
    movem.l (SP)+,d7
    rts

; =============================================================================
; snd_silence_all
; Key-off all OPM channels and send MIDI note-offs
; =============================================================================
snd_silence_all:
    bra     snd_silence_all_opm

init_driver_interface:  ; $01df
    clr.b   (snd_track)
    ; Clear all channel blocks to zero
    bsr     snd_clear_all_channels
    clr.b   (snd_fade_speed)
    clr.b   (snd_vol_accum)
    move.b  #$3F,(snd_status)
    move.b  #$3F,(snd_psg_mixer)
    move.b  #02,(snd_tempo_div)



    rts

; =============================================================================
; snd_load_track
; Load track data and initialise music channel blocks
; $0203 in Z80 code
; Called when snd_track is non-zero
; =============================================================================
snd_load_track:
    ; Save FM channel disable states
    move.l  d7,-(sp)
    lea     (snd_music_ch),a4
    lea     (snd_saved_disable),a1
    moveq   #FM_MUSIC_COUNT-1,d7
.save_loop:
    move.b  (CH_DISABLE,a4),(a1)+
    lea     (MUSIC_CH_SIZE,a4),a4
    dbf     d7,.save_loop

    moveq   #0,d1
    move.b  (snd_track),d1
    bsr     init_driver_interface

    ; Restore FM channel disable states (restore_fm_channel_data_byte_1 equiv)
    lea     (snd_music_ch),a4
    lea     (snd_saved_disable),a1
    moveq   #FM_MUSIC_COUNT-1,d7
.restore_loop:
    move.b  (a1)+,(CH_DISABLE,a0)
    lea     (MUSIC_CH_SIZE,a4),a4
    dbf     d7,.restore_loop

    ; snd_track is 1-based (dec a in sub_0203h makes it base-0 for table lookup)
    subq.w  #1,d1                ; base-0 (matches dec a in sub_0203h)
    add.w   d1,d1                ; d1 = track entry position
    moveq   #0,d3
    move.b  (snd_bank),d3        ; d3 = bank (0 or 1) — used for table select below

    ; --- Resolve bank base address ---
    ; Z80: ld bc,M68K_MEM_SPACE (bc = $8000, the bank window base)
    ; X68000: select snd_bank_base[bank] — the absolute RAM address
    ; where this bank's data was loaded. Must be indexed by the actual
    ; bank number; always reading entry 0 only works by coincidence
    ; when both banks happen to be laid out contiguously in RAM.
    lsl.w   #2,d3                ; bank * 4 (longword index into table)
    lea     (snd_bank_base),a0
    movea.l (a0,d3.w),a0          ; update a0 => a0 = snd_bank_base[bank]
    movea.l a0,a5                 ; a5 = temp bank base
    adda.w  d1,a5                 ; + track's entry position

    ; --- Resolve the track's own absolute address ---
    ; Z80: ld a,(hl) / inc hl / ld h,(hl) / ld l,a — read the track's
    ; offset-table entry (little-endian word), then add hl,bc ($8000)
    ; to get the track's absolute address, saved to l1398h.
    moveq   #$0,d2
    move.b  (a5)+,d0
    move.b  (a5)+,d2
    lsl.w   #8,d2
    or.w    d0,d2                ; d2 = track data stream position in bank
    movea.l a0,a5                ; a5 = bank base again
    adda.w  d2,a5                ; a5 = bank base + track data stream offset
    move.l  a5,(snd_track_ptr)   ; save it to RAM (Z80: ld (l1398h),hl)
    movea.l a5,a6                ; a6 = track data stream address (like iy in Z80 code)

    ; Word 0: LFO setting
    ; Z80: write (iy+$01) to YM2612 reg $22 (LFO enable/freq)
    ; X68000: map to OPM registers $18 (LFRQ) and $1B (CT/waveform)
    move.b  (a5)+,d2            ; first byte is always $02
    ; second byte → OPM LFRQ ($18)
    move.b  (a5)+,d1
    move.b  #OPM_LFRQ,d0
    bsr     write_opm
    ; High byte → OPM CT/waveform ($1B) if non-zero
    move.b  d2,d1               ; get first byte
    beq.b   .no_lfo_wave
    move.b  #OPM_CT_W,d0
    bsr     write_opm
.no_lfo_wave:

    ; Words 1-9: per-channel stream pointers
    moveq   #0,d2   ; FM channel index
    lea     (snd_music_ch),a4   ; always try to use a4 to point at music or instrument blocks
    moveq   #FM_MUSIC_COUNT-1,d7
.fm_ch_init:
    bsr     init_common_block_vars
    ; FM specific
    move.b  #$c0,(CH_FM_LR_FB_ALGO,a4)
    addq    #$1,d2   ; inc index
    lea     (MUSIC_CH_SIZE,a4),a4   ; next block
    dbf     d7,.fm_ch_init

    moveq   #$20,d2   ; PSG/Midi channel index
    moveq   #-$A,d3   ; PSG/Midi MIXER
    moveq   #MIDI_MUSIC_COUNT-1,d7
.midi_ch_init:
    bsr     init_common_block_vars
    ; PSG/Midi specific
    move.b  d3,(CH_PSG_MASK,a4)
    rol.b   #$1,d3
    addq    #$1,d2   ; inc index
    lea     (MUSIC_CH_SIZE,a4),a4   ; next block
    dbf     d7,.midi_ch_init

    ; Words 10-13: FM preset table base addresses
    moveq   #(PRESET_COUNT-1),d7
    lea     (snd_preset_ptrs),a1
.preset_ptrs:
    moveq   #0,d0
    move.b  (a5)+,d0
    move.b  (a5)+,d1
    lsl.w   #8,d1
    or.w    d0,d1               ; offset
    movea.l a6,a0               ; start of stream
    adda.w  d1,a0               ; add preset offset
    move.l  a0,(a1)+            ; store pointer
    dbf     d7,.preset_ptrs

    ; Reset sequencer state (confirmed from sub_0203h)
    clr.b   (snd_status)        ; $00 = playing
    clr.b   (snd_tempo_frac)    ; l1391h+1 = 0
    clr.b   (snd_ch_stop_count) ; l139ah = 0 — reset channels-stopped count
    clr.b   (snd_tempo_ovf)     ; l1391h+2 = 0
    clr.b   (snd_fade_flag)     ; l1394h = 0
    clr.b   (snd_fade_ovf)      ; l1395h = 0
    clr.b   (snd_fade_accum)    ; l1396h = 0
    move.b  #$7F,(snd_tempo_base) ; l1391h = $7F (default tempo)
    ; --- sub_02e0h equivalent: silence all FM channels ---
    bsr     snd_silence_all_opm
    move.l  (sp)+,d7
    rts

; =============================================================================
; init_common_block_vars
; a5= data ptr, a4= block pointer, d2= ch index
; =============================================================================
init_common_block_vars:
    ; Read channel offset word (little-endian)
    moveq   #0,d0
    move.b  (a5)+,d0            ; low byte
    move.b  (a5)+,d1            ; high byte
    lsl.w   #8,d1
    move.b  d0,d1               ; d1 = offset within bank (0-32767)
    movea.l a6,a0               ; start of stream
    adda.w  d1,a0               ; add music channel offset
    move.l  a0,(CH_STREAM_PTR,a4)   ; save stream point to block
    ; Also set loop pointer to same address (sub_02c0h sets both equal)
    move.l  a0,(CH_LOOP_PTR,a4)
    ; common init values for FM and PSG - index is incremented
    move.b  #$01,(CH_DURATION,a4)
    move.b  #$04,(CH_OCTAVE,a4)
    move.b  d2,(CH_CONFIG,a4)
    move.b  #$01,(CH_FX_DURATION,a4)
    move.b  #$7f,(CH_VOLUME,a4)
    move.b  #$c0,(CH_FX_FLAGS)
    rts


; =============================================================================
; snd_silence_all_opm
; Silence all OPM channels and reset frequency registers
; Equivalent of sub_02e0h (FM portion only — PSG replaced by MIDI silence)
; =============================================================================
snd_silence_all_opm:
    movem.l  d6-d7/a4,-(sp)
    ; Set TL = $7F (max attenuation) for all 32 operator slots
    lea     (snd_music_ch),a4
    moveq   #FM_MUSIC_COUNT-1,d7
.silence_chan_loop:
    move.b  #$7F,d1 ; reg value for all operators
    move.b  (CH_CONFIG,a4),d0
    andi.b  #$7,d0  ; keep chan
    move.b  d0,d2   ; saved for KON
    addi.b  #OPM_DT1_MUL,d0     ; add 1st reg to modify
    moveq   #(6-1),d6   ; 6 OPM from $40(OPM_DT1_MUL) to $FF
    .silence_op_reg:
        bsr     write_opm_ch
        addq.b  #$8,d0  ; next operator
        dbf     d6,.silence_op_reg
    ; do KEY on and move block pointer
    move.b  d2,d1 ; KON reg value
    move.b  #OPM_KON,d0
    bsr     write_opm_ch
    lea     (MUSIC_CH_SIZE,a4),a4
    dbf     d7,.silence_chan_loop

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
    movem.l  (sp)+,a4/d7-d6
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
    move.b  d0,d2               ; preserve d0 and save it to d2
    and.w   #$001f,d2           ; lower 5 bits = command index 0-31
    lsl.w   #2,d2               ; * 4 for longword table
    lea     .ext_table,a0
    move.l  (a0,d2.w),a1
    jmp     (a1)

; d0 = 1st byte; d1 = 2nd byte
.ext_table:
    dc.l    ecmd_E0_tempo      ; $E0 set tempo
    dc.l    ecmd_E1_finetune   ; $E1 set fine-tune
    dc.l    ecmd_E2_vibrato    ; $E2 set vibrato
    dc.l    ecmd_E3_oct_dn     ; $E3 octave down (single byte)
    dc.l    ecmd_E4_oct_up     ; $E4 octave up (single byte)
    dc.l    ecmd_E5_volume     ; $E5 set volume
    dc.l    ecmd_E6_arpeggio   ; $E6 set arpeggio
    dc.l    ecmd_E7_sustain    ; $E7 sustain on (single byte)
    dc.l    ecmd_E8_nop        ; $E8 NOP (single byte)
    dc.l    ecmd_E9_noise      ; $E9 PSG noise → MIDI percussion
    dc.l    ecmd_EA_mixer      ; $EA PSG mixer → MIDI CC10 pan
    dc.l    ecmd_EB_port       ; $EB portamento enable/disable
    dc.l    ecmd_EC_portgt     ; $EC portamento target (3 bytes)
    dc.l    ecmd_ED_EE_ED_panning ; $ED LFO depth high (single byte)
    dc.l    ecmd_ED_EE_ED_panning        ; $EE LFO depth mid (single byte)
    dc.l    ecmd_ED_EE_ED_panning        ; $EF LFO depth low (single byte)
    ; $F0-$FF: from second dispatch table in original (l0427h beyond index 15)
    ; Extend here as those routines are identified
    dc.l    ecmd_F0_l0b63h        ; $F0
    dc.l    ecmd_F1_l0b75h        ; $F1
    dc.l    ecmd_F2_l0b80h        ; $F2
    dc.l    ecmd_F3_l0b8bh        ; $F3
    dc.l    ecmd_F4_l0b98h        ; $F4
    dc.l    ecmd_F5_set_counter   ; $F5 l0baeh: set counter slot = value from param
    dc.l    ecmd_F6_dec_br_nz     ; $F6 l0bbeh: dec counter, branch if not zero
    dc.l    ecmd_F7_dec_br_z      ; $F7 l0bd8h: dec counter, branch if zero
    dc.l    ecmd_F8_br_if_eq      ; $F8 l0bf2h: branch if counter == param
    dc.l    ecmd_F9_inc_counter   ; $F9 l0c0fh: increment counter slot
    dc.l    ecmd_FA_dec_counter   ; $FA l0c18h: decrement counter slot
    dc.l    ecmd_FB_jump          ; $FB l0c21h: unconditional branch
    dc.l    ecmd_FC_call          ; $FC l0c28h: call (branch + save return)
    dc.l    ecmd_FD_call_if_eq    ; $FD l0c42h: conditional call
    dc.l    ecmd_FE_return        ; $FE l0c5ch: return from call
    dc.l    ecmd_FF_stop          ; $FF l0c6fh: stop channel / end of track

; --- $E0: set tempo (l04a9h) ---
; a = second_byte + 6, stored as tempo base
ecmd_E0_tempo:
    add.b   #6,d1
    move.b  d1,(snd_tempo_base)
    rts

; --- $E1: set fine-tune (l04afh) ---
ecmd_E1_finetune:
    move.b  d1,(CH_FINETUNE,a4)
    rts

; --- $E2: set vibrato (l04b3h) ---
; d1=0 → disable. d1≠0 → enable and copy 6 bytes (d1 + 5 stream bytes)
; a5= data stream
; a4= block pointer
ecmd_E2_vibrato:
    bclr.b  #6,(CH_FLAGS,a4)
    tst.b   d1
    beq.b   .vib_done
    bset.b  #6,(CH_FLAGS,a4)
    move.b  d1,(CH_VIB_PARAMS,a4)
    lea     (CH_VIB_PARAMS,a4),a1
    move.b  d1,(a1)+
    REPT 5
        move.b  (a5)+,(a1)+
    ENDR
    bclr.b  #1,(CH_FX_FLAGS,a4)
.vib_done:
    rts

; --- $E3: octave down (l04d6h) — single byte, back up stream ---
ecmd_E3_oct_dn:
    subq.l  #1,a5
    subq.b  #1,(CH_OCTAVE,a4)
    rts

; --- $E4: octave up (l04dbh) — single byte ---
ecmd_E4_oct_up:
    subq.l  #1,a5
    addq.b  #1,(CH_OCTAVE,a4)
    rts

; --- $E5: set volume (l04e0h / l04e3h) ---
ecmd_E5_volume:
    move.b  d1,(CH_VOLUME,a4)
set_chan_volume:
    btst.b  #5,(CH_CONFIG,a4)
    bne.b   .vol_midi
    ; FM: calculate combined volume and write TL
    bsr     snd_calc_combined_volume    ; d4.b = combined TL
    bsr     snd_write_tl_opm
    bra     .leave_ecmd_E5
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
.leave_ecmd_E5:
    rts

; --- $E6: set arpeggio (l04edh) ---
; d1=0 → disable. d1≠0 → load 5-byte pattern from arp table
ecmd_E6_arpeggio:
    bclr.b  #3,(CH_FLAGS,a4)
    tst.b   d1
    beq.b   .arp_done_cmd
    bset.b  #3,(CH_FLAGS,a4)
    subq.b  #1,d1               ; base-0 index
    moveq   #0,d0
    move.b  d1,d0
    mulu.w  #5,d0               ; 5 bytes per pattern
    move.l  (snd_arp_ptr),a0
    adda.l  d0,a0
    lea     (CH_ARP_BASE,a4),a1
    REPT 5
        move.b  (a0)+,(a1)+
    ENDR
    ; If note playing, recalculate
    btst.b  #0,(CH_FX_FLAGS,a4)
    beq.b   .arp_done_cmd
    bsr     snd_calc_frequency
.arp_done_cmd:
    rts

; --- $E7: sustain on (l052ch) — single byte ---
ecmd_E7_sustain:
    subq.l  #1,a5
    bset.b  #5,(CH_FX_FLAGS,a4)
    rts

; --- $E8: NOP (l0530h) — single byte ---
ecmd_E8_nop:
    subq.l  #1,a5
    rts

; --- $E9: PSG noise → MIDI percussion (l0532h) ---
; Only for MIDI channels (bit 5 of CH_CONFIG)
ecmd_E9_noise:
    btst.b  #5,(CH_CONFIG,a4)
    beq.b   .e9_done            ; FM channel — ignore
    ; Map noise parameter to GM drum note
    move.b  d1,d0
    lsr.b   #3,d0
    and.w   #$0007,d0
    lea     (midi_noise_map),a2
    move.b  (a2,d0.w),d1        ; GM note number
    move.b  #MIDI_PERCUSSION,d0
    move.b  #100,d2             ; velocity
    bsr     midi_note_on
.e9_done:
    rts

; --- $EA: PSG mixer → MIDI CC10 pan (l054ah) ---
ecmd_EA_mixer:
    btst.b  #5,(CH_CONFIG,a4)
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
ecmd_EB_port:
    bclr.b  #1,(CH_FLAGS,a4)
    tst.b   d1
    beq.b   .eb_done
    btst.b  #5,(CH_CONFIG,a4)   ; MIDI: ignore portamento
    bne.b   .eb_done
    bset.b  #1,(CH_FLAGS,a4)
    move.b  d1,(CH_PORT_SPEED,a4)
    move.b  d1,(CH_MIDI_SPEED,a4)
.eb_done:
    rts

; --- $EC: portamento target ($058e and $0594)
ecmd_EC_portgt:
    btst.b  #5,(CH_CONFIG,a4)
    bne.b   ec_midi
set_portgt:
    ; FM portamento target
    clr.b   (CH_PORT_TARGET,a4)
    tst.b   d1
    beq.b   ec_done
    move.b  d1,(CH_PORT_SPEED,a4)
    move.b  (a5)+,d1            ; read third byte
    bset    #7,d1               ; set direction flag
    move.b  d1,(CH_PORT_TARGET,a4)
    btst.b  #0,(CH_FX_FLAGS,a4)
    beq.b   ec_done
    bsr     snd_write_panning
    bra.b   ec_done
ec_midi:
    tst.b   d1
    beq.b   ec_done
    addq.l  #1,a5               ; skip third byte
ec_done:
    rts

; --- $ED(R)/$EE(L)/$EF(L+R): Set opm panning d0 bits 1-0 = LR ($05b0) — single byte ---
ecmd_ED_EE_ED_panning:
    subq.l  #1,a5               ; single byte command
    btst.b  #5,(CH_CONFIG,a4)
    bne.b   lfo_midi
    ; FM: extract LFO depth from command bits 7-6, write to OPM $20+ch
    move.b  d0,d1               ; d0 = original command byte
    ror     #2,d1
    and.b   #$c0,d1             ; extract bits 7-6
    move.b  (CH_FX_FLAGS,a4),d2
    and.b   #$3F,d2
    or.b    d1,d2
    move.b  d2,(CH_FX_FLAGS,a4)
    move.b  (CH_FM_AMS_PMS,a4),d1
    and.b   #$3F,d2
    or.b    d2,d1
    bsr     save_and_write_opm_panning_ch
    rts
lfo_midi:
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

; --- $F0: l0b63h equivalent — compute (l139fh_value + a*8), store to
; ix+$15/ix+$16.
ecmd_F0_l0b63h:  ; d1 = command's own parameter byte (the Z80 'a')
    lsl.b   #3,d1
	and.w   #$00ff,d1
    movea.l (snd_inst_preset_ptr),a2
	adda.w  d1,a2
    move.l  a2,(CH_INST_PTR,a4)
    rts

; --- $F1: l0b75h equivalent — increment global_flag_table[param] ---
; Z80 builds an absolute zero-page address "a + $000A" via the
; add/adc/sub zero-extend idiom; ported here as an index into the
; dedicated snd_global_flag_table (see its declaration for why this
; can't reuse the stream pointer a5 or channel block a4 — confirmed
; via l0b98h sharing the identical "$000a" base).
ecmd_F1_l0b75h:  ; d1 = command's own parameter byte (0-255)
    and.w   #$00ff,d1
    lea     (snd_global_flag_table),a2
    addq.b  #1,(a2,d1.w)
    rts

; --- $F2: l0b80h equivalent — decrement global_flag_table[param] ---
ecmd_F2_l0b80h:
    and.w   #$00ff,d1
    lea     (snd_global_flag_table),a2
    subq.b  #1,(a2,d1.w)
    rts

; --- $F3: l0b8bh equivalent — global_flag_table[param] = next stream byte ---
ecmd_F3_l0b8bh:
    move.b  (a5)+,d2             ; e = (hl); inc hl
    and.w   #$00ff,d1
    lea     (snd_global_flag_table),a2
    move.b  d2,(a2,d1.w)
    rts

; --- $F4: l0b98h equivalent — conditional stream branch ---
; Z80: if global_flag_table[param] == next_stream_byte, read a further
; stream WORD and jump the channel's stream pointer to
; (snd_track_ptr + that word); otherwise continue normally (the
; stream-byte and stream-word bytes are still consumed either way in
; the Z80 original — "ld a,(hl)/inc hl/ld e,(hl)/inc hl/ld d,(hl)/inc hl"
; advances hl past all 3 bytes BEFORE the cp/ret nz check, so a5 must
; advance past all 3 bytes here too regardless of which branch is taken).
ecmd_F4_l0b98h:  ; d1 = command's own parameter byte
    and.w   #$00ff,d1
    move.b  (a5)+,d2              ; a = (hl) — expected value to compare
    move.b  (a5)+,d3              ; e = next byte (word low)
    move.b  (a5)+,d4              ; d = next byte (word high)
    lea     (snd_global_flag_table),a2
    move.b  (a2,d1.w),d0
    cmp.b   d2,d0
    bne.b   .f4_no_match           ; Z80: ret nz — table value didn't match
    lsl.w   #8,d4
    move.b  d3,d4                 ; d4 = de = the stream word, little-endian
    movea.l (snd_track_ptr),a5
    adda.w  d4,a5                  ; a5 = track_ptr + de — branch taken
.f4_no_match:
    rts

; =============================================================================
; Extended commands $F5-$FF — loop/counter/branch engine
; These are the music format's control-flow primitives: a set of 4
; per-channel counters (ix+$11-$14 / CH_COUNTER_SLOT0-3) and matching
; conditional/unconditional branch instructions that jump within the
; current channel's stream using offsets relative to snd_track_ptr
; (the track's base address in RAM, equivalent to the Z80's (track_ptr)).
;
; Branch target addressing (all branch commands):
;   target = snd_track_ptr + (high_byte << 8 | low_byte)
;   where high_byte and low_byte come from the stream (in little-endian
;   order: low_byte is the param / auto-read byte, high_byte is the
;   next stream byte read inside the handler), EXCEPT:
;   - $F5/$F9/$FA: no branch, no stream bytes beyond param
;   - $FB: param = low byte, next stream byte = high byte, NO inc past
;           the high byte on Z80 (hl replaced wholesale by add hl,de),
;           equivalent here to reading one more byte and then replacing
;           a5 entirely — matching the analysis from the walker
;
; Counter selection ($F5/$F6/$F7/$F8/$F9/$FA/$FD):
;   slot = (relevant_byte >> 6) & 3  → selects CH_COUNTER_SLOT0..3
;   ($F5 is the exception: slot = param & 3, value = param >> 2)
;
; $FC/$FE: call/return pair using CH_TMP_INST_PTR + CH_LOOP_PTR
;   $FC saves current stream position (a5) to CH_LOOP_PTR, saves
;        CH_INST_PTR to CH_TMP_INST_PTR, then branches
;   $FE restores CH_LOOP_PTR to a5 and CH_TMP_INST_PTR to CH_INST_PTR
;
; Dispatcher calling convention (all handlers):
;   d0.b  = original command byte (opcode, for $ED/$EE/$EF style)
;   d1.b  = auto-read param byte (already consumed from stream)
;   a4    = channel block
;   a5    = stream pointer (past opcode and param byte)
;   All handlers return via rts; dispatcher (jmp via table) handles
;   the return to snd_save_stream_ptr
; =============================================================================

; --- $F5: l0baeh — set counter slot to value ---
; param byte: bits 1-0 = slot (0-3), bits 7-2 = value (0-63)
; 1 stream byte consumed (param only, no extra bytes)
ecmd_F5_set_counter:
    move.b  d1,d2
    and.w   #$0003,d2             ; d2 = slot 0-3
    move.b  d1,d3
    lsr.b   #2,d3               ; d3 = value (bits 7-2 >> 2 = 0-63)
    ;lea     (CH_COUNTER_BASE,a4),a0
    ;move.b  d3,(a0,d2.w)
    move.b  d3,(CH_COUNTER_BASE,a4,d2.w)
    rts

; --- $F6: l0bbeh — decrement counter; branch to track_ptr+offset if NOT zero ---
; "loop back while counter > 0, fall through when it hits 0"
; param (d1) = offset low byte; next stream byte: bits 7-6 = slot, bits 5-0 = offset high
; 2 stream bytes consumed (param + 1 extra)
ecmd_F6_dec_br_nz:
    move.b  (a5)+,d2            ; d2 = extra byte (slot in bits 7-6, offset hi in bits 5-0)
    move.b  d2,d3
    lsr.b   #6,d3               ; d3 = slot 0-3
    and.w   #$0003,d3
    lea     (CH_COUNTER_BASE,a4),a0
    subq.b  #1,(a0,d3.w)        ; dec slot
    beq.b   .f6_done            ; hit zero — fall through (Z80: ret z)
    ; Not zero — branch
    and.b   #$3F,d2             ; d2 = offset high (6 bits)
    moveq   #0,d4
    move.b  d1,d4               ; d4 = offset low (param)
    lsl.w   #8,d2
    or.w    d2,d4               ; d4 = 14-bit offset
    movea.l (snd_track_ptr),a5
    adda.w  d4,a5
.f6_done:
    rts

; --- $F7: l0bd8h — decrement counter; branch to track_ptr+offset if ZERO ---
; "exit loop when counter hits 0, loop back while > 0" (inverse of $F6)
; Same byte layout as $F6
ecmd_F7_dec_br_z:
    move.b  (a5)+,d2
    move.b  d2,d3
    lsr.b   #6,d3
    and.w   #$0003,d3
    lea     (CH_COUNTER_BASE,a4),a0
    subq.b  #1,(a0,d3.w)
    bne.b   .f7_done            ; not zero — fall through (Z80: ret nz)
    ; Zero — branch
    and.b   #$3F,d2
    moveq   #0,d4
    move.b  d1,d4
    lsl.w   #8,d2
    or.w    d2,d4
    movea.l (snd_track_ptr),a5
    adda.w  d4,a5
.f7_done:
    rts

; --- $F8: l0bf2h — branch to track_ptr+offset if counter[slot] == param ---
; param (d1) = comparison value; next 2 stream bytes: [offset low] [slot_in_7-6 + offset_hi_in_5-0]
; 3 stream bytes consumed (param + 2 extra)
ecmd_F8_br_if_eq:
    move.b  (a5)+,d2            ; offset low byte
    move.b  (a5)+,d3            ; slot/offset-hi byte
    move.b  d3,d4
    lsr.b   #6,d4
    and.w   #$0003,d4           ; d4 = slot 0-3
    lea     (CH_COUNTER_BASE,a4),a0
    cmp.b   (a0,d4.w),d1        ; compare param against counter slot value
    bne.b   .f8_done            ; mismatch — fall through (Z80: ret nz)
    and.b   #$3F,d3
    lsl.w   #8,d3
    or.b    d2,d3               ; d3 = 14-bit offset
    movea.l (snd_track_ptr),a5
    adda.w  d3,a5
.f8_done:
    rts

; --- $F9: l0c0fh — increment counter[param] ---
; param = offset from ix+$11 (0=slot0, 1=slot1, 2=slot2, 3=slot3)
; 1 stream byte consumed (param only)
ecmd_F9_inc_counter:
    and.w   #$0003,d1           ; clamp to 0-3
    lea     (CH_COUNTER_BASE,a4),a0
    addq.b  #1,(a0,d1.w)
    rts

; --- $FA: l0c18h — decrement counter[param] ---
; Same layout as $F9
ecmd_FA_dec_counter:
    and.w   #$0003,d1
    lea     (CH_COUNTER_BASE,a4),a0
    subq.b  #1,(a0,d1.w)
    rts

; --- $FB: l0c21h — unconditional absolute branch ---
; target = snd_track_ptr + (next_byte << 8 | param)
; param (d1) = offset low; next stream byte = offset high
; Z80: ld e,a / ld d,(hl) — reads d from (hl) then "hl = track_ptr + de"
; replaces hl entirely, so the extra byte IS consumed (hl moves past it
; via the wholesale replacement, unlike a plain ld that would leave hl
; pointing at it — here the offset arithmetic skips it implicitly).
; Net: 2 stream bytes consumed, a5 replaced with the branch target.
ecmd_FB_jump:
    moveq   #0,d2
    move.b  (a5)+,d2            ; offset high byte (d in Z80)
    lsl.w   #8,d2
    move.b  d1,d2               ; d2 = (high<<8)|low = branch offset
    movea.l (snd_track_ptr),a5
    adda.w  d2,a5
    rts

; --- $FC: l0c28h — call (branch + save return position and CH_INST_PTR) ---
; param (d1) = offset low; next stream byte = offset high
; Saves: a5+1 (position after the extra byte) → CH_LOOP_PTR
;        CH_INST_PTR → CH_TMP_INST_PTR (mirrors ix+$15/$16 → ix+$0f/$10)
; Then branches to snd_track_ptr + offset.
; 2 stream bytes consumed before branch; return position is a5 as it
; stands after the second byte (matching Z80's "ld (ix+$0d),l after inc hl").
ecmd_FC_call:
    moveq   #0,d2
    move.b  (a5)+,d2            ; offset high byte
    ; Save return position (current a5, which is past both param and high byte)
    move.l  a5,(CH_LOOP_PTR,a4)
    ; Save CH_INST_PTR → CH_TMP_INST_PTR (ix+$15/$16 → ix+$0f/$10)
    move.l  (CH_INST_PTR,a4),d3
    move.l  d3,(CH_TMP_INST_PTR,a4)
    ; Branch
    lsl.w   #8,d2
    move.b  d1,d2               ; d2 = branch offset
    movea.l (snd_track_ptr),a5
    adda.w  d2,a5
    rts

; --- $FD: l0c42h — conditional call (branch + save only if counter == param) ---
; param (d1) = compare value; next 2 bytes: [offset low] [slot_7-6 + offset_hi_5-0]
; If counter[slot] == param: saves return pos and CH_INST_PTR, then branches
; If mismatch: consumes all 3 bytes, falls through (Z80: ret nz after all reads)
; 3 stream bytes consumed in all cases.
ecmd_FD_call_if_eq:
    move.b  (a5)+,d2            ; offset low byte
    move.b  (a5)+,d3            ; slot_hi byte
    move.b  d3,d4
    lsr.b   #6,d4
    and.w   #$0003,d4           ; slot 0-3
    lea     (CH_COUNTER_BASE,a4),a0
    cmp.b   (a0,d4.w),d1
    bne.b   .fd_done            ; mismatch — bytes already consumed, fall through
    ; Match — save return position and CH_INST_PTR, then branch
    move.l  a5,(CH_LOOP_PTR,a4)
    move.l  (CH_INST_PTR,a4),d5
    move.l  d5,(CH_TMP_INST_PTR,a4)
    and.b   #$3F,d3
    lsl.w   #8,d3
    or.b    d2,d3               ; 14-bit offset
    movea.l (snd_track_ptr),a5
    adda.w  d3,a5
.fd_done:
    rts

; --- $FE: l0c5ch — return (restore CH_LOOP_PTR → a5, CH_TMP_INST_PTR → CH_INST_PTR) ---
; Reverses a previous $FC or $FD call.
; Param byte consumed by dispatcher but not used.
ecmd_FE_return:
    movea.l (CH_LOOP_PTR,a4),a5
    move.l  (CH_TMP_INST_PTR,a4),(CH_INST_PTR,a4)
    rts

; --- $FF: l0c6fh — stop channel / end of track ---
; Mark this channel inactive, increment the global stopped-channel
; counter, and if all MUSIC_CH_COUNT channels have stopped, set the
; driver to idle and silence everything.
; Z80: "pop bc" discards a return address because l0c6fh is a JP target
; (not called with CALL). Here the dispatcher uses JMP so there is no
; extra address to discard — the rts at the end returns correctly.
; Param byte consumed by dispatcher but not used.
ecmd_FF_stop:
    addq.L  #4,SP    ; discard JMP return address
    bset.b  #0,(CH_FLAGS,a4)            ; channel inactive
    addq.b  #1,(snd_ch_stop_count)
    cmp.b   #MUSIC_CH_COUNT,(snd_ch_stop_count)
    bne.b   .ff_done                    ; not all stopped yet
    ; All channels stopped — set driver idle and silence everything
    move.b  #$3F,(snd_status)
    move.b  #$3F,(snd_psg_mixer)
    bsr     snd_silence_all_opm
.ff_done:
    rts

ecmd_r_15h_16h:  ; d1 is the value modify and it returns d0 - $0b56?
    and.w   #$0007,d1       ; clamp index to 0-7 (max 8 entries)
    movea.l (CH_INST_PTR,a4),a2
    adda.w  d1,a2
    move.b  (a2),d0
    rts


; =============================================================================
; snd_load_preset
; Load FM or MIDI preset from preset table ($80-$BF command handler)
; d2.b = preset index (bits 5-0)
; a4 = channel block, a5 = stream pointer
; $05db (FM) / $0618 (PSG/MIDI)
; =============================================================================
snd_load_preset:
    move.l  a5,-(sp)    ; save stream pointer
    btst.b  #5,(CH_CONFIG,a4)
    bne     .midi_preset

    ; --- FM preset: 36-byte entries (file format, not RAM block size) ---
    moveq   #0,d0
    move.b  d2,d0
    mulu.w  #37,d0    ; see l05dbh in Z80 code
    move.l  (snd_fm_preset_ptr),a5
    adda.l  d0,a5

    ; Store preset pointer in channel block (MUSIC_PRESET_LO/HI)
    move.l  a5,(CH_PRESET_PTR,a4)

    ; Load vibrato from preset byte 0
    movea.l a5,a3       ; save a5 to a3 setting vibrato
    move.b  (a5)+,d1
    bsr     ecmd_E2_vibrato
    movea.l a3,a5       ; restore a5
    addq.l  #$6,a5      ; skip 6 bytes
    ; Load portamento target (sub_0594h equivalent)
    move.b  (a5)+,d1
    movea.l a5,a3       ; save a5 to a3 setting portamento
    bsr     set_portgt
    movea.l a3,a5       ; restore a5
    addq.l  #1,a5               ; skip one byte
    bsr     snd_write_fm_patch  ; a5 points to patch data like load_music_preset_ptr_to_iy in Z80 code
    ; Apply FM parameters (sub_08afh equivalent)
    bsr     snd_calc_combined_volume
    bra.b   .load_exit
.midi_preset:
    ; --- MIDI preset: 16-byte entries ---
    moveq   #0,d0
    move.b  d2,d0
    lsl.w   #4,d0               ; index * 16
    move.l  (snd_midi_preset_ptr),a5
    adda.l  d0,a5

    ; Store preset pointer
    move.l  a5,(CH_PRESET_PTR,a4)

    ; Load vibrato from byte 0
    move.b  (a5)+,d1
    movea.l a5,a3       ; save a5 to a3 setting vibrato
    bsr     ecmd_E2_vibrato
    movea.l a3,a5       ; restore a5
    adda.w  #$000e,a5      ; skip 14 bytes
    ; Skip to MIDI mixer byte (offset 14 from preset base — mirrors l0618h $0E)
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
.load_exit
    move.l  (sp)+,a5    ; restore stream pointer
    rts


; =============================================================================
; snd_rel_volume
; Relative volume change command ($C0-$CF)
; d0.b = command byte (lower nibble = signed offset -8..+7)
; a4 = channel block
; Equivalent of l0658h
; =============================================================================
snd_rel_volume:
    move.l  a5,-(sp)    ; save stream pointer
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
    bsr     set_chan_volume
    move.l  (sp)+,a5    ; restore stream pointer
    rts

; =============================================================================
; snd_duration_lookup
; Convert duration index to tick count
; d0.b = index (0-15, upper nibble of note byte pre-shifted)
; Returns d0.b = tick count
; Equivalent of $0b56
; =============================================================================
snd_duration_lookup:
    andi.w  #$0007,d0
    movea.l (CH_INST_PTR,a4),a0
    move.b  (a0,d0.w),d0
    rts


; =============================================================================
; snd_process_sfx
; Process all instrument channels — called every timer B interrupt
; Equivalent of l0d97h
; =============================================================================
snd_process_sfx:
    move.l  d7,-(sp)
    ; Check for instrument trigger
    tst.b   (snd_re_lock)
    bne     .end_inst_tick
    move.b  #$ff,(snd_re_lock)
    ; Process all 4 instrument channel blocks
    lea     (snd_inst_ch),a4
    moveq   #INST_CH_COUNT-1,d7
.inst_loop:
    bsr     snd_inst_channel_tick
    lea     (INST_CH_SIZE,a4),a4
    dbf     d7,.inst_loop
.end_inst_tick:
    move.l  (sp)+,d7
    rts


; =============================================================================
; snd_inst_channel_tick
; Process one instrument channel tick
; a4 = instrument channel block
; $0dbe in Z80 code
; =============================================================================
snd_inst_channel_tick:
    move.l  d7,-(sp)
    ; Check active flag (INST_STATUS bit 0)
    btst.b  #0,(INST_STATUS,a4)
    beq     .ict_done

    clr.b  (snd_re_lock)
    ; Advance fractional step accumulator (ix+$1f / ix+$22)
    add.b   (INST_STEP_RATE,a4),d0
    add.b   d0,(INST_FRAC_ACCUM,a4)
    bcc     .ict_done           ; no overflow — skip this tick

    ; Decrement duration counter (ix+$1c)
    subq.b  #1,(INST_DURATION,a4)
    bne.b   .ict_effects        ; not expired → effects only
    ; 0ddf
    ; Duration expired — read next event
    bsr     snd_inst_read_event

.ict_effects:
    ; Apply pitch update (l0f45h equivalent — vibrato/LFO update)
    bsr     snd_inst_pitch_update

.ict_done:
    move.l  (sp)+,d7
    rts


; =============================================================================
; snd_inst_read_event
; Read and dispatch next event from instrument channel data
; a4 = instrument channel block
; Equivalent of event dispatch in snd_inst_channel_tick / $0ddf
; =============================================================================
snd_inst_read_event:
    ; Load 32-bit stream pointer
    move.l  (CH_STREAM_PTR,a4),a5
.read_inst_data
    move.b  (a5)+,d0            ; read event byte
    move.b  d0,d2
    ; Check lower nibble for command vs note
    move.b  d0,d1
    and.b   #$0f,d1
    cmp.b   #$0f,d1
    bne.b   .inst_note          ; lower != $0F → note/duration event
    ; Command: upper nibble = index
    move.b  (a5)+,d1            ; read second byte
    and.w   #$00f0,d2
    lsr.b   #2,d2               ; point at long words
    lea     .inst_cmd_table,a0
    move.l  (a0,d2.w),a1
    jsr     (a1)
    bra     .read_inst_data
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
    move.l  a5,(CH_STREAM_PTR,a4)   ; save inst data stream pointer
    move.b  d0,d1
    and.b   #$0f,d1
    cmp.b   #$0e,d1
    beq     .leave_read_event
    cmp.b   #$0d,d1
    beq.b   .sfx_calc_freq
	move.b  d0,(INST_OCTAVE_NOTE,a4)
	bsr     snd_key_off
	cmp.b   #$0c,d1
    beq     .leave_read_event
.sfx_calc_freq
	move.b  (INST_OCTAVE_NOTE,a4),d0 ; load note reg
	move.b  d0,d1
    lsr.b   #$4,d1
    andi.b  #$07,d1
    move.b  d1,(CH_OCTAVE,a4)   ; keep d1 for later
    ; almost common code to snd_calc_freq
    bsr     snd_inst_calc_frequency
    ; end of common code
    clr.w   (CH_VIB_DELTA,a4)
    move.b  #$80,(CH_VIB_ACCUM,a4)
    bclr.b  #$2,(INST_STATUS,a4)
    bsr     snd_key_on
    bsr     snd_write_frequency
.leave_read_event:
    rts

; Instrument command dispatch table (l00b2h_table equivalent)
; d0 = first byte, d1 = second byte (in Z80 code, b is first byte, a is second byte
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
    dc.l    .ic_stop            ; $XF stop channel

; --- $X0: set step rate (l0e02h) ---
.ic_set_rate:
    move.b  d1,(INST_STEP_RATE,a4)
    rts

; --- $X1/$X2/$X3: panning from command bits (l0e06h) ---
; Panning encoded in upper nibble of command byte × 4, bits 7-6 result
.ic_pan_cmd:    ; TODO add FB and CON to OPM_LR_FB_CON value
    suba    #$1,a5  ; unconsume last fetched byte
    lsl.b   #$2,d0
    andi.b  #$c0,d0
    andi.b  #$3f,(INST_STATUS,a4)
    or.b    d0,(INST_STATUS,a4)
    move.b  d0,d1   ; save d0 to d1 to write value to opm register
    ; Writing to OPM is done in 2 stages to match OPN2:
    ; 1) first, use LR from d0 bit7-6 and add FB + CH_FM_ALGO + CONFIGFB_CON to $20+ch
    move.b  (CH_FM_LR_FB_ALGO,a4),d2

    move.b  (CH_CONFIG,a4),d0
    add.b   #OPM_LR_FB_CON,d0
    bsr     write_opm
    ; 2) clear AMS_PMS
    clr     d1
    move.b  (CH_CONFIG,a4),d0
    and.b   #$07,d0
    add.b   #OPM_PMS_AMS,d0
    bsr     write_opm
    rts

; --- $X4: load FM patch (l0e22h) ---
; Patch entry = 29 bytes at inst_table + (index * 29)
.ic_load_patch:
    move.l  d7,-(sp)
    moveq   #0,d0
    move.b  d1,d0   ; save second byte to d0
    mulu.w  #29,d0  ; patch length
    movea.l (snd_inst_table_ptr),a3 ; get sfx data base pointer
    move.b  ($0,a3),d2
    move.b  ($1,a3),d1
    lsl.w   #$8,d1
    move.b  d2,d1
    adda.w  d1,a3   ; add sfx header
    adda.w  d0,a3   ; add patch offset
    move.l  a3,(CH_LOOP_PTR,a4)
    ; Write patch to OPM
    move.w  #(4-1),d7
    move.b  (CH_CONFIG,a4),d0
    and.b   #$07,d0     ; load channel only
    add.b   #(OPM_D1L_RR),d0     ; add decay release register offset
    move.b  #$ff,d1     ; reg value
    .update_ss_sl_reg:
        bsr     write_opm
        add.b   #$8,d0      ; next operator
        dbf     d7,.update_ss_sl_reg
    bsr     snd_write_fm_patch
    bsr     .snd_inst_volume
    move.l  (sp)+,d7
    rts

; --- $X5: set volume (l0e5ch) ---
.ic_set_vol:
    move.b  d1,(CH_VOLUME,a4)
    bsr     .snd_inst_volume
    rts

; =============================================================================
; snd_inst_volume ($0ffd in Z80 code)
; Calculate combined volume: inst_chan_varation + channel_vol, clamped $7F
; a4 = channel block
; =============================================================================
.snd_inst_volume:
	movea   (CH_LOOP_PTR,a4),a2 ; preset data source
	move.b  (INST_VOL_VAR,a4),d4
    add.b   (CH_VOLUME,a4),d4   ; + channel volume
    cmp.b   #$7F,d4
    bls.b   .vol_ok
    move.b  #$7F,d4
.vol_ok:
    bsr     snd_write_tl_opm
    rts

; --- $X6: load vibrato data (l0e62h) ---
; Copy 5 bytes from stream to instrument channel block at +$15
.ic_load_vib:
    bset.b  #1,(INST_STATUS,a4)
    lea     (INST_VIB_PARAM,a4),a1
    REPT 5
        move.b  (a5)+,(a1)+
    ENDR
    bclr.b  #2,(INST_STATUS,a4)
    rts

; --- $X7: vibrato enable (l0e7ch) ---
.ic_vib_on:
    suba    #$1,a5  ; unconsume last fetched byte
    bset.b  #1,(INST_STATUS,a4)
    rts

; --- $X8: vibrato disable (l0e82h) ---
.ic_vib_off:
    suba    #$1,a5  ; unconsume last fetched byte
    bclr.b  #1,(INST_STATUS,a4)
    rts

; --- $X9: panning from snd_pan register (l0e88h) ---
.ic_pan_from_reg:
    suba    #$1,a5  ; unconsume last fetched byte
    move.b  (snd_pan),d0
    and.b   #$03,d0
    ror.b   #2,d0               ; scale bits 1-0 to bits 7-6
    andi.b  #$3f,(INST_STATUS,a4)
    or.b    d0,(INST_STATUS,a4)
    ; 1) first, use LR from d0 bit7-6 and add FB + CH_FM_ALGO + CONFIGFB_CON to $20+ch
    move.b  d0,d1   ; save d0 to d1 to write value to opm register
    bra     write_opm_panning

; --- $XA: expression from snd_expression (l0ea6h) ---
.ic_expr_from_reg:
    suba    #$1,a5  ; unconsume last fetched byte
    move.b  (snd_expression),(CH_PORT_TARGET,a4)    ; ix+$1e
    rts

; --- $XB: set fine-tune (l0eaeh) ---
.ic_finetune:
    move.b  d1,(CH_FINETUNE,a4)
    rts

; --- $XC/$XD/$XE: NOP (l0eb2h) ---
.ic_nop:
   suba    #$1,a5  ; unconsume last fetched byte
   rts

; --- $XF: stop channel ($0eb4) ---
.ic_stop:
    addq.L  #4,SP    ; discard JSR return address
    bclr.b  #0,(INST_STATUS,a4)     ; clear active flag
    clr.b   (INST_OP_MASK,a4)      ; clear priority ($23)
    move.b  (INST_CH_IDX,a4),d0
    bra     snd_inst_ch_reset


; =============================================================================
; snd_inst_pitch_update
; Per-tick vibrato/LFO update for instrument channels
; Equivalent of l0f45h
; =============================================================================
snd_inst_pitch_update:
    ; Check vibrato enable (INST_STATUS b1-0 set)
    move.b  (INST_STATUS,a4),d0
    move.b  d0,d1   ; save for later
    cmpi.b  #$03,d0
    bne     .ipu_done
    move.b  (INST_DUR_VAR,a4),d0
    lsl.b   #$1,d0
    add.b   d0,(INST_VIB_CALC,a4)
    bcc     .ipu_done
    btst    #$2,d1
	bne     .l0f98h		;0f5e
    clr.w   d0
    clr.w   d2
    move.b  (INST_BASE_NOTE,a4),d2
    move.b  (INST_VIB_PARAM,a4),d0
    mulu.w  d2,d0
    lsl.w   #$1,d0
    move.w  d0,(INST_VIB_RESULT,a4)
    move.b  (INST_VIB_PARAM2,a4),d0
    mulu.w  d2,d0
    lsl.w   #$1,d0
    move.w  d0,(INST_VIB_RESULT2,a4)
    bset    #$3,d1  ; set flag 3 in satus reg
	move.b  (INST_DURATION2,a4),d0
    btst.b  #$7,(INST_DUR_VAR,a4)
    bne     .l0f8dh
    bclr    #$3,d1  ; clear flag 3 in satus reg
    move.b  (INST_DURATION1,a4),d0
.l0f8dh:
	lsr.b   #$1,d0
	move.b  d0,(INST_VIB_SUBCOUNTER,a4)
	move.b  #$80,(CH_VIB_ACCUM,a4)
	bset    #$2,d1  ; set flag 2 in satus reg
.l0f98h:
    subq.b  #$1,(INST_VIB_SUBCOUNTER,a4)
	beq     .l0fb0h
	btst    #$3,d1
    beq     .l0fa8h
    bclr    #$3,d1  ; clear flag 3 in satus reg
    move.b  (INST_DURATION1,a4),d0
    bra     .l0fadh		;0fa6
.l0fa8h:
	bset    #$3,d1  ; set flag 3 in satus reg
    move.b  (INST_DURATION2,a4),d0
.l0fadh:
	move.b  d0,(INST_VIB_SUBCOUNTER,a4)
.l0fb0h:
	move.b  d1,(INST_STATUS,a4)
	btst    #$3,d1
    bne     .l0fd9h
    ; add CH_VIB_ACCUM to CH_VIB_DELTA
	move.w  (INST_VIB_RESULT,a4),d0
    moveq   #$0,d2
    move.b  (CH_VIB_ACCUM,a4),d2
    add.w   d2,d0
    move.b  d0,(CH_VIB_ACCUM,a4)
    and.w   #$ff00,d0
    beq     .ipu_done
    lsr.w   #$8,d0
    add.w   d0,(CH_VIB_DELTA,a4)
    bra     snd_write_frequency
.l0fd9h:
	; substract CH_VIB_ACCUM from
	move.w  (INST_VIB_RESULT2,a4),d0
    moveq   #$0,d2
    move.b  (CH_VIB_ACCUM,a4),d2
    sub.w   d2,d0
    move.b  d0,(CH_VIB_ACCUM,a4)
    and.w   #$ff00,d0
    beq     .ipu_done
    lsr.w   #$8,d0
    sub.w   d0,(CH_VIB_DELTA,a4)
	bra     snd_write_frequency
.ipu_done:
    rts


; =============================================================================
; snd_load_instrument
; Equivalent of sub_0cach
; Called when snd_instrument is non-zero
; Will load up to 4 channels from sfx data
; sfx data is $77, $00, fx0 priority, fx0 abs data lsb, fx0 abs data msb,...
; from fxn address: channel count, chan0 abs data stream ptr lsb, msb, etc...
; =============================================================================
snd_load_instrument:
    move.l  d7,-(sp)
    move.b  (snd_instrument),d0 ; save sfx id
    beq     .leave_loading
    clr.b   (snd_instrument)   ; acknowledge

    move.b  d0,d6               ; store current value
    andi.b  #$7F,d0             ; mask bit 7 for sfx index
    ; Check for stop-all ($7F)
    cmp.b   #$7F,d0
    beq     .stop_loading_insts
    ; Calculate table entry (3 bytes per entry: op_mask, addr_lo, addr_hi)
    subq.b  #$1,d0               ; base-0 index
    moveq   #$0,d1
    move.b  d0,d1
    mulu.w  #$3,d1
    movea.l (snd_inst_table_ptr),a0     ; keep as base address to save pointers
    ; read sfx 3 byte header starting from byte 2
    move.b  ($2,a0,d1.w),d2     ; sfx priority
    move.b  ($3,a0,d1.w),d3     ; sfx data addr lsb
    move.b  ($4,a0,d1.w),d4     ; sfx data addr msb
    lsl.w   #8,d4
    move.b  d3,d4               ; 16-bit offset
    movea.l a0,a1
    add.w   d4,a1               ; a1 = start of sfx data
    btst    #$7,d6               ; original bit 7 set? d6 no longer needed
    beq.b   .mask_ok
    move.b  #$FF,d2             ; override priority
.mask_ok:
    move.b  d2,(snd_op_mask)
    ; load sfx blocks
    lea     (snd_inst_ch),a4    ; block ptr
    moveq   #INST_CH_COUNT,d6
    moveq   #$0,d7
    move.b  (a1)+,d7        ; number of inst channels
    subq.b  #1,d7
.patch_sfx_loop:
    move.b  (a1)+,d0        ; data stream ptr lo
    move.b  (a1)+,d1        ; data stream ptr lo
    lsl.w   #8,d1
    move.b  d0,d1               ; 16-bit offset
    lea     (a0,d1.w),a2    ; set address to base + offset
    move.l  a2,(CH_STREAM_PTR,a4)
    move.b  d6,d0      ; d0 is the index value used in init_inst_block
    bsr     init_inst_block            ; populate inst block
    ; Z80 code ($0d63)
    ; 1. key off chan
    ; 2. only enabled LR in YM2612_LR_PMS_AMS
    ; 3. set the associated music channel disable flag (CH_DISABLE)
    ; write 0 to OPM_PMS_AMS    as shared with LR on the YM2612
    bsr     snd_key_off
    move.b  d6,d0      ; restore chan id
    addi.b  #OPM_PMS_AMS,d0
    clr.b   d1
    bsr     write_opm
    ; write LR to OPM_LR_FB_CON
    move.b  d6,d0      ; restore chan id
    addi.b  #OPM_LR_FB_CON,d0
    move.b  #$c0,d1
    bsr     write_opm
    ; set disable/pause flag in associated music channel
    moveq   #$0,d0
    move.b  (INST_CH_IDX,a4),d0
    mulu.w  #MUSIC_CH_SIZE,d0
    lea     (snd_music_ch),a5   ; point at music chan block base
    lea     (a5,d0.w),a5        ; points at the correct music chan block
    move.b  #$ff,(CH_DISABLE,a5)
    ; final reg to be updated in the sfx block
    bset.b  #$0,(INST_STATUS,a4)
    ; process next inst block if needed
    lea     (INST_CH_SIZE,a4),a4
    dbf     d7,.patch_sfx_loop
    ; tidy flag before leaving
    clr.b   (snd_re_lock)
    clr.b   (snd_op_mask)
    bra     .leave_loading
.stop_loading_insts:
    bsr     snd_stop_all_inst
.leave_loading:
    move.l  (sp)+,d7
    rts

snd_stop_all_inst:
    ; Stop all active instrument channels (l0d80h equivalent)
    move.l  d7,-(sp)
    lea     (snd_inst_ch),a4
    moveq   #INST_CH_COUNT-1,d7
.stop_loop:     ; $0eb5
    bclr.b  #0,(INST_STATUS,a4)
    beq.b   .stop_next
    clr.b   (INST_OP_MASK,a4)      ; clear priority ($23)
    move.b  (INST_CH_IDX,a4),d0
    bsr     snd_inst_ch_reset
.stop_next:
    lea     (INST_CH_SIZE,a4),a4
    dbf     d7,.stop_loop
    move.l  (sp)+,d7
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
snd_cmd_play_music:
    move.b  d0,(snd_bank)
    move.b  d1,(snd_track)      ; non-zero = track load pending
    clr.b   (snd_sample_update_flag)   ; clear any pending force update
    rts

; snd_cmd_stop_music
; Stop music with fade-out
; d0.b = fade speed (accumulation rate)
; d1.b = fade step size (= ch_count value)
snd_cmd_stop_music:
    move.b  d0,(snd_fade_speed)
    move.b  d1,(snd_fade_step)
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
snd_bank:           ds.b    1       ; track bank select (0/1) $4
snd_track:          ds.b    1       ; track index to load (0=none) $5
snd_fade_speed:     ds.b    1       ; fade accumulation rate $6
snd_fade_step:      ds.b    1       ; active channels $07 or $09 (used as fade step)
snd_status:         ds.b    1       ; $3F=idle $00=busy - $8
snd_vol_accum:      ds.b    1       ; global volume accumulator (internal) $9
                    ds.b    1       ; unused ($000A)
snd_pause:          ds.b    1       ; $00=play $01=pause ($000B?)
                    ds.b    4       ; unused ($000C-$000F)
snd_sample:         ds.b    1       ; ADPCM: $FF=active $00=stopped
snd_z80_tmr         ds.b    1       ; unused ($0011)
snd_instrument:     ds.b    1       ; instrument trigger ($0012)
snd_pan:            ds.b    1       ; panning value (bits 1-0) ($0013)
snd_expression:     ds.b    1       ; expression / velocity ($0014)
snd_op_mask:        ds.b    1       ; operator mask when loading instrument ($0015)
snd_re_lock:        ds.b    1       ; reentrancy lock ($0016)

; --- Sequencer internal state ---
snd_sample_update_flag:
                    ds.b    1       ; $FF=sample is being refreshed which will stop music ticking ($0010)
snd_tempo_div:      ds.b    1       ; tempo divider counter (mirrors l1390h)
snd_tempo_base:     ds.b    1       ; tempo base value (mirrors l1391h)
snd_tempo_frac:     ds.b    1       ; fractional accumulator (mirrors l1392h)
;snd_tempo_acc:      ds.w    1       ; tempo base value (mirrors l1391h)
snd_tempo_ovf:      ds.b    1       ; overflow flag (mirrors l1393h)
snd_fade_flag:      ds.b    1       ; fade enable (mirrors l1394h)
snd_fade_ovf:       ds.b    1       ; overflow fade flag (mirrors l1395h)
snd_ch_stop_count:  ds.b    1       ; channels-stopped counter (mirrors
                                    ; l139ah) — incremented by the $FF
                                    ; extended command (track-end/stop);
                                    ; when it reaches MUSIC_CH_COUNT (9),
                                    ; the driver is set idle. Reset to 0
                                    ; on every track load.
snd_fade_accum:     ds.b    1       ; fade step accumulator (mirrors l1396h)
snd_psg_mixer:      ds.b    1       ; global MIDI/PSG mixer state (mirrors l1397h)

; --- Track and asset pointers (replace Z80 bank+offset system) ---
    align 4
snd_track_ptr:      ds.l    1       ; current track base pointer (track itself,
                                    ; NOT the bank base — used for header parsing)
snd_bank_base:      ds.l    2       ; absolute base address of bank 0 / bank 1
                                    ; in music_data RAM, set by setup_driver_assets.
                                    ; Header offsets in the track data are relative
                                    ; to THIS, not to snd_track_ptr — the two are
                                    ; only equal for the very first track in a bank.
snd_track_table:    ds.l    32      ; pointers to decompressed track data in RAM
snd_preset_ptrs:                    ; 4 pointers initialised in sub_0203h
snd_fm_preset_ptr:      ds.l    1 ; FM preset table base
snd_midi_preset_ptr:    ds.l    1 ; MIDI/PSG preset table base
snd_inst_preset_ptr:    ds.l    1 ;
snd_arp_ptr:            ds.l    1 ;

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

; Saved supervisor stack pointer (set by _SUPER call in snd_init)
saved_ssp:          ds.l    1

; --- MIDI note tracking (for note-off) ---
snd_midi_notes:     ds.b    3       ; current note per MIDI PSG channel (0-2)

; --- Saved channel disable states (across track changes) ---
snd_saved_disable:  ds.b    MUSIC_CH_COUNT

    even
;   temp tables until we know their exact sizes
snd_global_flag_table:
    ds.b    256
snd_inst_table_ptr:
    ds.l    1   ; pointer to sfx_data set in soundtest.s
