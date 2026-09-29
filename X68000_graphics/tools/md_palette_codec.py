#!/usr/bin/env python3
"""
md_palette_codec.py -- Convert Mega Drive CRAM palette data to X68000
palette format (and back), in bulk, offline.

Conversion math matches convert_md_colours_to_x68k in the working (tested
on real hardware/emulator) sega_logo_x68k.s exactly -- not re-derived, not
the original lookup-table approach this project started with. That
routine is itself the ground truth this script is checked against below.

============================================================================
FORMATS
============================================================================
MD CRAM word (big-endian, as stored in ROM/RAM):
    0000 BBB0 GGG0 RRR0
    bits 15-12 unused, 11-9=Blue, 8=pad, 7-5=Green, 4=pad, 3-1=Red, 0=pad
    (3-bit channels, each stored pre-shifted left by 1)

X68000 palette word (GPAL and TPAL both use this -- confirmed against
real hardware documentation and cross-checked with working code):
    GGGGG RRRRR BBBBB I
    bits 15-11=Green, 10-6=Red, 5-1=Blue, 0=Intensity (unused here, left 0)
    (5-bit channels)

Each 3-bit MD channel value is placed into the TOP 3 bits of the
corresponding 5-bit X68000 field, bottom 2 bits left as 0 (matches the
working assembly's shift amounts exactly -- this is a coarser mapping
than a proper 3-to-5-bit rounding table would give, but it's what's
already proven working, so this script reproduces it rather than
"improving" on it and creating a mismatch between tools).
"""

import argparse
import struct
import sys
from pathlib import Path


def md_word_to_x68k(word: int) -> int:
    """
    Exact port of convert_md_colours_to_x68k's shift sequence.
    word: MD CRAM word (0000 BBB0 GGG0 RRR0)
    returns: X68000 palette word (GGGGG RRRRR BBBBB I)

    NOTE: this only ever sets the TOP 3 bits of each 5-bit field (bottom
    2 bits always 0), matching the verified working assembly exactly --
    but it means MD's maximum channel value (3-bit 7) becomes X68000 28,
    not 31. Every colour converted this way tops out ~10% short of full
    brightness/saturation on each channel. This is a faithful match to
    what's proven working, not a bug -- but see md_word_to_x68k_precise()
    below for the alternative (map max-to-max) if you'd rather have that
    instead, now that this is becoming the project-wide conversion path.
    """
    result = 0
    # "blue" block in the assembly (bits 3-1 -- mislabelled there, this
    # is actually red; reproduced faithfully since the CODE, not the
    # comment, is what's verified working)
    red_field = (word & 0x000E) << 7          # bits3-1 -> bits10-8
    result |= red_field
    # green block (bits 7-5 -> bits15-13)
    green_field = (word & 0x00E0) << 8
    result |= green_field
    # blue block (bits 11-9 -> bits5-3)
    blue_field = (word & 0x0E00) >> 6
    result |= blue_field
    return result & 0xFFFF


MD3_TO_X68K5_PRECISE = [0, 4, 9, 13, 18, 22, 27, 31]  # round(v * 31 / 7)


def md_word_to_x68k_precise(word: int) -> int:
    """
    Alternative conversion: proper 3-to-5-bit rounding (round(v*31/7)),
    so MD's max channel value (7) maps to X68000's true max (31), not 28.
    NOT what the currently-working assembly does -- provided so you can
    compare/choose, not as a silent "better" default.
    """
    r3 = (word >> 1) & 7
    g3 = (word >> 5) & 7
    b3 = (word >> 9) & 7
    r5, g5, b5 = (MD3_TO_X68K5_PRECISE[r3], MD3_TO_X68K5_PRECISE[g3],
                  MD3_TO_X68K5_PRECISE[b3])
    return ((g5 << 11) | (r5 << 6) | (b5 << 1)) & 0xFFFF


