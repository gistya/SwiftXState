import Foundation
import SwiftWebGPU

/// Distance-field text for the GPU. A `FontAtlas` holds a distance-field texture plus per-glyph
/// metrics in *em units* (advance, quad plane bounds, atlas UV rect) — exactly the data a layout
/// pass needs to place crisp, resolution-independent glyphs at any scale.
///
/// Two providers fill this in:
/// - ``SDFFont`` — a single-channel SDF computed entirely in Swift at load (no asset, no tool).
/// - ``MSDFFont`` — a true multi-channel SDF atlas generated offline and embedded (PNG + JSON).
///
/// Both feed the same `vs_glyph`/`fs_glyph` pipeline; `mode` (0 = SDF → sample `.r`, 1 = MSDF →
/// `median(rgb)`) and `pxRange` tell the shader how to reconstruct the edge.

/// One glyph's metrics, all in em units (baseline at y = 0, y-up), with the atlas UV rect.
struct GlyphMetric: Sendable {
    var advance: Double                 // pen advance, em
    var planeMin: (x: Double, y: Double) // quad lower-left relative to pen, em
    var planeMax: (x: Double, y: Double) // quad upper-right relative to pen, em
    var uvMin: (x: Double, y: Double)    // atlas top-left, normalized (y-down)
    var uvMax: (x: Double, y: Double)    // atlas bottom-right, normalized (y-down)
    var hasQuad: Bool                    // false for whitespace (advance only)
}

/// A distance-field font: its atlas texture + the metrics to lay out strings against it.
final class FontAtlas {
    let texture: GPUTexture
    let view: GPUTextureView
    let width: Int
    let height: Int
    let pxRange: Double                  // distance range the field was generated with (atlas px)
    let mode: Int                        // 0 = single-channel SDF, 1 = multi-channel MSDF
    let ascender: Double                 // em
    let descender: Double                // em (negative)
    let lineHeight: Double               // em
    let glyphs: [Character: GlyphMetric]
    let kerning: [String: Double]        // "AB" -> em adjustment (optional)

    init(texture: GPUTexture, width: Int, height: Int, pxRange: Double, mode: Int,
         ascender: Double, descender: Double, lineHeight: Double,
         glyphs: [Character: GlyphMetric], kerning: [String: Double] = [:]) {
        self.texture = texture
        self.view = texture.createView()
        self.width = width
        self.height = height
        self.pxRange = pxRange
        self.mode = mode
        self.ascender = ascender
        self.descender = descender
        self.lineHeight = lineHeight
        self.glyphs = glyphs
        self.kerning = kerning
    }

    /// Width of `s` in em units (advances + kerning).
    func measure(_ s: String) -> Double {
        var w = 0.0
        let chars = Array(s)
        for (i, ch) in chars.enumerated() {
            let g = glyphs[ch] ?? glyphs[" "]
            w += g?.advance ?? 0.5
            if i + 1 < chars.count, let k = kerning["\(ch)\(chars[i + 1])"] { w += k }
        }
        return w
    }

    /// Append per-glyph quad instances for `s` to `out` (12 floats each: worldMin.xy, worldMax.xy,
    /// uvMin.xy, uvMax.xy, color.rgba). `em` is world units per em; the string is laid out from
    /// `(originX, baselineY)` in world space. Returns the number of glyph quads appended.
    @discardableResult
    func appendQuads(_ s: String, into out: inout [Double],
                     originX: Double, baselineY: Double, em: Double,
                     color: (Double, Double, Double, Double)) -> Int {
        var pen = originX
        var count = 0
        let chars = Array(s)
        for (i, ch) in chars.enumerated() {
            let g = glyphs[ch] ?? glyphs[" "] ?? GlyphMetric(
                advance: 0.5, planeMin: (0, 0), planeMax: (0, 0), uvMin: (0, 0), uvMax: (0, 0), hasQuad: false)
            if g.hasQuad {
                let x0 = pen + g.planeMin.x * em, y0 = baselineY + g.planeMin.y * em
                let x1 = pen + g.planeMax.x * em, y1 = baselineY + g.planeMax.y * em
                out += [x0, y0, x1, y1, g.uvMin.x, g.uvMin.y, g.uvMax.x, g.uvMax.y,
                        color.0, color.1, color.2, color.3]
                count += 1
            }
            pen += g.advance * em
            if i + 1 < chars.count, let k = kerning["\(ch)\(chars[i + 1])"] { pen += k * em }
        }
        return count
    }
}
