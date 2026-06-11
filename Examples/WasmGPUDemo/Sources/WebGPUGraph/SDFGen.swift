import Foundation
import JavaScriptKit
import SwiftWebGPU

/// Builds a single-channel SDF ``FontAtlas`` entirely at runtime, in Swift — no external tool, no
/// embedded asset, no extra JavaScript. Each glyph is rasterised to an offscreen 2D canvas at high
/// resolution, an exact Euclidean distance transform (Felzenszwalb & Huttenlocher) turns it into a
/// signed distance field, and the fields are packed into an `r8unorm` atlas uploaded via
/// `writeTexture`. Crisp at any UI scale; corners soften only under extreme magnification (that's
/// where the offline ``MSDFFont`` wins).
@MainActor
enum SDFFont {
    static let firstChar = 32, lastChar = 126
    static let emPx = 32.0        // atlas pixels per em (target resolution)
    static let ss = 4             // supersample factor for the raster → DT
    static let pad = 5            // atlas-px padding around each glyph (field margin)
    static let pxRange = 6.0      // distance range, atlas px, mapped to the stored [0,1]
    static let atlasW = 256       // fixed width → bytesPerRow (256) is already 256-aligned for r8

    struct Cell {
        var ch: Character
        var advanceEm: Double
        var abL: Double, abAsc: Double      // ink bearings at hi-res (px)
        var inkW: Double, inkH: Double      // ink box at hi-res (px)
        var cellW: Int, cellH: Int          // atlas px
        var x0: Int, y0: Int                // atlas px placement
        var hasInk: Bool
    }

    static func build(dev: GPUDevice) -> FontAtlas? {
        let doc = JSObject.global.document
        let cnv = doc.createElement("canvas").object!
        let g = cnv.getContext!("2d").object!
        let font = "700 \(Int(emPx) * ss)px -apple-system, system-ui, sans-serif"
        g.font = .string(font)
        g.textAlign = .string("left")
        g.textBaseline = .string("alphabetic")

        // Line metrics from the font box of a tall sample.
        let fm = g.measureText!("Hg").object!
        let fAsc = fm.fontBoundingBoxAscent.number ?? (emPx * Double(ss) * 0.8)
        let fDesc = fm.fontBoundingBoxDescent.number ?? (emPx * Double(ss) * 0.2)

        // Pass 1: measure every glyph and shelf-pack into the fixed-width atlas.
        var cells: [Cell] = []
        var x = 0, y = 0, rowH = 0
        for code in firstChar...lastChar {
            let ch = Character(UnicodeScalar(code)!)
            let m = g.measureText!(String(ch)).object!
            let adv = m.width.number ?? 0
            let abL = m.actualBoundingBoxLeft.number ?? 0
            let abR = m.actualBoundingBoxRight.number ?? 0
            let abAsc = m.actualBoundingBoxAscent.number ?? 0
            let abDesc = m.actualBoundingBoxDescent.number ?? 0
            let inkW = max(abL + abR, 0), inkH = max(abAsc + abDesc, 0)
            let hasInk = inkW > 0.5 && inkH > 0.5 && ch != " "
            let cellW = hasInk ? Int(ceil(inkW / Double(ss))) + 2 * pad : 0
            let cellH = hasInk ? Int(ceil(inkH / Double(ss))) + 2 * pad : 0
            var c = Cell(ch: ch, advanceEm: adv / Double(ss) / emPx, abL: abL, abAsc: abAsc,
                         inkW: inkW, inkH: inkH, cellW: cellW, cellH: cellH, x0: 0, y0: 0, hasInk: hasInk)
            if hasInk {
                if x + cellW > atlasW { x = 0; y += rowH; rowH = 0 }
                c.x0 = x; c.y0 = y
                x += cellW; rowH = max(rowH, cellH)
            }
            cells.append(c)
        }
        let atlasH = y + rowH
        guard atlasH > 0 else { return nil }

        // Pass 2: rasterise each glyph at hi-res, distance-transform, downsample into the atlas.
        var atlas = [UInt8](repeating: 0, count: atlasW * atlasH)   // 0 = far outside
        var glyphs: [Character: GlyphMetric] = [:]
        for c in cells {
            if !c.hasInk {
                glyphs[c.ch] = GlyphMetric(advance: c.advanceEm, planeMin: (0, 0), planeMax: (0, 0),
                                           uvMin: (0, 0), uvMax: (0, 0), hasQuad: false)
                continue
            }
            let hiW = c.cellW * ss, hiH = c.cellH * ss
            cnv.width = .number(Double(hiW))
            cnv.height = .number(Double(hiH))
            // Resizing resets the context state — restore it.
            g.font = .string(font)
            g.textAlign = .string("left")
            g.textBaseline = .string("alphabetic")
            g.fillStyle = .string("#fff")
            let penX = Double(pad * ss) + c.abL
            let penY = Double(pad * ss) + c.abAsc
            _ = g.fillText!(String(c.ch), penX, penY)

            let img = g.getImageData!(0, 0, Double(hiW), Double(hiH)).object!
            let dataArr = JSTypedArray<JSUInt8Clamped>(unsafelyWrapping: img.data.object!)
            let n = hiW * hiH
            var inside = [Bool](repeating: false, count: n)
            dataArr.withUnsafeBytes { buf in
                for i in 0..<n { inside[i] = buf[i * 4 + 3] > 127 }   // alpha channel
            }

            let signed = signedDistanceField(inside: inside, w: hiW, h: hiH)

            // Downsample SS×SS blocks (average the signed distance), store normalized.
            for ay in 0..<c.cellH {
                for ax in 0..<c.cellW {
                    var sum = 0.0
                    for sy in 0..<ss {
                        let hy = ay * ss + sy
                        let base = hy * hiW + ax * ss
                        for sx in 0..<ss { sum += signed[base + sx] }
                    }
                    let distHi = sum / Double(ss * ss)
                    let distAtlas = distHi / Double(ss)
                    let stored = min(max(0.5 + distAtlas / pxRange, 0), 1)
                    atlas[(c.y0 + ay) * atlasW + (c.x0 + ax)] = UInt8(stored * 255)
                }
            }

            let S = emPx
            let penXCell = Double(pad) + c.abL / Double(ss)
            let penYCell = Double(pad) + c.abAsc / Double(ss)
            glyphs[c.ch] = GlyphMetric(
                advance: c.advanceEm,
                planeMin: (-penXCell / S, -(Double(c.cellH) - penYCell) / S),
                planeMax: ((Double(c.cellW) - penXCell) / S, penYCell / S),
                uvMin: (Double(c.x0) / Double(atlasW), Double(c.y0) / Double(atlasH)),
                uvMax: (Double(c.x0 + c.cellW) / Double(atlasW), Double(c.y0 + c.cellH) / Double(atlasH)),
                hasQuad: true)
        }

        // Upload the r8 atlas (bytesPerRow = atlasW = 256, already 256-aligned).
        let tex = dev.createTexture(descriptor: GPUTextureDescriptor(
            size: GPUExtent3D(width: UInt32(atlasW), height: UInt32(atlasH)),
            format: .r8unorm, usage: [.textureBinding, .copyDst]))
        let ta = JSTypedArray<UInt8>(atlas)
        dev.queue.writeTexture(
            destination: GPUImageCopyTexture(texture: tex),
            data: ta.jsObject,
            dataLayout: GPUImageDataLayout(bytesPerRow: UInt32(atlasW), rowsPerImage: UInt32(atlasH)),
            size: GPUExtent3D(width: UInt32(atlasW), height: UInt32(atlasH)))

        let asc = fAsc / Double(ss) / emPx
        let desc = -fDesc / Double(ss) / emPx
        return FontAtlas(texture: tex, width: atlasW, height: atlasH, pxRange: pxRange, mode: 0,
                         ascender: asc, descender: desc, lineHeight: asc - desc, glyphs: glyphs)
    }

