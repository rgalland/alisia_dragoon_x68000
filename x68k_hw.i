; =============================================================================
; x68k_hw.i — X68000 Hardware Register Definitions
; For use with VASM (Motorola 68k syntax)
;
; Verified against:
;   - NFG Games / GameSX wiki (vidcon_registers)
;   - MAME x68k video driver source
;   - Retrobug.org hardware reference
;
; Memory map overview:
;   $000000-$BxxxFF   Main RAM (1MB standard, up to 12MB expanded)
;   $C00000-$C0FFFF   CRTC (screen timing and scroll)
;   $E00000-$E7FFFF   Graphic VRAM (4 pages x 512x512)
;   $E80000-$E8FFFF   Text VRAM
;   $E82000-$E821FF   Graphic palette (256 words in 256-colour mode)
;   $E82200-$E823FF   Text palette + Sprite/BG palette (16 blocks x 16 colours)
;   $E82400           Video controller R0 (colour/size mode)
;   $E82500           Video controller R1 (layer priority)
;   $E82600           Video controller R2 (layer ON/OFF)
;   $EB0000-$EB07FF   Sprite attribute table (128 entries)
;   $EB0800-$EB0808   BG scroll + control registers
;   $EB8000-$EBFFFF   PCG pattern RAM (32KB shared sprites+BG)
;   $E88000-$E88FFF   MFP MC68901 (timers, interrupts)
;   $E9A000-$E9A003   Joypad ports
; =============================================================================


; =============================================================================
; CRTC — CRT Controller ($C00000)
; Controls screen timing, resolution and scroll positions
; All registers 16-bit write
; =============================================================================

CRTC_BASE           equ $C00000

CRTC_R00            equ $C00000     ; Horizontal total
CRTC_R01            equ $C00002     ; Horizontal sync end
CRTC_R02            equ $C00004     ; Horizontal display start
CRTC_R03            equ $C00006     ; Horizontal display end
CRTC_R04            equ $C00008     ; Vertical total
CRTC_R05            equ $C0000A     ; Vertical sync end
CRTC_R06            equ $C0000C     ; Vertical display start
CRTC_R07            equ $C0000E     ; Vertical display end
CRTC_R08            equ $C00010     ; Fine adjust
CRTC_R09            equ $C00012     ; Raster line (read: current raster position)
CRTC_R10            equ $C00014     ; Text layer horizontal scroll
CRTC_R11            equ $C00016     ; Text layer vertical scroll
CRTC_R12            equ $C00018     ; Graphic layer 0 horizontal scroll
CRTC_R13            equ $C0001A     ; Graphic layer 0 vertical scroll
CRTC_R14            equ $C0001C     ; Graphic layer 1 horizontal scroll (unused)
CRTC_R15            equ $C0001E     ; Graphic layer 1 vertical scroll  (unused)
CRTC_R16            equ $C00020     ; Graphic layer 2 horizontal scroll
CRTC_R17            equ $C00022     ; Graphic layer 2 vertical scroll
CRTC_R18            equ $C00024     ; Graphic layer 3 horizontal scroll (unused)
CRTC_R19            equ $C00026     ; Graphic layer 3 vertical scroll  (unused)
CRTC_R20            equ $C00028     ; Screen mode flags

; CRTC R20 bit fields:
;   bit 12    : 1=1024 dot mode
;   bit 11-10 : vertical res (00=256, 01=512, 1x=1024 interlace)
;   bit 9-8   : horizontal res (00=256, 01=512, 10=768)
;   bit 1     : 1=interlace
;   bit 0     : 1=31kHz, 0=15kHz
; NOTE: bits 9-8 must match VC R0 colour mode bits

; Convenient aliases for scroll registers
; In 256-colour 2-layer mode:
;   Pages 0+1 = Layer 0 (background)  → CRTC R12/R13
;   Pages 2+3 = Layer 1 (foreground)  → CRTC R16/R17
GFX_L0_HSCROLL      equ CRTC_R12
GFX_L0_VSCROLL      equ CRTC_R13
GFX_L1_HSCROLL      equ CRTC_R16
GFX_L1_VSCROLL      equ CRTC_R17

