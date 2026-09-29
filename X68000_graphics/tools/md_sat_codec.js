// md_sat_codec.js -- JS port of md_sat_to_x68k.py's SAT parsing and
// conversion logic. Ported for exact behavioral match, not rewritten --
// see that file's docstring for the full field-layout sourcing and the
// hand-verified flip-mirroring geometry derivation.

const SAT_TILE_BYTES = 32;
const SAT_BLANK_TILE = new Uint8Array(SAT_TILE_BYTES);

function parseSatEntry(data, offset) {
  const w0 = (data[offset] << 8) | data[offset+1];
  const w1 = (data[offset+2] << 8) | data[offset+3];
  const w2 = (data[offset+4] << 8) | data[offset+5];
  const w3 = (data[offset+6] << 8) | data[offset+7];
  return {
    yRaw: w0 & 0x3FF,
    hsize: (w1 >> 10) & 3,
    vsize: (w1 >> 8) & 3,
    link: w1 & 0x7F,
    priority: (w2 >> 15) & 1,
    palette: (w2 >> 13) & 3,
    vflip: (w2 >> 12) & 1,
    hflip: (w2 >> 11) & 1,
    tileIndex: w2 & 0x7FF,
    xRaw: w3 & 0x3FF,
  };
}

function extractSpriteTiles(tiles, baseIndex, tileW, tileH) {
  const grid = [];
  for (let col = 0; col < tileW; col++) {
    const column = [];
    for (let row = 0; row < tileH; row++) {
      const idx = baseIndex + col * tileH + row;
      column.push((idx >= 0 && idx < tiles.length) ? tiles[idx] : SAT_BLANK_TILE);
    }
    grid.push(column);
  }
  return grid;
}

function tileAtGrid(grid, col, row, tileW, tileH) {
  if (col < tileW && row < tileH) return grid[col][row];
  return SAT_BLANK_TILE;
}

function concatBytes(arrays) {
  const total = arrays.reduce((n, a) => n + a.length, 0);
  const out = new Uint8Array(total);
  let off = 0;
  for (const a of arrays) {
    out.set(a, off);
    off += a.length;
  }
  return out;
}

function concatTiles(...tiles) {
  return concatBytes(tiles);
}

function convertSprite(entry, tiles, patternStartIndex) {
  const tileW = entry.hsize + 1;
  const tileH = entry.vsize + 1;
  const grid = extractSpriteTiles(tiles, entry.tileIndex, tileW, tileH);

  const quadW = Math.ceil(tileW / 2);
  const quadH = Math.ceil(tileH / 2);

  const patterns = [];
  const subEntries = [];
  let patternNum = patternStartIndex;

  for (let qy = 0; qy < quadH; qy++) {
    for (let qx = 0; qx < quadW; qx++) {
      const tl = tileAtGrid(grid, qx*2,   qy*2,   tileW, tileH);
      const tr = tileAtGrid(grid, qx*2+1, qy*2,   tileW, tileH);
      const bl = tileAtGrid(grid, qx*2,   qy*2+1, tileW, tileH);
      const br = tileAtGrid(grid, qx*2+1, qy*2+1, tileW, tileH);
      patterns.push(concatTiles(tl, bl, tr, br)); // PCG order, always unflipped

      const screenQx = entry.hflip ? (quadW - 1 - qx) : qx;
      const screenQy = entry.vflip ? (quadH - 1 - qy) : qy;

      subEntries.push({
        relX: screenQx * 16,
        relY: screenQy * 16,
        pattern: patternNum,
        palette: entry.palette,
        hflip: entry.hflip,
        vflip: entry.vflip,
        priority: entry.priority,
      });
      patternNum++;
    }
  }
  return { patterns, subEntries };
}

function convertSat(satData, tileData, spriteCount, tileIndexBase = 0) {
  const tiles = [];
  for (let i = 0; i < Math.floor(tileData.length / SAT_TILE_BYTES); i++) {
    tiles.push(tileData.slice(i*SAT_TILE_BYTES, (i+1)*SAT_TILE_BYTES));
  }

  const allPatterns = [];
  const sprites = [];
  let patternCursor = 0;
  let subSpriteCursor = 0;

  for (let i = 0; i < spriteCount; i++) {
    const entry = parseSatEntry(satData, i * 8);
    entry.tileIndex -= tileIndexBase;
    const { patterns, subEntries } = convertSprite(entry, tiles, patternCursor);
    allPatterns.push(...patterns);
    patternCursor += patterns.length;

    const quadW = Math.ceil((entry.hsize + 1) / 2);
    const quadH = Math.ceil((entry.vsize + 1) / 2);
    sprites.push({
      mdIndex: i, entry, subEntries,
      subSpriteStart: subSpriteCursor,
      subSpriteCount: subEntries.length,
      widthSprites: quadW, heightSprites: quadH,
    });
    subSpriteCursor += subEntries.length;
  }

  const pcgData = concatTiles(...allPatterns);
  return { pcgData, sprites };
}

// X68000 sprite attribute word field positions (same constants as
// md_sat_to_x68k.py, sourced from gfx_blit_ex.s / x68k_hw.i)
const SP_PAL_SHIFT = 8;
const SP_HFLIP = 0x4000;
const SP_VFLIP = 0x8000;
const SP_PRI_FRONT = 0x0003;
const SP_PRI_BACK = 0x0001;

function buildSubSpriteTable(sprites) {
  const entries = [];
  sprites.forEach(s => s.subEntries.forEach(sub => entries.push(sub)));
  const out = new Uint8Array(entries.length * 8);
  entries.forEach((sub, i) => {
    let attr = sub.pattern & 0xFF;
    attr |= (sub.palette & 0xF) << SP_PAL_SHIFT;
    if (sub.hflip) attr |= SP_HFLIP;
    if (sub.vflip) attr |= SP_VFLIP;
    const priority = sub.priority ? SP_PRI_FRONT : SP_PRI_BACK;
    const off = i * 8;
    out[off]   = (sub.relX >> 8) & 0xFF; out[off+1] = sub.relX & 0xFF;
    out[off+2] = (sub.relY >> 8) & 0xFF; out[off+3] = sub.relY & 0xFF;
    out[off+4] = (attr >> 8) & 0xFF;     out[off+5] = attr & 0xFF;
    out[off+6] = (priority >> 8) & 0xFF; out[off+7] = priority & 0xFF;
  });
  return out;
}

function buildMetaSpriteTable(sprites) {
  const out = new Uint8Array(sprites.length * 6);
  sprites.forEach((s, i) => {
    const off = i * 6;
    out[off]   = (s.subSpriteStart >> 8) & 0xFF; out[off+1] = s.subSpriteStart & 0xFF;
    out[off+2] = s.subSpriteCount & 0xFF;
    out[off+3] = s.widthSprites & 0xFF;
    out[off+4] = s.heightSprites & 0xFF;
    out[off+5] = s.entry.palette & 0xFF;
  });
  return out;
}

if (typeof module !== 'undefined') {
  module.exports = {
    parseSatEntry, convertSprite, convertSat,
    buildSubSpriteTable, buildMetaSpriteTable, SAT_TILE_BYTES,
  };
}
