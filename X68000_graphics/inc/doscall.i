; =============================================================================
; doscall.i — Human68k DOS Call Definitions
;
; Human68k DOS calls are F-line instructions: the entire $FFxx word IS the
; instruction. There is no separate TRAP. Usage:
;
;   move.w  d0,-(sp)        ; push parameter(s), word-aligned
;   DOS _PUTCHAR            ; expands to dc.w $FF02
;   addq.l  #2,sp           ; pop parameter(s)
;
; All parameters are pushed right-to-left and must be word or longword sized
; (never push a single byte — it misaligns the stack and causes an address
; error on the next instruction).
;
; Reference: Human68k DOSCALL specification (doscall.man)
; =============================================================================

; -----------------------------------------------------------------------
; DOS macro — emits the F-line word for a given doscall name
; Usage: DOS _PUTCHAR
; -----------------------------------------------------------------------
DOS MACRO
    dc.w    __DOS_\1
    ENDM


; =============================================================================
; Character I/O
; =============================================================================
__DOS__EXIT0       equ $FF00   ; _EXIT — terminate (no return code)
__DOS__GETCHAR     equ $FF01   ; _GETCHAR — read char from stdin, no echo
__DOS__PUTCHAR     equ $FF02   ; _PUTCHAR — write char to stdout (push word)
__DOS__COMINP      equ $FF03   ; _COMINP — direct console input check
__DOS__COMOUT      equ $FF04   ; _COMOUT — direct console output
__DOS__COMISNS     equ $FF05   ; _COMISNS — console input status
__DOS__COMOSNS     equ $FF06   ; _COMOSNS — console output status
__DOS__INPOUT      equ $FF07   ; _INPOUT — char I/O combined
__DOS__INKEY       equ $FF08   ; _INKEY — non-blocking key check
__DOS__PRINT       equ $FF09   ; _PRINT — print string (push longword ptr,
                                ;          string ends with $00 or $0D)
__DOS__KFLUSH      equ $FF0C   ; _KFLUSH — flush keyboard buffer
__DOS__FFLUSH      equ $FF0D   ; _FFLUSH — flush file buffers
__DOS__CHGDRV      equ $FF0E   ; _CHGDRV — change current drive
__DOS__DRVCTRL     equ $FF0F   ; _DRVCTRL — drive control

__DOS__KEYCHK      equ $FF12   ; _KEYCHK — keyboard sense
__DOS__KEYCTRL     equ $FF13   ; _KEYCTRL — keyboard control

__DOS__GETENV      equ $FF53   ; _GETENV — get environment variable
__DOS__VERIFY      equ $FF54   ; _VERIFY — set verify flag


; =============================================================================
; File operations
; =============================================================================
__DOS__CHDIR       equ $FF3B   ; _CHDIR — change directory
__DOS__MKDIR       equ $FF3C   ; _MKDIR — make directory
__DOS__OPEN        equ $FF3D   ; _OPEN — open file
                                ;   push: mode.w, path_ptr.l
                                ;   returns: d0.l = handle (negative = error)
__DOS__CREATE      equ $FF3C   ; _CREATE — create file (alias context)
__DOS__CLOSE       equ $FF3E   ; _CLOSE — close file handle
                                ;   push: handle.l
__DOS__READ        equ $FF3F   ; _READ — read from file
                                ;   push: handle.l, buffer_ptr.l, length.l
                                ;   returns: d0.l = bytes read (negative=error)
__DOS__WRITE       equ $FF40   ; _WRITE — write to file
                                ;   push: handle.l, buffer_ptr.l, length.l
__DOS__DELETE      equ $FF41   ; _DELETE — delete file
__DOS__SEEK        equ $FF42   ; _SEEK — seek within file
                                ;   push: handle.l, offset.l, mode.w
                                ;   mode: 0=SEEK_SET 1=SEEK_CUR 2=SEEK_END
__DOS__CHMOD       equ $FF43   ; _CHMOD — change file attributes
__DOS__IOCTRL      equ $FF44   ; _IOCTRL — I/O control
__DOS__DUP         equ $FF45   ; _DUP — duplicate file handle
__DOS__DUP2        equ $FF46   ; _DUP2 — duplicate to specific handle
__DOS__CREATETMP   equ $FF47   ; _CREATETMP — create temp file

__DOS__MALLOC      equ $FF48   ; _MALLOC — allocate memory
                                ;   push: size.l
                                ;   returns: d0.l = pointer (negative=error)
__DOS__MFREE       equ $FF49   ; _MFREE — free memory block
                                ;   push: pointer.l