; --- CRTC preset values for 256x256 15kHz ---
CRTC_256_R00        equ $003F
CRTC_256_R01        equ $0009
CRTC_256_R02        equ $000E
CRTC_256_R03        equ $002E
CRTC_256_R04        equ $010B
CRTC_256_R05        equ $0005
CRTC_256_R06        equ $0028
CRTC_256_R07        equ $0128
CRTC_256_R08        equ $001B
CRTC_256_R20        equ $0000       ; 256x256 15kHz, must match VC_R0_256COL


; =============================================================================
; Graphic VRAM — $E00000 (512KB total, 4 x 128KB pages)
;
; In 256-colour mode (our target):
;   2 page pairs active, each pair = one independently scrolling layer
;   Each pixel = 1 byte (8-bit index into graphic palette at $E82000)
;   Virtual space per layer = 512x512 pixels
;
;   Layer 0 (background scroll) : pages 0+1  $E00000 / $E20000
;   Layer 1 (foreground scroll) : pages 2+3  $E40000 / $E60000
;
; Writing pixels in 256-colour mode:
;   A pixel at position (x,y) on layer 0:
;     address = GVRAM_PAGE0 + (y * GVRAM_WIDTH) + x
;   A pixel at position (x,y) on layer 1:
;     address = GVRAM_PAGE2 + (y * GVRAM_WIDTH) + x
;
; Clearing a layer: fill with colour index 0 (transparent/background)
; Tile blitting: copy 8 or 16 pixel rows of colour index bytes
; =============================================================================

GVRAM_BASE          equ $E00000
GVRAM_PAGE0         equ $E00000     ; Layer 0
GVRAM_PAGE1         equ $E20000     ; Layer 0 (256-colour pair, may be unused directly)
GVRAM_PAGE2         equ $E40000     ; Layer 1
GVRAM_PAGE3         equ $E60000     ; Layer 1 (256-colour pair, may be unused directly)
GVRAM_PAGE_SIZE     equ $20000      ; 128KB per page
GVRAM_WIDTH         equ 512         ; virtual layer width in pixels
GVRAM_HEIGHT        equ 512         ; virtual layer height in pixels


; =============================================================================
; Graphic Palette — $E82000
;
; Used ONLY by graphic VRAM layers. Independent from sprite/text palettes.
;
; In 256-colour mode: 256 entries x 2 bytes = 512 bytes ($E82000-$E821FF)
; Each entry is a 16-bit colour word directly output to display.
;
; Colour format (16-bit word):
;   bit  15    : unused (always 0)
;   bits 14-10 : Red   (5 bits, 0=dark, 31=full)
;   bits  9-5  : Green (5 bits)
;   bits  4-0  : Blue  (5 bits)
;   Format: 0RRRRR GGGGG BBBBB
;
; Index 0 = layer background colour (shown where no other layer is visible)
;
; MD-to-X68k colour conversion:
;   MD  3-bit channel (0-7):  stored as (value << 1) in bits 3-1
;   X68k 5-bit channel (0-31): scale with x68k = md_3bit * 4 + md_3bit / 2
;   Simpler: x68k = (md_raw_nibble >> 1) * 36 / 32  (use lookup table)
;
; Address of entry N: GPAL_BASE + (N * 2)
; =============================================================================

GPAL_BASE           equ $E82000
GPAL_ENTRY_SIZE     equ 2           ; bytes per palette entry
GPAL_COUNT          equ 256         ; entries in 256-colour mode

COL_RED_SHIFT       equ 10
COL_GREEN_SHIFT     equ 5
COL_BLUE_SHIFT      equ 0
COL_RED_MASK        equ $7C00
COL_GREEN_MASK      equ $03E0
COL_BLUE_MASK       equ $001F

COL_BLACK           equ $0000
COL_WHITE           equ $7FFF
COL_RED             equ $7C00
COL_GREEN           equ $03E0
COL_BLUE            equ $001F


