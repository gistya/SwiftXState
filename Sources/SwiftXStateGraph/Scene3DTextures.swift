#if SWIFTXSTATE_GRAPH_UI && canImport(SceneKit) && !os(watchOS)
import CoreGraphics
import CoreImage
import CoreText
import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Procedural textures for the 3D renderer — generated once per scene build. Returns
/// `CGImage`s, which SceneKit materials accept directly on every Apple platform.
enum Scene3DTextures {
    private static let ciContext = CIContext(options: nil)

    /// Shared, instance-independent textures (computed once).
    static let brushedRoughnessImage: CGImage? = brushedMetalRoughness()
    static let glassNormalImage: CGImage? = glassNormal()

    /// A tiling hexagonal grid (pointy-top), e.g. swift-orange lines on a gray field.
    static func hexGrid(
        pixels: Int,
        hexRadius: CGFloat,
        line: CGColor,
        background: CGColor,
        lineWidth: CGFloat
    ) -> CGImage? {
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.setFillColor(background)
        ctx.fill(CGRect(x: 0, y: 0, width: pixels, height: pixels))
        ctx.setStrokeColor(line)
        ctx.setLineWidth(lineWidth)
        ctx.setLineJoin(.round)

        let r = hexRadius
        let w = sqrt(3.0) * r
        let h = 1.5 * r
        let rows = Int(ceil(CGFloat(pixels) / h)) + 2
        let cols = Int(ceil(CGFloat(pixels) / w)) + 2

        for j in -1...rows {
            let offset = (j & 1) == 0 ? 0 : w / 2
            let cy = CGFloat(j) * h
            for i in -1...cols {
                let cx = CGFloat(i) * w + offset
                ctx.beginPath()
                for k in 0..<6 {
                    let a = CGFloat.pi / 180 * (60 * CGFloat(k) - 90)
                    let p = CGPoint(x: cx + r * cos(a), y: cy + r * sin(a))
                    if k == 0 { ctx.move(to: p) } else { ctx.addLine(to: p) }
                }
                ctx.closePath()
                ctx.strokePath()
            }
        }
                
        guard let image = ctx.makeImage(), let stacked = stackHorizontally(image) else {
            return nil
        }
        
        return stacked
    }
    
    /// Spherical mapping requires that height * 2  == width.
    /// I.e. the images must be stacked like [😀][😀]
    static func stackHorizontally(_ image: CGImage) -> CGImage? {
        let w = image.width
        let h = image.height
        
        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        
        guard let context = CGContext(
            data: nil,
            width: w * 2,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: 0,                 // 0 = let CG compute the optimal stride
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        
        // Draw the image in the left half...
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        // ...and again in the right half
        context.draw(image, in: CGRect(x: w, y: 0, width: w, height: h))
        
        return context.makeImage()
    }

    /// Renders text to a transparent image with a soft drop shadow (for readable 3D labels).
    /// Returns the image and its aspect ratio (width / height).
    static func textImage(
        _ text: String,
        fontSize: CGFloat,
        weight: PlatformFont.Weight,
        color: CGColor,
        background: CGColor? = CGColor(gray: 0.04, alpha: 0.62)
    ) -> (image: CGImage, aspect: CGFloat)? {
        guard !text.isEmpty else { return nil }
        #if os(macOS)
        let platformFont = NSFont.systemFont(ofSize: fontSize, weight: weight)
        #else
        let platformFont = UIFont.systemFont(ofSize: fontSize, weight: weight)
        #endif
        let ctFont = platformFont as CTFont

        let attrs: [CFString: Any] = [kCTFontAttributeName: ctFont, kCTForegroundColorAttributeName: color]
        guard let astr = CFAttributedStringCreate(nil, text as CFString, attrs as CFDictionary) else { return nil }
        let line = CTLineCreateWithAttributedString(astr)
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)

        // ~1 pica of padding around the text, plus room for the plate's drop shadow.
        let blur = fontSize * 0.18
        let inset: CGFloat = background == nil ? 0 : 12
        let pad = max(blur * 2.2, inset + blur)
        let wPt = ceil(bounds.width + pad * 2)
        let hPt = ceil(bounds.height + pad * 2)
        let supersample: CGFloat = 3
        let pw = max(1, Int(wPt * supersample))
        let ph = max(1, Int(hPt * supersample))

        guard let ctx = CGContext(
            data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.scaleBy(x: supersample, y: supersample)
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)

        if let background {
            // A dark rounded plate (with its own soft drop shadow) behind the text.
            let rect = CGRect(x: blur, y: blur, width: wPt - blur * 2, height: hPt - blur * 2)
            let path = CGPath(roundedRect: rect, cornerWidth: 7, cornerHeight: 7, transform: nil)
            ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: blur, color: CGColor(gray: 0, alpha: 0.55))
            ctx.addPath(path)
            ctx.setFillColor(background)
            ctx.fillPath()
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
        } else {
            ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: blur, color: CGColor(gray: 0, alpha: 0.6))
        }

        ctx.textPosition = CGPoint(x: pad - bounds.origin.x, y: pad - bounds.origin.y)
        CTLineDraw(line, ctx)

        guard let image = ctx.makeImage() else { return nil }
        return (image, wPt / max(hPt, 1))
    }

    /// Gaussian-blurs a CGImage, clamping edges so the result stays opaque to the border.
    static func blurred(_ image: CGImage, radius: Double) -> CGImage? {
        let input = CIImage(cgImage: image).clampedToExtent()
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return image }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(radius, forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage else { return image }
        let extent = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        return ciContext.createCGImage(output, from: extent)
    }

    /// A grayscale roughness map with fine vertical streaks — a "brushed metal" finish that
    /// shows up as anisotropic-looking highlights once the environment reflects in it.
    static func brushedMetalRoughness(pixels: Int = 256, base: CGFloat = 0.34, variation: CGFloat = 0.14) -> CGImage? {
        let cs = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(
            data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
            space: cs, bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        var generator = SystemRandomNumberGenerator()
        for x in 0..<pixels {
            // Each vertical column gets a slightly different roughness → brushed streaks.
            let n = CGFloat.random(in: -1...1, using: &generator)
            let value = max(0, min(1, base + n * variation))
            ctx.setFillColor(CGColor(gray: value, alpha: 1))
            ctx.fill(CGRect(x: x, y: 0, width: 1, height: pixels))
        }
        return ctx.makeImage()
    }

    /// A faint normal map (noise-perturbed) giving glass a subtle, uneven surface.
    static func glassNormal(pixels: Int = 256, strength: CGFloat = 10) -> CGImage? {
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        // Flat normal (0.5, 0.5, 1.0), then sparse soft bumps that nudge R/G.
        ctx.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 1.0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: pixels, height: pixels))

        var generator = SystemRandomNumberGenerator()
        let bumps = 60
        for _ in 0..<bumps {
            let cx = CGFloat.random(in: 0...CGFloat(pixels), using: &generator)
            let cy = CGFloat.random(in: 0...CGFloat(pixels), using: &generator)
            let radius = CGFloat.random(in: 8...28, using: &generator)
            let dx = CGFloat.random(in: -1...1, using: &generator)
            let dy = CGFloat.random(in: -1...1, using: &generator)
            let r = max(0, min(1, 0.5 + dx * strength / 255))
            let g = max(0, min(1, 0.5 + dy * strength / 255))
            ctx.setFillColor(CGColor(red: r, green: g, blue: 1.0, alpha: 0.5))
            ctx.fillEllipse(in: CGRect(x: cx - radius, y: cy - radius, width: radius * 2, height: radius * 2))
        }
        return ctx.makeImage()
    }
}
#endif
