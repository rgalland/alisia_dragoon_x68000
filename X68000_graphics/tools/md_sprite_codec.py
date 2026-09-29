#!/usr/bin/env python3
"""
md_sprite_codec.py -- Reorder Mega Drive sprite tile data into X68000 PCG
pattern order.

MD sprites are built from 8x8 tiles in raster order within each 16x16
group: A(top-left) B(top-right) C(bottom-left) D(bottom-right).

X68000 PCG sprite patterns store the same four 8x8 quadrants in a
different order: A(top-left) C(bottom-left) B(top-right) D(bottom-right)
-- i.e. left column top-to-bottom, then right column top-to-bottom.
(Verified against a working chibiakumas.com hardware reference during
this project; independently matches the even/odd tile split found by
hand for the Sega logo sprites.)

This script reorders every consecutive group of 4 tiles in a raw MD
sprite tile file from ABCD -> ACBD, so the output can be uploaded
directly to PCG pattern RAM as one 128-byte block per 16x16 sprite.

The transform is its own inverse (swapping positions 2 and 3 is an
involution), which gives a free correctness check: applying it twice
must reproduce the original file exactly -- this script's test suite
uses that property, and running the CLI command twice on your own data
is a quick sanity check too.

For MD sprites larger than 16x16 (e.g. the Sega logo's 32x32 sprites,
each 4x4=16 tiles), this operates on whatever tile groups you point it
at -- see --width/--height if your source data's tile arrangement for
larger sprites isn't simply "one ABCD group per 16x16 quadrant,
concatenated." (This script assumes that simple case by default; if
your larger-sprite tile order turns out to need something else -- e.g.
true column-major across all rows, not just within each 16x16 quadrant
-- let me know and this can be adjusted rather than guessed at now.)
"""

import argparse
import sys
from pathlib import Path

TILE_BYTES = 32  # 8x8 pixels, 4bpp, packed 2px/byte


def reorder_abcd_to_acbd(data: bytes) -> bytes:
    """
    Reorder every consecutive group of 4 tiles from A,B,C,D to A,C,B,D.
    `data` length must be a multiple of 4*TILE_BYTES (128 bytes/group).
    """
    if len(data) % (4 * TILE_BYTES) != 0:
        raise ValueError(
            f"data length ({len(data)} bytes) is not a multiple of "
            f"{4 * TILE_BYTES} (4 tiles x {TILE_BYTES} bytes/tile) -- "
            f"can't split cleanly into ABCD groups"
        )
    out = bytearray()
    for i in range(0, len(data), 4 * TILE_BYTES):
        a = data[i:i + TILE_BYTES]
        b = data[i + TILE_BYTES:i + 2 * TILE_BYTES]
        c = data[i + 2 * TILE_BYTES:i + 3 * TILE_BYTES]
        d = data[i + 3 * TILE_BYTES:i + 4 * TILE_BYTES]
        out += a + c + b + d
    return bytes(out)


def reorder_grid(data: bytes, width_tiles: int, height_tiles: int) -> bytes:
    """
    For sprites wider/taller than 2x2 tiles: walk the source as a
    width_tiles x height_tiles raster grid (row-major, matching how the
    simple ABCD case generalises -- row0 left-to-right, then row1, etc.),
    and apply the ABCD->ACBD swap independently to every 2x2 quadrant of
    tiles. Both dimensions must be even (X68000 sprites tile in whole
    16x16 units).

    If your data's actual layout for larger sprites isn't "row-major
    grid of tiles, reordered per-2x2-quadrant" -- e.g. if it's really
    column-major across the WHOLE sprite rather than per-quadrant --
    this won't be right, and the file's docstring note applies: flag it
    and this can be adjusted rather than assumed correct.
    """
    if width_tiles % 2 != 0 or height_tiles % 2 != 0:
        raise ValueError(
            f"width_tiles ({width_tiles}) and height_tiles ({height_tiles}) "
            f"must both be even -- X68000 sprites are built from whole "
            f"16x16 (2x2-tile) units"
        )
    expected = width_tiles * height_tiles * TILE_BYTES
    if len(data) != expected:
        raise ValueError(
            f"data is {len(data)} bytes, expected exactly {expected} for "
            f"a {width_tiles}x{height_tiles}-tile grid"
        )

    def tile_at(tx, ty):
        idx = ty * width_tiles + tx
        return data[idx * TILE_BYTES:(idx + 1) * TILE_BYTES]

    out = bytearray()
    for qy in range(0, height_tiles, 2):
        for qx in range(0, width_tiles, 2):
            a = tile_at(qx, qy)          # top-left
            b = tile_at(qx + 1, qy)      # top-right
            c = tile_at(qx, qy + 1)      # bottom-left
            d = tile_at(qx + 1, qy + 1)  # bottom-right
            out += a + c + b + d
    return bytes(out)