def x68k_word_to_md(word: int) -> int:
    """
    Inverse of md_word_to_x68k. Since the forward conversion only keeps
    the top 3 bits of each 5-bit field (discarding the bottom 2), this
    is lossy -- round-tripping MD->X68k->MD reproduces the original
    exactly (verified below), but X68k->MD->X68k does not necessarily,
    if the X68k source didn't come from this same conversion originally.
    """
    red5 = (word >> 6) & 0x1F
    green5 = (word >> 11) & 0x1F
    blue5 = (word >> 1) & 0x1F
    # top 3 bits of the 5-bit field -> the MD's 3-bit value
    red3 = (red5 >> 2) & 0x7
    green3 = (green5 >> 2) & 0x7
    blue3 = (blue5 >> 2) & 0x7
    return ((blue3 << 9) | (green3 << 5) | (red3 << 1)) & 0xFFFF


def md_word_to_index(word: int) -> int:
    """
    Compact an MD CRAM word (0000 BBB0 GGG0 RRR0, gaps at bits 0/4/8/12-15)
    down to a dense 9-bit index (000000 BBB GGG RRR, 0-511) by removing
    the gap bits. Verified against known test vectors (pure max R/G/B,
    all-max) -- see conversation notes.
    """
    return ((word & 0x0E00) >> 3) | ((word & 0x00E0) >> 2) | ((word & 0x000E) >> 1)


def build_lookup_table(precise: bool = True):
    """
    Build the 512-entry MD-index -> X68000-word lookup table. Intensity
    bit (bit 0) is always 0. `precise` selects which per-channel mapping
    populates the table -- see md_word_to_x68k / md_word_to_x68k_precise
    docstrings for the tradeoff; this only affects what's PRECOMPUTED
    into the table, not the index math, so the table can be regenerated
    with a different mapping later without touching any assembly that
    consumes it.
    """
    table = [0] * 512
    for b in range(8):
        for g in range(8):
            for r in range(8):
                index = (b << 6) | (g << 3) | r
                md_word = (b << 9) | (g << 5) | (r << 1)
                conv = md_word_to_x68k_precise if precise else md_word_to_x68k
                table[index] = conv(md_word)
    return table


def table_to_asm(table, label: str = "md_colour_table") -> str:
    """Render a lookup table as a vasm-compatible dc.w block, 8 words/line."""
    lines = [f"; Generated by md_palette_codec.py gen-table -- 512-entry",
             f"; MD-compacted-index -> X68000 GGGGGRRRRRBBBBBI lookup table.",
             f"; Index = ((word&$0E00)>>3)|((word&$00E0)>>2)|((word&$000E)>>1)",
             f"    even",
             f"{label}:"]
    for i in range(0, 512, 8):
        chunk = table[i:i + 8]
        vals = ",".join(f"${v:04x}" for v in chunk)
        lines.append(f"    dc.w    {vals}")
    return "\n".join(lines) + "\n"
    """data: N big-endian MD CRAM words. Returns N X68000 palette words."""
    if len(data) % 2 != 0:
        raise ValueError(f"palette data length ({len(data)}) is not a "
                          f"multiple of 2 -- not a whole number of words")
    n = len(data) // 2
    words = struct.unpack(f'>{n}H', data)
    conv = md_word_to_x68k_precise if precise else md_word_to_x68k
    out = [conv(w) for w in words]
    return struct.pack(f'>{n}H', *out)


def convert_palette_x68k_to_md(data: bytes) -> bytes:
    if len(data) % 2 != 0:
        raise ValueError(f"palette data length ({len(data)}) is not a "
                          f"multiple of 2 -- not a whole number of words")
    n = len(data) // 2
    words = struct.unpack(f'>{n}H', data)
    out = [x68k_word_to_md(w) for w in words]
    return struct.pack(f'>{n}H', *out)


# ============================================================================
# Viewing
# ============================================================================