; =============================================================================
; Text + Sprite/BG Palette — $E82200
;
; Completely separate from graphic palette.
; Covers 16 blocks x 16 colours x 2 bytes = 512 bytes ($E82200-$E823FF)
;
; Text layer uses block 0 only ($E82200-$E8221F)
; Sprite system uses all 16 blocks via 4-bit palette select in sprite attr
;
; Colour index for sprites:
;   upper 4 bits = palette block (from sprite attribute bits 3-0)
;   lower 4 bits = pixel value (from PCG pattern data nibble)
;   combined 8-bit value indexes into this 256-entry palette area
;
; Address of block B, colour C:
;   TPAL_BASE + (B * TPAL_BLOCK_SIZE) + (C * 2)
; =============================================================================

TPAL_BASE           equ $E82200
TPAL_BLOCK_SIZE     equ $20         ; 32 bytes = 16 colours per block
TPAL_BLOCK_COUNT    equ 16
TEXT_PAL_BASE       equ $E82200     ; text layer palette = block 0


; =============================================================================
; Video Controller Registers
; =============================================================================

; VC R0 — Colour/size mode ($E82400)
;   bit  2   : GVRAM size 0=512x512  1=1024x1024
;   bits 1-0 : colour mode 00=16col  01=256col  11=65536col
;   MUST match CRTC R20 bits 9-8
VC_R0               equ $E82400
VC_R0_512           equ $0000       ; 512x512 GVRAM size
VC_R0_1024          equ $0004       ; 1024x1024 GVRAM size
VC_R0_16COL         equ $0000       ; 16 colour graphic
VC_R0_256COL        equ $0001       ; 256 colour graphic (our target)
VC_R0_65536COL      equ $0003       ; 65536 colour graphic

; Our target VC R0 value: 512x512 + 256 colour
VC_R0_GAME          equ VC_R0_512|VC_R0_256COL

; VC R1 — Layer priority ($E82500)
;   bits 13-12 : SP  sprite priority  (00=highest 01=second 10=third)
;   bits 11-10 : TX  text priority
;   bits  9-8  : GR  graphic priority
;   bits  7-0  : GP3-GP0 graphic page order
;   For 256-colour 2-page: GP=$E4 means page1 < page0
VC_R1               equ $E82500

; Sprite on top, text (HUD) second, graphic layers below
; SP=00, TX=01, GR=10, GP=$E4
VC_R1_GAME          equ $0004|(2<<8)|($E4&$FF)

; VC R2 — Layer ON/OFF ($E82600)
;   bit  6 : SON sprite screen ON
;   bit  5 : TON text screen ON
;   bit  3 : GS3 graphic page 3 ON  (layer 1 high)
;   bit  2 : GS2 graphic page 2 ON  (layer 1 low)
;   bit  1 : GS1 graphic page 1 ON  (layer 0 high)
;   bit  0 : GS0 graphic page 0 ON  (layer 0 low)
;   In 256-colour mode set both pages of each pair together
VC_R2               equ $E82600
VC_SPRITE_ON        equ $0040
VC_TEXT_ON          equ $0020
VC_GFX_L0_ON        equ $0003       ; pages 0+1 = layer 0
VC_GFX_L1_ON        equ $000C       ; pages 2+3 = layer 1

; Combined value: sprites + text HUD + both graphic layers
VC_R2_GAME          equ VC_SPRITE_ON|VC_TEXT_ON|VC_GFX_L0_ON|VC_GFX_L1_ON


; =============================================================================
; Sprite attribute table — $EB0000
; 128 entries x 8 bytes
;
; Entry layout (4 words):
;   +0 word : X position  (add SP_X_OFFSET to screen pixel coordinate)
;   +2 word : Y position  (add SP_Y_OFFSET to screen pixel coordinate)
;   +4 word : Attributes
;               bits 15-8 : pattern number (0-255, into PCG at $EB8000)
;               bit  7    : vertical flip
;               bit  6    : horizontal flip
;               bits 3-0  : palette block (0-15, upper 4 bits of colour index)
;   +6 word : Link
;               bits 6-0  : index of next sprite in display chain
;                           set to own index to terminate chain
;
; Sprites are rendered in linked-list order starting from the index
; stored in BG_CTRL bits 15-9.
; To disable all sprites: set sprite 0 link to 0, set BG_CTRL head to 0
;
; PCG colour index = (palette_block << 4) | pcg_pixel_nibble
; indexes into sprite/BG palette at $E82200
; =============================================================================