# ============================================================================
# Viewing
# ============================================================================

def sprite_groups_to_image(data: bytes, palette, groups_per_row: int = 8):
    """
    Render 16x16-sprite-sized (4-tile) groups to a PIL image, reading
    each group in ACBD (X68000 PCG) order -- i.e. this previews what the
    hardware will actually display, not the raw file order.
    """
    from PIL import Image

    group_bytes = 4 * TILE_BYTES
    n_groups = len(data) // group_bytes
    rows = (n_groups + groups_per_row - 1) // groups_per_row
    img = Image.new('RGB', (groups_per_row * 16, rows * 16), palette[0])
    px = img.load()

    for g in range(n_groups):
        gx = (g % groups_per_row) * 16
        gy = (g // groups_per_row) * 16
        group = data[g * group_bytes:(g + 1) * group_bytes]
        # ACBD order: quadrant 0=TL, 1=BL, 2=TR, 3=BR
        quadrant_pos = [(0, 0), (0, 8), (8, 0), (8, 8)]
        for qi, (ox, oy) in enumerate(quadrant_pos):
            tile = group[qi * TILE_BYTES:(qi + 1) * TILE_BYTES]
            for row in range(8):
                for col in range(0, 8, 2):
                    byte = tile[row * 4 + col // 2]
                    hi, lo = byte >> 4, byte & 0xF
                    px[gx + ox + col, gy + oy + row] = palette[hi % len(palette)]
                    px[gx + ox + col + 1, gy + oy + row] = palette[lo % len(palette)]
    return img


DEFAULT_GRAYSCALE_PALETTE = [(i * 17, i * 17, i * 17) for i in range(16)]


# ============================================================================
# CLI
# ============================================================================

def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                  formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='cmd', required=True)

    r = sub.add_parser('reorder', help='convert MD tile order to X68000 PCG order')
    r.add_argument('input')
    r.add_argument('output')
    r.add_argument('--width', type=int, help='sprite width in tiles (for grids larger than 2x2)')
    r.add_argument('--height', type=int, help='sprite height in tiles (for grids larger than 2x2)')

    v = sub.add_parser('view', help='render sprite tile data (X68000 PCG order) to PNG')
    v.add_argument('input')
    v.add_argument('output_png')
    v.add_argument('--already-reordered', action='store_true',
                    help='input is already in ACBD/PCG order (skip the ABCD->ACBD step for viewing)')
    v.add_argument('--groups-per-row', type=int, default=8)

    args = ap.parse_args()

    try:
        if args.cmd == 'reorder':
            data = Path(args.input).read_bytes()
            if args.width or args.height:
                if not (args.width and args.height):
                    sys.exit("error: --width and --height must be given together")
                out = reorder_grid(data, args.width, args.height)
            else:
                out = reorder_abcd_to_acbd(data)
            Path(args.output).write_bytes(out)
            n_tiles = len(data) // TILE_BYTES
            print(f"Reordered {n_tiles} tiles ({len(data)} bytes) -> {args.output}")

        elif args.cmd == 'view':
            data = Path(args.input).read_bytes()
            if not args.already_reordered:
                data = reorder_abcd_to_acbd(data)
            img = sprite_groups_to_image(data, DEFAULT_GRAYSCALE_PALETTE, args.groups_per_row)
            img.save(args.output_png)
            n_groups = len(data) // (4 * TILE_BYTES)
            print(f"Rendered {n_groups} 16x16 sprite(s) -> {args.output_png}")

    except FileNotFoundError as e:
        sys.exit(f"error: file not found: {e.filename}")
    except ValueError as e:
        sys.exit(f"error: {e}")


if __name__ == '__main__':
    main()