__DOS__SETBLOCK    equ $FF4A   ; _SETBLOCK — resize memory block
__DOS__MALLOC2     equ $FF4B   ; _MALLOC2 — allocate from top of memory

__DOS__EXIT2       equ $FF4C   ; _EXIT2 — terminate with return code
                                ;   push: code.w
__DOS__EXEC        equ $FF4D   ; _EXEC — execute program
__DOS__GETENV2     equ $FF4E   ; _GETENV2

__DOS__FFIND       equ $FF4F   ; _FFIND — find first file
__DOS__NFIND       equ $FF50   ; _NFIND — find next file
__DOS__SETDATE     equ $FF51   ; _SETDATE
__DOS__SETTIME     equ $FF52   ; _SETTIME

__DOS__SETPDB      equ $FF55   ; _SETPDB — set Process Descriptor Block
__DOS__GETPDB      equ $FF56   ; _GETPDB — get Process Descriptor Block
                                ;   returns: d0.l = PDB pointer
__DOS__SETENV      equ $FF57   ; _SETENV
__DOS__PATHCHK     equ $FF58   ; _PATHCHK — check path

__DOS__GETTIME2    equ $FF5A   ; _GETTIME2
__DOS__SETTIME2    equ $FF5B   ; _SETTIME2
__DOS__NAMECK      equ $FF5C   ; _NAMECK — check filename validity


; =============================================================================
; Process control
; =============================================================================
__DOS__FORK        equ $FF5D   ; _FORK
__DOS__GETTIME     equ $FF2C   ; _GETTIME
__DOS__GETDATE     equ $FF2A   ; _GETDATE
__DOS__SUPER       equ $FF20   ; _SUPER — switch to supervisor mode
                                ;   push: 0 (or stack ptr) — see manual
                                ;   returns: d0.l = old SSP, sets supervisor
__DOS__FNCKEY      equ $FF21   ; _FNCKEY — function key control
__DOS__KEEPPR      equ $FF22   ; _KEEPPR — terminate and stay resident
__DOS__GETTIM2     equ $FF23   ; _GETTIM2
__DOS__SETTIM2     equ $FF24   ; _SETTIM2
__DOS__INTVCS      equ $FF25   ; _INTVCS — set interrupt vector (user-mode safe)
                                ;   push handler_ptr.l FIRST, then vector_num.w
                                ;   returns: d0.l = previous handler address
                                ;   NOTE: was wrongly set to $FF33 (_BREAKCK)
                                ;   Correct value confirmed from Human68k reference

__DOS__GETENVPTR   equ $FF26   ; _GETENVPTR


__DOS__BREAKCK     equ $FF33   ; _BREAKCK — set break check (NOT _INTVCS)

__DOS__ASSIGN      equ $FF35   ; _ASSIGN
__DOS__BUS_ERR     equ $FF3A   ; _BUS_ERR — install bus error handler

__DOS__NEWPDB      equ $FF80   ; _NEWPDB — create new PDB (v3 address)

; =============================================================================
; Common combined sequences as macros
; These follow the convention: push parameters, emit DOS call, clean stack
; =============================================================================

; DOS_PUTCHAR_W d0 — print character in d0.b (pushed as word for alignment)
DOS_PUTCHAR_W   MACRO
    move.w  d0,-(sp)
    DOS     _PUTCHAR
    addq.l  #2,sp
    ENDM

; DOS_GETCHAR_D0 — read character into d0.l (no stack params)
DOS_GETCHAR_D0  MACRO
    DOS     _GETCHAR
    ENDM

; DOS_EXIT_CODE n — exit with return code n (immediate)
DOS_EXIT_CODE   MACRO
    move.w  #\1,-(sp)
    DOS     _EXIT2
    ENDM

; DOS_OPEN_FILE — a0=path pointer, mode in d1.w; returns handle in d0.l
DOS_OPEN_FILE   MACRO
    move.w  d1,-(sp)
    move.l  a0,-(sp)
    DOS     _OPEN
    addq.l  #6,sp
    ENDM

; DOS_CLOSE_FILE — d1.l = handle
DOS_CLOSE_FILE  MACRO
    move.l  d1,-(sp)
    DOS     _CLOSE
    addq.l  #4,sp
    ENDM

; DOS_READ_FILE — d1.l=handle, a0=buffer, d2.l=length; returns d0.l=bytes read
DOS_READ_FILE   MACRO
    move.l  d2,-(sp)
    move.l  a0,-(sp)
    move.w  d1,-(sp)
    DOS     _READ
    add.l   #10,sp
    ENDM

DOS_SUPER MACRO
    pea     0
    DOS     _SUPER
    addq.l  #4,sp
    ENDM