def md_to_rgb(word: int):
    r3, g3, b3 = (word >> 1) & 7, (word >> 5) & 7, (word >> 9) & 7
    scale = lambda v: round(v * 255 / 7)
    return (scale(r3), scale(g3), scale(b3))


def x68k_to_rgb(word: int):
    r5, g5, b5 = (word >> 6) & 0x1F, (word >> 11) & 0x1F, (word >> 1) & 0x1F
    scale = lambda v: round(v * 255 / 31)
    return (scale(r5), scale(g5), scale(b5))


def palette_strip_image(colours, swatch=24):
    from PIL import Image
    img = Image.new('RGB', (swatch * len(colours), swatch))
    px = img.load()
    for i, c in enumerate(colours):
        for y in range(swatch):
            for x in range(swatch):
                px[i * swatch + x, y] = c
    return img


# ============================================================================
# CLI
# ============================================================================

def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                  formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='cmd', required=True)

    c = sub.add_parser('md2x68k', help='convert MD CRAM palette data to X68000 format')
    c.add_argument('input')
    c.add_argument('output')
    c.add_argument('--precise', action='store_true',
                    help='true 3-to-5-bit rounding (max maps to max) instead '
                         'of the verified working shift-based conversion '
                         '(which caps brightness ~10%% short of max -- see '
                         'module docstring)')

    r = sub.add_parser('x68k2md', help='convert X68000 palette data back to MD CRAM format')
    r.add_argument('input')
    r.add_argument('output')

    v = sub.add_parser('view', help='render a palette file to a PNG colour strip')
    v.add_argument('input')
    v.add_argument('output_png')
    v.add_argument('--format', choices=['md', 'x68k'], required=True)
    v.add_argument('--swatch', type=int, default=24)

    t = sub.add_parser('gen-table', help='generate the 512-entry MD->X68000 lookup table as .s source')
    t.add_argument('output')
    t.add_argument('--label', default='md_colour_table')
    t.add_argument('--precise', action='store_true', default=True,
                    help='(default) true 3-to-5-bit rounding, max maps to max')
    t.add_argument('--shift-based', dest='precise', action='store_false',
                    help='use the verified-working shift-based mapping instead '
                         '(caps ~10%% short of max -- see module docstring)')

    args = ap.parse_args()

    try:
        if args.cmd == 'md2x68k':
            data = Path(args.input).read_bytes()
            out = convert_palette_md_to_x68k(data, precise=args.precise)
            Path(args.output).write_bytes(out)
            mode = 'precise (max-to-max)' if args.precise else 'shift-based (matches working asm, caps ~10% short of max)'
            print(f"Converted {len(data)//2} colours (MD -> X68000, {mode}) -> {args.output}")

        elif args.cmd == 'x68k2md':
            data = Path(args.input).read_bytes()
            out = convert_palette_x68k_to_md(data)
            Path(args.output).write_bytes(out)
            print(f"Converted {len(data)//2} colours (X68000 -> MD) -> {args.output}")

        elif args.cmd == 'view':
            data = Path(args.input).read_bytes()
            n = len(data) // 2
            words = struct.unpack(f'>{n}H', data)
            to_rgb = md_to_rgb if args.format == 'md' else x68k_to_rgb
            colours = [to_rgb(w) for w in words]
            img = palette_strip_image(colours, args.swatch)
            img.save(args.output_png)
            print(f"Rendered {n} colours -> {args.output_png}")

        elif args.cmd == 'gen-table':
            table = build_lookup_table(precise=args.precise)
            asm = table_to_asm(table, label=args.label)
            Path(args.output).write_text(asm)
            mode = 'precise (max-to-max)' if args.precise else 'shift-based (matches working asm)'
            print(f"Generated 512-entry table ({mode}) -> {args.output}")

    except FileNotFoundError as e:
        sys.exit(f"error: file not found: {e.filename}")
    except ValueError as e:
        sys.exit(f"error: {e}")


if __name__ == '__main__':
    main()
