import Foundation
import JavaScriptKit
import SwiftWebGPU

/// Loads a *true* multi-channel SDF ``FontAtlas`` from an embedded, offline-generated atlas
/// (`msdf.png` + `msdf.json`, served next to the page). MSDF keeps glyph corners razor-sharp at any
/// magnification because the field is built from the font's vector outline — something that can't be
/// reconstructed from a runtime raster, so the atlas is generated ahead of time (see `tools/`).
///
/// Returns `nil` if the assets aren't present (the caller then falls back to the runtime ``SDFFont``).
///
/// Expected `msdf.json` schema (normalized, y-down UVs; em-unit plane bounds, baseline at y = 0):
/// ```json
/// { "atlasWidth": 256, "atlasHeight": 256, "pxRange": 4,
///   "ascender": 0.93, "descender": -0.24, "lineHeight": 1.2,
///   "glyphs": { "A": { "advance": 0.63, "plane": [l,b,r,t], "uv": [l,t,r,b] } } }
/// ```
@MainActor
enum MSDFFont {
    private struct Doc: Decodable {
        let atlasWidth: Int
        let atlasHeight: Int
        let pxRange: Double
        let ascender: Double
        let descender: Double
        let lineHeight: Double
        let glyphs: [String: Glyph]
    }
    private struct Glyph: Decodable {
        let advance: Double
        let plane: [Double]?   // [left, bottom, right, top] em, y-up (absent for whitespace)
        let uv: [Double]?      // [left, top, right, bottom] normalized, y-down
    }

    static func load(dev: GPUDevice, jsonURL: String = "msdf.json", pngURL: String = "msdf.png") async -> FontAtlas? {
        guard let doc = await fetchJSON(jsonURL), let bitmap = await loadBitmap(pngURL) else { return nil }

        let tex = dev.createTexture(descriptor: GPUTextureDescriptor(
            size: GPUExtent3D(width: UInt32(doc.atlasWidth), height: UInt32(doc.atlasHeight)),
            format: .rgba8unorm, usage: [.textureBinding, .copyDst, .renderAttachment]))
        dev.queue.copyExternalImageToTexture(
            source: GPUImageCopyExternalImage(source: bitmap),
            destination: GPUImageCopyTextureTagged(texture: tex),
            copySize: GPUExtent3D(width: UInt32(doc.atlasWidth), height: UInt32(doc.atlasHeight)))

        var glyphs: [Character: GlyphMetric] = [:]
        for (key, g) in doc.glyphs {
            guard let ch = key.first, key.count == 1 else { continue }
            if let p = g.plane, p.count == 4, let uv = g.uv, uv.count == 4 {
                glyphs[ch] = GlyphMetric(
                    advance: g.advance,
                    planeMin: (p[0], p[1]), planeMax: (p[2], p[3]),
                    uvMin: (uv[0], uv[1]), uvMax: (uv[2], uv[3]), hasQuad: true)
            } else {
                glyphs[ch] = GlyphMetric(advance: g.advance, planeMin: (0, 0), planeMax: (0, 0),
                                         uvMin: (0, 0), uvMax: (0, 0), hasQuad: false)
            }
        }
        return FontAtlas(texture: tex, width: doc.atlasWidth, height: doc.atlasHeight,
                         pxRange: doc.pxRange, mode: 1, ascender: doc.ascender, descender: doc.descender,
                         lineHeight: doc.lineHeight, glyphs: glyphs)
    }

    private static func fetchJSON(_ url: String) async -> Doc? {
        guard let respObj = JSObject.global.fetch!(url).object, let p = JSPromise(respObj),
              let resp = try? await p.value(), (resp.ok.boolean ?? false) else { return nil }
        guard let textObj = resp.text().object, let tp = JSPromise(textObj),
              let text = try? await tp.value(), let s = text.string,
              let data = s.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Doc.self, from: data)
    }

    private static func loadBitmap(_ url: String) async -> JSObject? {
        // Load + decode the PNG (`img.decode()` rejects on 404/broken), then make an ImageBitmap —
        // the most portable copyExternalImageToTexture source.
        let img = JSObject.global.Image.function!.new()
        img.src = .string(url)
        guard let dec = img.decode!().object, let dp = JSPromise(dec),
              (try? await dp.value()) != nil else { return nil }
        guard let bmObj = JSObject.global.createImageBitmap!(img.jsValue).object, let bp = JSPromise(bmObj),
              let bm = try? await bp.value(), let obj = bm.object else { return nil }
        return obj
    }
}
