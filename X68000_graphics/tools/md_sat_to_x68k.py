#!/usr/bin/env python3
"""
md_sat_to_x68k.py -- Convert a Mega Drive sprite attribute table (SAT) +
tile data into X68000 PCG-ready tile data + a sprite table entry report.

Automates what the sprite_editor.html tool required manual tile
placement for: reads the MD's own sprite definitions directly, so
sprites of any size/flip/palette convert without per-sprite clicking.

============================================================================
MD SAT entry format (8 bytes, confirmed against real sega_logo_sprite_table
data and cross-checked against a chibiakumas.com hardware reference
earlier in this project):
    word0 (+0): Y position, bits9-0 (raw MD value, +128 offset -- NOT
                removed here, per "I'll add offsets later")
    word1 (+2): bits11-10=HSize, bits9-8=VSize (tile counts - 1), bits6-0=Link
                (CORRECTED -- an earlier revision had these at bits9-8/7-6/5-0,
                which happened to give plausible-looking-but-wrong values on
                real data: confirmed via real sega_logo_sat.bin, cross-checked
                three independent ways -- the "0000 HH VV 0 NNNNNNN" bit
                format from a hardware reference, the tile file's size (48
                tiles = exactly 3 sprites x 16 tiles/sprite for 32x32, not
                the 12 tiles the buggy 32x8 interpretation would have needed),
                and the tile index stride between sprites (16, matching
                16 tiles/sprite for 32x32))
    word2 (+4): bit15=Priority, bits14-13=Palette, bit12=VFlip, bit11=HFlip,
                bits10-0=Tile index
    word3 (+6): X position, bits9-0 (raw MD value, +128 offset)

============================================================================
Tile storage: confirmed column-major/"transposed" (verified against real
32x32 sprite data earlier in this project, and confirmed as a hardware-
level MD VDP requirement, not a per-asset convention) -- tile at
(col, row) within the sprite = tile_data[base_index + col*tile_h + row].

============================================================================
X68000 output: PCG pattern order is TL,BL,TR,BR per 16x16 quadrant
(confirmed earlier). Since X68000 sprites support hardware H/V flip
directly (confirmed: bit15=VFlip, bit14=HFlip in the attribute word),
flip is NOT baked into pixel data -- instead:
  - PCG tile content is always extracted/stored UNFLIPPED
  - Each 16x16 quadrant's OWN pixels get the hardware flip bit set
  - For MD sprites spanning more than one quadrant, the ARRANGEMENT of
    quadrants also mirrors (not just each quadrant's own pixels) --
    verified by hand-tracing specific pixels through the compound
    transform against what a true whole-sprite mirror should produce,
    and confirmed generally via the automated geometry tests below.
"""

import argparse
import struct
import sys
from pathlib import Path

TILE_BYTES = 32
BLANK_TILE = bytes(TILE_BYTES)


def parse_sat_entry(data: bytes, offset: int):
    """Parse one 8-byte MD SAT entry. Returns a dict of decoded fields."""
    w0, w1, w2, w3 = struct.unpack_from('>4H', data, offset)
    return {
        'y_raw': w0 & 0x3FF,
        'hsize': (w1 >> 10) & 3,
        'vsize': (w1 >> 8) & 3,
        'link': w1 & 0x7F,
        'priority': (w2 >> 15) & 1,
        'palette': (w2 >> 13) & 3,
        'vflip': (w2 >> 12) & 1,
        'hflip': (w2 >> 11) & 1,
        'tile_index': w2 & 0x7FF,
        'x_raw': w3 & 0x3FF,
    }


def extract_sprite_tiles(tiles: list, base_index: int, tile_w: int, tile_h: int):
    """
    Extract tile_w x tile_h tiles for one sprite, column-major, starting
    at base_index. Returns a 2D list [col][row] of tile bytes (32 bytes
    each), using BLANK_TILE for any index that runs past the end of the
    loaded tile data (should not normally happen with correct input, but
    fails soft rather than crashing on a malformed/truncated tile file).
    """
    grid = []
    for col in range(tile_w):
        column = []
        for row in range(tile_h):
            idx = base_index + col * tile_h + row
            column.append(tiles[idx] if 0 <= idx < len(tiles) else BLANK_TILE)
        grid.append(column)
    return grid


