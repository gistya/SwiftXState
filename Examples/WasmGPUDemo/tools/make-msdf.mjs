// Generates a true MSDF atlas for the WebGPUGraph text engine.
//
//   cd tools && npm install && node make-msdf.mjs
//
// Produces ../assets/msdf.png + ../assets/msdf.json (build.sh copies them into site/). The atlas is
// multi-channel SDF — built from the font's vector outline, so glyph corners stay razor-sharp at any
// magnification. Font: Roboto Bold (Apache-2.0); the generated atlas is a redistributable derivative.
//
// The JSON is converted from the generator's BMFont layout into the compact, em-normalized schema
// MSDFFont.load() expects (see MSDFAtlas.swift).
import generateBMFont from 'msdf-bmfont-xml';
import { writeFileSync, mkdirSync } from 'node:fs';

const FONT = 'Roboto-Bold.ttf';
const charset = Array.from({ length: 126 - 32 + 1 }, (_, i) => String.fromCharCode(32 + i)).join('');

generateBMFont(FONT, {
    outputType: 'json',
    fieldType: 'msdf',
    fontSize: 42,
    distanceRange: 4,
    textureSize: [512, 512],
    charset,
}, (err, textures, font) => {
    if (err) { console.error(err); process.exit(1); }
    if (textures.length !== 1) { console.error(`expected 1 page, got ${textures.length}`); process.exit(1); }

    mkdirSync('../assets', { recursive: true });
    writeFileSync('../assets/msdf.png', textures[0].texture);

    const bm = JSON.parse(font.data);
    const size = bm.info.size, base = bm.common.base;
    const W = bm.common.scaleW, H = bm.common.scaleH;
    const range = bm.distanceField.distanceRange;

    const glyphs = {};
    for (const c of bm.chars) {
        const ch = c.char ?? String.fromCharCode(c.id);
        if (c.width > 0 && c.height > 0) {
            glyphs[ch] = {
                advance: c.xadvance / size,
                // plane: [left, bottom, right, top] in em, baseline at y = 0, y-up.
                plane: [
                    c.xoffset / size,
                    (base - c.yoffset - c.height) / size,
                    (c.xoffset + c.width) / size,
                    (base - c.yoffset) / size,
                ],
                // uv: [left, top, right, bottom] normalized, y-down (atlas top-left origin).
                uv: [c.x / W, c.y / H, (c.x + c.width) / W, (c.y + c.height) / H],
            };
        } else {
            glyphs[ch] = { advance: c.xadvance / size };   // whitespace: advance only
        }
    }

    const doc = {
        atlasWidth: W,
        atlasHeight: H,
        pxRange: range,
        ascender: base / size,
        descender: (base - bm.common.lineHeight) / size,
        lineHeight: bm.common.lineHeight / size,
        glyphs,
    };
    writeFileSync('../assets/msdf.json', JSON.stringify(doc));
    console.log(`✓ msdf atlas ${W}×${H}, ${Object.keys(glyphs).length} glyphs, range ${range}px`);
});
