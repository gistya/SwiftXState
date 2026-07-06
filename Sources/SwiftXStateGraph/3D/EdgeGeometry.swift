//  EdgeGeometry.swift
//  Adapted from the scenekit-3d-statecharts skill (assets/EdgeGeometry.swift).
//
//  Cubic Bézier evaluation, parallel-transport frames, tube mesh -> SCNGeometry,
//  and arrowhead transform. Parallel transport is used (rather than per-sample
//  lookAt) so the tube never twists or collapses where the tangent approaches
//  a reference axis.
#if SWIFTXSTATE_GRAPH_UI && canImport(SceneKit) && !os(watchOS)
import Foundation
import simd
import SceneKit

// MARK: - Vector helpers (stdlib SIMD3 only, so the pure math stays testable anywhere)

@inline(__always) func vdot(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float { (a * b).sum() }
@inline(__always) func vlength(_ a: SIMD3<Float>) -> Float { vdot(a, a).squareRoot() }
@inline(__always) func vnormalize(_ a: SIMD3<Float>) -> SIMD3<Float> { a / vlength(a) }
@inline(__always) func vcross(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> {
    SIMD3(a.y*b.z - a.z*b.y, a.z*b.x - a.x*b.z, a.x*b.y - a.y*b.x)
}
/// Rodrigues rotation: rotate `v` around unit `axis` by `angle`.
@inline(__always) func vrotate(_ v: SIMD3<Float>, axis: SIMD3<Float>, angle: Float) -> SIMD3<Float> {
    let c = cosf(angle), s = sinf(angle)
    let term1 = v * c
    let term2 = vcross(axis, v) * s
    let term3 = axis * (vdot(axis, v) * (1 - c))
    return term1 + term2 + term3
}

// MARK: - Cubic Bézier (pure Swift — unit-testable anywhere)

struct CubicBezier {
    var p0, p1, p2, p3: SIMD3<Float>

    init(_ p0: SIMD3<Float>, _ p1: SIMD3<Float>, _ p2: SIMD3<Float>, _ p3: SIMD3<Float>) {
        (self.p0, self.p1, self.p2, self.p3) = (p0, p1, p2, p3)
    }

    func point(_ t: Float) -> SIMD3<Float> {
        // Scalar Bernstein weights precomputed as explicit Float, then vector-scaled — keeps each
        // sub-expression trivially typed (the inline `3*u*u*t * p1 + …` form is too complex to type-check).
        let u = 1 - t
        let w0: Float = u * u * u
        let w1: Float = 3 * u * u * t
        let w2: Float = 3 * u * t * t
        let w3: Float = t * t * t
        return p0 * w0 + p1 * w1 + p2 * w2 + p3 * w3
    }

    func tangent(_ t: Float) -> SIMD3<Float> {
        let u = 1 - t
        let c0: Float = 3 * u * u
        let c1: Float = 6 * u * t
        let c2: Float = 3 * t * t
        // Annotate each term SIMD3<Float> so the solver doesn't explore vector/scalar `*`/`-`/`+`
        // overloads across the whole sum. The fully-inferred one-liner takes Xcode's type-checker
        // ~3.3s (and can hard-fail); split into typed terms it's <20ms (measured with xcrun swiftc 6.2).
        let d0: SIMD3<Float> = (p1 - p0) * c0
        let d1: SIMD3<Float> = (p2 - p1) * c1
        let d2: SIMD3<Float> = (p3 - p2) * c2
        let d: SIMD3<Float> = d0 + d1 + d2
        let len = vlength(d)
        if len < 1e-6 { return vnormalize(p3 - p0) }
        return d / len
    }

    func samples(_ count: Int) -> [SIMD3<Float>] {
        (0..<count).map { point(Float($0) / Float(count - 1)) }
    }
}

// MARK: - Parallel-transport frames

struct PathFrame {
    var position: SIMD3<Float>
    var tangent: SIMD3<Float>
    var normal: SIMD3<Float>
    var binormal: SIMD3<Float>
}

/// Builds one orthonormal frame per sample by transporting the initial normal along the curve,
/// avoiding the twisting/flipping that naive cross-product frames exhibit near inflection points.
func parallelTransportFrames(along curve: CubicBezier, sampleCount: Int = 24) -> [PathFrame] {
    precondition(sampleCount >= 2)
    let denom = Float(sampleCount - 1)
    let ts: [Float] = (0..<sampleCount).map { Float($0) / denom }
    let positions = ts.map(curve.point)
    let tangents = ts.map(curve.tangent)

    let t0 = tangents[0]
    let ref: SIMD3<Float> = abs(t0.y) < 0.9 ? [0, 1, 0] : [1, 0, 0]
    var normal = vnormalize(ref - t0 * vdot(ref, t0))

    var frames: [PathFrame] = []
    frames.reserveCapacity(sampleCount)
    for i in 0..<sampleCount {
        if i > 0 {
            let prev = tangents[i - 1], curr = tangents[i]
            let axis = vcross(prev, curr)
            let axisLen = vlength(axis)
            if axisLen > 1e-6 {
                let angle = atan2f(axisLen, vdot(prev, curr))
                normal = vnormalize(vrotate(normal, axis: axis / axisLen, angle: angle))
            }
            normal = vnormalize(normal - curr * vdot(normal, curr))
        }
        let t = tangents[i]
        frames.append(PathFrame(position: positions[i], tangent: t,
                                normal: normal, binormal: vnormalize(vcross(t, normal))))
    }
    return frames
}

// MARK: - Tube mesh

enum EdgeGeometry {

    /// Tube following `curve`. `shortenEnd` pulls the tube back from t=1 so an arrowhead cone can
    /// occupy the tip without the tube poking through.
    static func tube(along curve: CubicBezier, radius: Float = 0.05, radialSegments: Int = 8,
                     lengthSamples: Int = 24, shortenEnd: Float = 0) -> SCNGeometry {
        var c = curve
        if shortenEnd > 0 {
            let tip = curve.point(1), tan = curve.tangent(1)
            c.p3 = tip - tan * shortenEnd
        }
        let frames = parallelTransportFrames(along: c, sampleCount: lengthSamples)

        var vertices: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        let ring = radialSegments + 1

        for f in frames {
            for s in 0...radialSegments {
                let a = Float(s) / Float(radialSegments) * 2 * .pi
                let n = cosf(a) * f.normal + sinf(a) * f.binormal
                vertices.append(f.position + n * radius)
                normals.append(n)
            }
        }
        for i in 0..<(frames.count - 1) {
            for s in 0..<radialSegments {
                let a = UInt32(i * ring + s), b = a + 1
                let cIdx = UInt32((i + 1) * ring + s), d = cIdx + 1
                indices.append(contentsOf: [a, cIdx, b, b, cIdx, d])
            }
        }

        let vSrc = SCNGeometrySource(vertices: vertices.map(SCNVector3.init))
        let nSrc = SCNGeometrySource(normals: normals.map(SCNVector3.init))
        let elem = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        return SCNGeometry(sources: [vSrc, nSrc], elements: [elem])
    }

    /// Arrowhead cone node aligned with the curve's end tangent, tip at t=1.
    static func arrowheadNode(for curve: CubicBezier, tubeRadius: Float = 0.05) -> SCNNode {
        let coneLen = tubeRadius * 4
        let cone = SCNCone(topRadius: 0, bottomRadius: CGFloat(tubeRadius * 2.5), height: CGFloat(coneLen))
        let node = SCNNode(geometry: cone)
        let tip = curve.point(1)
        let dir = curve.tangent(1)
        node.simdOrientation = simd_quatf(from: [0, 1, 0], to: dir)
        node.simdPosition = tip - dir * (coneLen / 2)
        return node
    }
}

private extension SCNVector3 {
    init(_ v: SIMD3<Float>) {
        #if os(macOS)
        self.init(CGFloat(v.x), CGFloat(v.y), CGFloat(v.z))
        #else
        self.init(v.x, v.y, v.z)
        #endif
    }
}
#endif