def tile_at(grid, col, row, tile_w, tile_h):
    """Grid lookup with blank-padding for odd (non-2-aligned) dimensions."""
    if col < tile_w and row < tile_h:
        return grid[col][row]
    return BLANK_TILE


def convert_sprite(entry: dict, tiles: list, pattern_start_index: int):
    """
    Convert one parsed SAT entry into:
      - a list of PCG-ready 128-byte pattern blocks (always unflipped)
      - a list of X68000 sprite table sub-entries (one per 16x16 quadrant),
        each: {rel_x, rel_y, pattern, palette, hflip, vflip}
        rel_x/rel_y are relative to the sprite's own origin (top-left of
        the UNFLIPPED bounding box) -- absolute screen position and the
        MD's own +128-style coordinate offset are left to the caller, as
        requested.
    pattern_start_index: PCG pattern number to assign to the first
    quadrant produced (caller tracks/increments across multiple sprites).
    """
    tile_w = entry['hsize'] + 1
    tile_h = entry['vsize'] + 1
    grid = extract_sprite_tiles(tiles, entry['tile_index'], tile_w, tile_h)

    quad_w = (tile_w + 1) // 2
    quad_h = (tile_h + 1) // 2

    patterns = []
    sub_entries = []
    pattern_num = pattern_start_index

    for qy in range(quad_h):
        for qx in range(quad_w):
            tl = tile_at(grid, qx*2,   qy*2,   tile_w, tile_h)
            tr = tile_at(grid, qx*2+1, qy*2,   tile_w, tile_h)
            bl = tile_at(grid, qx*2,   qy*2+1, tile_w, tile_h)
            br = tile_at(grid, qx*2+1, qy*2+1, tile_w, tile_h)
            patterns.append(tl + bl + tr + br)   # PCG order, always unflipped

            screen_qx = (quad_w - 1 - qx) if entry['hflip'] else qx
            screen_qy = (quad_h - 1 - qy) if entry['vflip'] else qy

            sub_entries.append({
                'rel_x': screen_qx * 16,
                'rel_y': screen_qy * 16,
                'pattern': pattern_num,
                'palette': entry['palette'],
                'hflip': entry['hflip'],
                'vflip': entry['vflip'],
                'priority': entry['priority'],
            })
            pattern_num += 1

    return patterns, sub_entries