    // MARK: Exact Euclidean distance transform (Felzenszwalb & Huttenlocher)

    /// Signed distance (in pixels): positive inside, negative outside.
    private static func signedDistanceField(inside: [Bool], w: Int, h: Int) -> [Double] {
        let inf = 1e20
        let n = w * h
        var fOut = [Double](repeating: 0, count: n)   // foreground = inside  → dist for outside px
        var fIn = [Double](repeating: 0, count: n)    // foreground = outside → dist for inside px
        for i in 0..<n {
            fOut[i] = inside[i] ? 0 : inf
            fIn[i] = inside[i] ? inf : 0
        }
        edt2d(&fOut, w: w, h: h)
        edt2d(&fIn, w: w, h: h)
        var out = [Double](repeating: 0, count: n)
        for i in 0..<n {
            out[i] = inside[i] ? fIn[i].squareRoot() : -fOut[i].squareRoot()
        }
        return out
    }

    private static func edt2d(_ f: inout [Double], w: Int, h: Int) {
        var row = [Double](repeating: 0, count: w)
        for yy in 0..<h {
            for xx in 0..<w { row[xx] = f[yy * w + xx] }
            let d = edt1d(row)
            for xx in 0..<w { f[yy * w + xx] = d[xx] }
        }
        var col = [Double](repeating: 0, count: h)
        for xx in 0..<w {
            for yy in 0..<h { col[yy] = f[yy * w + xx] }
            let d = edt1d(col)
            for yy in 0..<h { f[yy * w + xx] = d[yy] }
        }
    }

    /// 1-D squared-distance transform: D(q) = min_v ((q − v)² + f[v]).
    private static func edt1d(_ f: [Double]) -> [Double] {
        let n = f.count
        let inf = 1e20
        var d = [Double](repeating: 0, count: n)
        var v = [Int](repeating: 0, count: n)
        var z = [Double](repeating: 0, count: n + 1)
        var k = 0
        v[0] = 0; z[0] = -inf; z[1] = inf
        for q in 1..<n {
            var s = ((f[q] + Double(q * q)) - (f[v[k]] + Double(v[k] * v[k]))) / Double(2 * q - 2 * v[k])
            while s <= z[k] {
                k -= 1
                s = ((f[q] + Double(q * q)) - (f[v[k]] + Double(v[k] * v[k]))) / Double(2 * q - 2 * v[k])
            }
            k += 1
            v[k] = q; z[k] = s; z[k + 1] = inf
        }
        k = 0
        for q in 0..<n {
            while z[k + 1] < Double(q) { k += 1 }
            let dq = Double(q - v[k])
            d[q] = dq * dq + f[v[k]]
        }
        return d
    }
}