SPRITE_TABLE        equ $EB0000
SPRITE_ENTRY_SIZE   equ 8
SPRITE_MAX          equ 128

SP_OFF_X            equ 0
SP_OFF_Y            equ 2
SP_OFF_ATTR         equ 4
SP_OFF_LINK         equ 6

SP_X_OFFSET         equ 16
SP_Y_OFFSET         equ 16

SP_PATTERN_SHIFT    equ 8
SP_PATTERN_MASK     equ $FF00
SP_VFLIP            equ $0080
SP_HFLIP            equ $0040
SP_PAL_MASK         equ $000F

SP_LINK_MASK        equ $007F


; =============================================================================
; PCG Pattern RAM — $EB8000 (32KB)
;
; Shared between sprites, BG0 and BG1 (BG unused in our config)
; 256 patterns maximum, each pattern = 16x16 pixels 4bpp = 128 bytes
;
; Pattern data format:
;   128 bytes = 16 rows x 8 bytes
;   Each byte = 2 pixels: high nibble = left pixel, low nibble = right pixel
;   Pixel nibble = lower 4 bits of colour index
;   Upper 4 bits of colour index come from sprite attribute palette field
;
; Address of pattern N: PCG_BASE + (N * PCG_PATTERN_BYTES)
; =============================================================================

PCG_BASE            equ $EB8000
PCG_PATTERN_BYTES   equ 128
PCG_MAX_PATTERNS    equ 256


; =============================================================================
; BG control (defined for completeness, BG layers unused in our config)
; =============================================================================

BG0_HSCROLL         equ $EB0800
BG0_VSCROLL         equ $EB0802
BG1_HSCROLL         equ $EB0804
BG1_VSCROLL         equ $EB0806
BG_CTRL             equ $EB0808

BG_SPRITE_HEAD_SHIFT equ 9


; =============================================================================
; MFP MC68901 — $E88000
; =============================================================================

MFP_BASE            equ $E88000
MFP_GPDR            equ $E88001
MFP_DDR             equ $E88003
MFP_IERA            equ $E88007
MFP_IERB            equ $E88009
MFP_IPRA            equ $E8800B
MFP_IPRB            equ $E8800D
MFP_ISRA            equ $E8800F
MFP_ISRB            equ $E88011
MFP_IMRA            equ $E88013
MFP_IMRB            equ $E88015
MFP_VR              equ $E88017
MFP_TACR            equ $E88019
MFP_TBCR            equ $E8801B
MFP_TCDCR           equ $E8801D
MFP_TADR            equ $E8801F
MFP_TBDR            equ $E88021
MFP_TCDR            equ $E88023
MFP_TDDR            equ $E88025

MFP_VECTOR_BASE     equ $40
FM_IRQ_VECTOR       equ $43    ; MFP FM Audio source — this is where YM2151 timer interrupts land
VBLANK_VECTOR       equ $46
TIMER_B_VECTOR      equ $48
TIMER_A_VECTOR      equ $4D


; =============================================================================
; Joypad
; =============================================================================

JOY1_PORT           equ $E9A000
JOY2_PORT           equ $E9A002

JOY_RIGHT           equ $20
JOY_LEFT            equ $10
JOY_DOWN            equ $08
JOY_UP              equ $04
JOY_BTN_B           equ $02
JOY_BTN_A           equ $01


; =============================================================================
; Screen layout constants — adjust to match chosen CRTC mode
; =============================================================================

SCREEN_WIDTH        equ 256
SCREEN_HEIGHT       equ 256
GVRAM_VWIDTH        equ 512         ; virtual scroll space width
GVRAM_VHEIGHT       equ 512         ; virtual scroll space height