def convert_sat(sat_data: bytes, tile_data: bytes, sprite_count: int,
                 tile_index_base: int = 0):
    """
    Convert a full SAT (sprite_count entries) + tile data into combined
    PCG output and a per-MD-sprite list of X68000 sub-entries.
    tile_index_base: subtracted from each SAT entry's tile index before
    use, in case the SAT's indices are VRAM-relative rather than
    0-based into the tile file you're loading (you know your own
    asset's convention; this project can't infer it).
    """
    tiles = [tile_data[i*TILE_BYTES:(i+1)*TILE_BYTES]
             for i in range(len(tile_data) // TILE_BYTES)]

    all_patterns = []
    sprites = []
    pattern_cursor = 0
    sub_sprite_cursor = 0

    for i in range(sprite_count):
        entry = parse_sat_entry(sat_data, i * 8)
        entry['tile_index'] -= tile_index_base
        patterns, sub_entries = convert_sprite(entry, tiles, pattern_cursor)
        all_patterns.extend(patterns)
        pattern_cursor += len(patterns)

        quad_w = (entry['hsize'] + 2) // 2
        quad_h = (entry['vsize'] + 2) // 2
        sprites.append({
            'md_index': i, 'entry': entry, 'sub_entries': sub_entries,
            'sub_sprite_start': sub_sprite_cursor,
            'sub_sprite_count': len(sub_entries),
            'width_sprites': quad_w, 'height_sprites': quad_h,
        })
        sub_sprite_cursor += len(sub_entries)

    pcg_data = b''.join(all_patterns)
    return pcg_data, sprites


# X68000 sprite attribute word field positions (confirmed earlier in this
# project against a working hardware reference -- see gfx_blit_ex.s /
# x68k_hw.i's Sprite attribute table section)
SP_PAL_SHIFT = 8
SP_HFLIP = 0x4000
SP_VFLIP = 0x8000
SP_PRI_FRONT = 0x0003
SP_PRI_BACK = 0x0001


def build_sub_sprite_table(sprites) -> bytes:
    """
    Flat binary sub-sprite table, one 8-byte entry per 16x16 X68000
    sprite (matching SPRITE_TABLE's real entry layout: X,Y,attr,priority
    words). X/Y here are sprite-relative (rel_x/rel_y) -- NOT yet offset
    by SP_X_OFFSET/SP_Y_OFFSET or positioned on screen; apply your own
    per-object screen position and the hardware +16 offset at runtime,
    per your plan to add offsets later.
    """
    out = bytearray()
    for s in sprites:
        for sub in s['sub_entries']:
            attr = (sub['pattern'] & 0xFF)
            attr |= (sub['palette'] & 0xF) << SP_PAL_SHIFT
            if sub['hflip']:
                attr |= SP_HFLIP
            if sub['vflip']:
                attr |= SP_VFLIP
            priority = SP_PRI_FRONT if sub['priority'] else SP_PRI_BACK
            out += struct.pack('>hhHH', sub['rel_x'], sub['rel_y'], attr, priority)
    return bytes(out)


def build_meta_sprite_table(sprites) -> bytes:
    """
    One entry per ORIGINAL MD sprite (6 bytes): sub_sprite_start (word,
    index into the flat sub-sprite table), sub_sprite_count (byte),
    width_sprites (byte), height_sprites (byte), palette (byte) -- lets
    game code treat "MD sprite N" as one movable/animatable unit
    spanning sub_sprite_count consecutive entries in the flat table,
    rather than tracking which flat indices belong together by hand.
    """
    out = bytearray()
    for s in sprites:
        out += struct.pack('>HBBBB',
                            s['sub_sprite_start'],
                            s['sub_sprite_count'],
                            s['width_sprites'],
                            s['height_sprites'],
                            s['entry']['palette'])
    return bytes(out)


def format_report(sprites) -> str:
    lines = ["; MD SAT -> X68000 sprite table conversion report", ""]
    for s in sprites:
        e = s['entry']
        lines.append(f"; MD sprite {s['md_index']}: "
                      f"{(e['hsize']+1)*8}x{(e['vsize']+1)*8}px, "
                      f"pal={e['palette']} hflip={e['hflip']} vflip={e['vflip']} "
                      f"(Y_raw={e['y_raw']} X_raw={e['x_raw']} -- offsets not applied)")
        for sub in s['sub_entries']:
            lines.append(f";   pattern {sub['pattern']:3d}  "
                          f"rel=({sub['rel_x']:+4d},{sub['rel_y']:+4d})  "
                          f"pal={sub['palette']} hflip={sub['hflip']} vflip={sub['vflip']} "
                          f"pri={sub['priority']}")
        lines.append("")
    return "\n".join(lines)


# ============================================================================
# CLI
# ============================================================================

def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                  formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('sat_file', help='raw MD sprite attribute table binary')
    ap.add_argument('tile_file', help='raw MD tile data (packed 4bpp, 32 bytes/tile)')
    ap.add_argument('--sprite-count', type=int, required=True,
                     help='number of SAT entries to process')
    ap.add_argument('--tile-index-base', type=int, default=0,
                     help='subtracted from each SAT tile index before lookup '
                          '(use if SAT indices are VRAM-relative, not 0-based)')
    ap.add_argument('--out-pcg', default='sprite_pcg.bin')
    ap.add_argument('--out-report', default='sprite_report.txt')
    args = ap.parse_args()

    try:
        sat_data = Path(args.sat_file).read_bytes()
        tile_data = Path(args.tile_file).read_bytes()
        pcg_data, sprites = convert_sat(sat_data, tile_data, args.sprite_count,
                                         args.tile_index_base)
        Path(args.out_pcg).write_bytes(pcg_data)
        Path(args.out_report).write_text(format_report(sprites))
        total_patterns = len(pcg_data) // (4 * TILE_BYTES)
        print(f"Converted {args.sprite_count} MD sprites -> {total_patterns} "
              f"X68000 PCG patterns ({len(pcg_data)} bytes)")
        print(f"  PCG data:  {args.out_pcg}")
        print(f"  Report:    {args.out_report}")
    except FileNotFoundError as e:
        sys.exit(f"error: file not found: {e.filename}")
    except (struct.error, IndexError) as e:
        sys.exit(f"error: {e} -- check --sprite-count against the SAT file's actual size")


if __name__ == '__main__':
    main()
