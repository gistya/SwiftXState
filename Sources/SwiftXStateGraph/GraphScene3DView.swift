#if SWIFTXSTATE_GRAPH_UI && canImport(SceneKit) && !os(watchOS)
import SwiftUI
import SceneKit
import simd

#if os(macOS)
import AppKit
typealias PlatformColor = NSColor
typealias PlatformFont = NSFont
typealias PlatformClickRecognizer = NSClickGestureRecognizer
#else
import UIKit
typealias PlatformColor = UIColor
typealias PlatformFont = UIFont
typealias PlatformClickRecognizer = UITapGestureRecognizer
#endif

/// A Metal-backed 3D renderer for the state graph using SceneKit.
///
/// Nodes are placed using the same 2D layout, lifted onto depth layers along the Z
/// axis (`GraphStyle.layerForNodeID`). SceneKit's built-in camera controller provides
/// orbit / pinch-zoom / pan around the graph for free, and rendering is GPU-instanced
/// so it scales to large machines far better than a DOM renderer.
struct GraphScene3DView {
    let model: GraphModel
    let layout: GraphLayoutResult
    let activeIDs: Set<String>
    let selectedID: String?
    let style: GraphStyle
    /// Called when the user taps a node (or empty space, with `nil`).
    var onSelect: (@MainActor (String?) -> Void)?

    /// World units per logical point.
    private var scale: CGFloat { 0.02 }

    @MainActor func makeCoordinator() -> Coordinator { Coordinator() }

    // MARK: Scene construction

    /// Builds the SceneKit scene. Internal so it can be rendered off-screen in tests
    /// (`SCNRenderer`) without a window.
    func buildScene() -> SCNScene {
        let scene = SCNScene()
        applyBackgroundAndEnvironment(to: scene)

        let bounds = layout.bounds
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let showLabels = model.nodes.count <= style.labelDeclutterThreshold

        // Depth comes from nesting level: deeper-nested nodes sit closer to the camera,
        // so panning/rotating reveals layered separation by hierarchy.
        func z(for id: String, offset: CGFloat = 0) -> CGFloat {
            CGFloat(nestingDepth(of: id)) * CGFloat(style.layerZSpacing) * scale + offset
        }
        func position(for rect: CGRect, z: CGFloat) -> SCNVector3 {
            vec((rect.midX - center.x) * scale, -(rect.midY - center.y) * scale, z)
        }

        // Containers: frosted "liquid glass" panes — one per nesting level, sitting just
        // behind their contents, with the region label floating in front.
        let glassMat = glassMaterial()
        for node in model.nodes where node.type.isContainer {
            guard let rect = layout.frame(node.id) else { continue }
            // Thick, rounded glass slab.
            let pane = SCNBox(width: rect.width * scale, height: rect.height * scale, length: 0.22, chamferRadius: 0.10)
            pane.firstMaterial = glassMat
            let snode = SCNNode(geometry: pane)
            snode.position = position(for: rect, z: z(for: node.id, offset: -0.16))
            scene.rootNode.addChildNode(snode)

            if showLabels, let title = labelPlaneNode(node.label, worldHeight: 0.5, fontSize: 15, weight: .bold) {
                // Child of the pane so it rotates with it; sits on the front face, near the top.
                let titleWidth = (title.geometry as? SCNPlane)?.width ?? 0
                title.position = vec(
                    -(rect.width * scale) / 2 + titleWidth / 2 + 0.25,
                    (rect.height * scale) / 2 - 0.42,
                    0.13
                )
                snode.addChildNode(title)
            }
        }

        // Edges as thick cylinders + arrowheads between node centers, with upright labels.
        for edge in model.edges where !edge.isSelfLoop {
            guard let from = layout.frame(edge.from), let to = layout.frame(edge.to) else { continue }
            let a = position(for: from, z: z(for: edge.from))
            let b = position(for: to, z: z(for: edge.to))
            let highlighted = edge.from == selectedID || edge.to == selectedID
            let color = PlatformColor(highlighted ? style.activeEdgeColor : style.edgeColor)

            let en = edgeNode(from: a, to: b, color: color, radius: 0.024)
            en.name = "edge|\(edge.from)|\(edge.to)"
            scene.rootNode.addChildNode(en)

            // Arrowhead just outside the target node's boundary, pointing in.
            let pa = simd3(a), pb = simd3(b)
            let length = simd_length(pb - pa)
            if length > 1e-4 {
                let dir = (pb - pa) / length
                let hw = Float(to.width) * Float(scale) / 2, hh = Float(to.height) * Float(scale) / 2
                let tx = abs(dir.x) > 1e-4 ? hw / abs(dir.x) : .greatestFiniteMagnitude
                let ty = abs(dir.y) > 1e-4 ? hh / abs(dir.y) : .greatestFiniteMagnitude
                let arrowSize: CGFloat = 0.15
                let pullback = min(min(tx, ty) + Float(arrowSize) * 0.5, length * 0.48)
                let tip = pb - dir * pullback
                let arrow = arrowheadNode(tip: tip, direction: dir, color: color, size: arrowSize)
                arrow.name = "arrow|\(edge.from)|\(edge.to)"
                scene.rootNode.addChildNode(arrow)
            }

            if showLabels, !edge.label.isEmpty, let lbl = labelPlaneNode(edge.label, worldHeight: 0.3, fontSize: 12) {
                // Sit at the midpoint, rotated to run along the edge but flipped if it would be
                // upside-down (right-to-left), and offset toward the camera so it doesn't clip.
                let mid = (pa + pb) / 2
                var angle = atan2(Double(pb.y - pa.y), Double(pb.x - pa.x))
                if cos(angle) < 0 { angle += .pi }   // keep text upright
                lbl.eulerAngles = vec(0, 0, CGFloat(angle))
                lbl.position = vec(CGFloat(mid.x), CGFloat(mid.y), CGFloat(mid.z) + 0.09)
                scene.rootNode.addChildNode(lbl)
            }
        }

        // Leaf nodes as solid plates at their nesting depth (the front-most layer).
        for node in model.nodes where !node.type.isContainer {
            guard let rect = layout.frame(node.id) else { continue }
            let box = SCNBox(
                width: rect.width * scale,
                height: rect.height * scale,
                length: CGFloat(style.node3DSize) * scale,
                chamferRadius: CGFloat(style.nodeCornerRadius) * scale
            )
            let mat = brushedMetalMaterial()
            box.materials = [mat]
            let snode = SCNNode(geometry: box)
            snode.name = node.id
            snode.position = position(for: rect, z: z(for: node.id))
            applyMaterial(mat, for: node)
            scene.rootNode.addChildNode(snode)

            if showLabels, let label = labelPlaneNode(node.label, worldHeight: 0.4, fontSize: 13) {
                // Child of the node so it rotates with it; on the front face, not inside it.
                label.position = vec(0, 0, CGFloat(style.node3DSize) * scale / 2 + 0.03)
                snode.addChildNode(label)
            }
        }

        addCamera(to: scene, bounds: bounds)
        addLighting(to: scene)
        return scene
    }

    /// Number of ancestor containers above this node (root = 0). Drives the depth layer.
    private func nestingDepth(of id: String) -> Int {
        var depth = 0
        var current = model.node(id)?.parentID
        while let parent = current {
            depth += 1
            current = model.node(parent)?.parentID
        }
        return depth
    }

    /// A clear glass material: see-through, sharp reflections (from the environment), a
    /// clear-coat sheen, and a faint normal map for realistic surface unevenness.
    private func glassMaterial() -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = PlatformColor(white: 0.75, alpha: 0.1)
        m.metalness.contents = 0.0
        m.roughness.contents = 0.08
        m.transparency = 0.42
        m.transparencyMode = .dualLayer
        m.clearCoat.contents = 0.1
        m.clearCoatRoughness.contents = 0.04
        if let normal = Scene3DTextures.glassNormalImage {
            m.normal.contents = normal
            m.normal.intensity = 0.35
        }
        m.isDoubleSided = true
        m.writesToDepthBuffer = false          // let layered panes blend instead of z-fighting
        return m
    }

    /// A brushed-metal material (anisotropic-looking streaks via a roughness map + strong
    /// metalness). `applyMaterial` then tints the base color per node and adds active/selected glow.
    private func brushedMetalMaterial() -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.metalness.contents = 0.9
        m.roughness.contents = Scene3DTextures.brushedRoughnessImage ?? (0.34 as NSNumber)
        m.diffuse.contents = PlatformColor(white: 0.7, alpha: 1)
        return m
    }

    private func swiftOrangeCG(alpha: CGFloat) -> CGColor {
        CGColor(srgbRed: 0.941, green: 0.318, blue: 0.220, alpha: alpha)
    }

    /// Sets the backdrop (a distant, blurred hex grid for depth) and the reflection
    /// environment (a lighter-blurred hex grid so glass/metal pick up the orange).
    private func applyBackgroundAndEnvironment(to scene: SCNScene) {
        let bg = PlatformColor(style.backgroundColor)
        if style.gridStyle == .hexagonal,
           let hex = Scene3DTextures.hexGrid(pixels: 1024, hexRadius: 40,
                                             line: swiftOrangeCG(alpha: 0.1),
                                             background: bg.cgColor, lineWidth: 1.0) {
            scene.background.contents = hex
            scene.lightingEnvironment.contents = Scene3DTextures.blurred(hex, radius: 6) ?? hex
            scene.lightingEnvironment.intensity = 1.2
        } else {
            scene.background.contents = bg
            scene.lightingEnvironment.contents = PlatformColor(white: 0.4, alpha: 1)
            scene.lightingEnvironment.intensity = 0.6
        }
    }

    private func addCamera(to scene: SCNScene, bounds: CGRect) {
        let camera = SCNCamera()
        camera.zFar = 5000
        camera.fieldOfView = 50
        let node = SCNNode()
        node.camera = camera
        let radius = max(bounds.width, bounds.height) * scale
        node.position = vec(0, 0, max(radius * 1.4, 6))
        node.name = "camera"
        scene.rootNode.addChildNode(node)
    }

    private func addLighting(to scene: SCNScene) {
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 500
        scene.rootNode.addChildNode(ambient)

        let directional = SCNNode()
        directional.light = SCNLight()
        directional.light?.type = .directional
        directional.light?.intensity = 700
        directional.eulerAngles = vec(-0.6, 0.4, 0)
        scene.rootNode.addChildNode(directional)

        // A second rim light gives the glass clear-coat its highlights.
        let rim = SCNNode()
        rim.light = SCNLight()
        rim.light?.type = .directional
        rim.light?.intensity = 450
        rim.eulerAngles = vec(0.7, -0.8, 0.2)
        scene.rootNode.addChildNode(rim)
        // The reflection environment is set in `applyBackgroundAndEnvironment`.
    }

    // MARK: Materials / highlight

    private func applyMaterial(_ mat: SCNMaterial, for node: GraphNode) {
        let isActive = activeIDs.contains(node.id)
        let isSelected = node.id == selectedID
        let fill: Color
        switch node.type {
        case .final: fill = isActive ? style.activeNodeFill : style.finalNodeFill
        case .history: fill = style.historyNodeFill
        default: fill = isActive ? style.activeNodeFill : style.idleNodeFill
        }
        mat.diffuse.contents = PlatformColor(fill)
        if isSelected {
            mat.emission.contents = PlatformColor(style.selectedNodeStroke)
        } else if isActive {
            mat.emission.contents = PlatformColor(style.activeNodeFill)
        } else {
            mat.emission.contents = PlatformColor.black
        }
    }

    /// Refresh only the per-node materials + edge colors (cheap) when the active set / selection changes.
    private func refreshMaterials(in scnView: SCNView) {
        guard let root = scnView.scene?.rootNode else { return }
        for node in model.nodes where !node.type.isContainer {
            guard let snode = root.childNode(withName: node.id, recursively: false),
                  let mat = snode.geometry?.firstMaterial else { continue }
            applyMaterial(mat, for: node)
        }
        // Highlight edges connected to the selected node (and their arrowheads).
        let edgeC = PlatformColor(style.edgeColor)
        let activeC = PlatformColor(style.activeEdgeColor)
        for edge in model.edges where !edge.isSelfLoop {
            let highlighted = edge.from == selectedID || edge.to == selectedID
            let color = highlighted ? activeC : edgeC
            for prefix in ["edge", "arrow"] {
                root.childNode(withName: "\(prefix)|\(edge.from)|\(edge.to)", recursively: false)?
                    .geometry?.firstMaterial?.diffuse.contents = color
            }
        }
    }

    // MARK: Geometry helpers

    /// A flat, light-colored text label (rendered to an image with a soft drop shadow for
    /// readability). Added as a child of its node/pane so it rotates with the object.
    private func labelPlaneNode(_ text: String, worldHeight: CGFloat, fontSize: CGFloat, weight: PlatformFont.Weight = .semibold) -> SCNNode? {
        guard let (image, aspect) = Scene3DTextures.textImage(
            text, fontSize: fontSize, weight: weight, color: CGColor(gray: 0.97, alpha: 1)
        ) else { return nil }
        let plane = SCNPlane(width: worldHeight * aspect, height: worldHeight)
        let mat = SCNMaterial()
        mat.diffuse.contents = image
        mat.lightingModel = .constant
        mat.isDoubleSided = true
        plane.firstMaterial = mat
        return SCNNode(geometry: plane)
    }

    /// A thick cylinder edge from `a` to `b`.
    private func edgeNode(from a: SCNVector3, to b: SCNVector3, color: PlatformColor, radius: CGFloat) -> SCNNode {
        let pa = simd3(a), pb = simd3(b)
        let dir = pb - pa
        let length = simd_length(dir)
        let cylinder = SCNCylinder(radius: radius, height: CGFloat(length))
        let mat = SCNMaterial()
        mat.diffuse.contents = color
        mat.lightingModel = .constant
        cylinder.firstMaterial = mat
        let node = SCNNode(geometry: cylinder)
        let mid = (pa + pb) / 2
        node.position = vec(CGFloat(mid.x), CGFloat(mid.y), CGFloat(mid.z))
        if length > 1e-5 {
            // Cylinders are built along +Y; rotate that axis onto the edge direction.
            node.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: dir / length)
        }
        return node
    }

    /// A cone arrowhead whose tip sits at `tip`, pointing along `direction`.
    private func arrowheadNode(tip: SIMD3<Float>, direction: SIMD3<Float>, color: PlatformColor, size: CGFloat) -> SCNNode {
        let cone = SCNCone(topRadius: 0, bottomRadius: size * 0.5, height: size)
        let mat = SCNMaterial()
        mat.diffuse.contents = color
        mat.lightingModel = .constant
        cone.firstMaterial = mat
        let node = SCNNode(geometry: cone)
        node.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: direction)  // apex (+Y) → direction
        let center = tip - direction * Float(size / 2)
        node.position = vec(CGFloat(center.x), CGFloat(center.y), CGFloat(center.z))
        return node
    }

    private func simd3(_ v: SCNVector3) -> SIMD3<Float> {
        #if os(macOS)
        return SIMD3<Float>(Float(v.x), Float(v.y), Float(v.z))
        #else
        return SIMD3<Float>(v.x, v.y, v.z)
        #endif
    }

    @MainActor
    final class Coordinator: NSObject {
        var structureHash: Int?
        var onSelect: (@MainActor (String?) -> Void)?
        var nodeIDs: Set<String> = []
        var currentSelected: String?
        weak var scnView: SCNView?

        @objc func handleTap(_ recognizer: PlatformClickRecognizer) {
            guard let scnView else { return }
            let point = recognizer.location(in: scnView)
            let hits = scnView.hitTest(point, options: [.searchMode: SCNHitTestSearchMode.all.rawValue])
            var found: String?
            search: for hit in hits {
                var candidate: SCNNode? = hit.node
                while let node = candidate {
                    if let name = node.name, nodeIDs.contains(name) { found = name; break search }
                    candidate = node.parent
                }
            }
            onSelect?(found == currentSelected ? nil : found)  // toggle; nil deselects
        }
    }
}

// MARK: - Platform vector helpers (SCNVector3 uses CGFloat on macOS, Float on iOS)

private func vec(_ x: CGFloat, _ y: CGFloat, _ z: CGFloat) -> SCNVector3 {
    #if os(macOS)
    return SCNVector3(x, y, z)
    #else
    return SCNVector3(Float(x), Float(y), Float(z))
    #endif
}

private func addZ(_ z: SCNFloat, _ delta: CGFloat) -> SCNFloat {
    #if os(macOS)
    return z + delta
    #else
    return z + Float(delta)
    #endif
}

// MARK: - Representable conformance

#if os(macOS)
extension GraphScene3DView: NSViewRepresentable {
    func makeNSView(context: Context) -> SCNView { makeView(context.coordinator) }
    func updateNSView(_ scnView: SCNView, context: Context) { updateView(scnView, context.coordinator) }
}
#else
extension GraphScene3DView: UIViewRepresentable {
    func makeUIView(context: Context) -> SCNView { makeView(context.coordinator) }
    func updateUIView(_ scnView: SCNView, context: Context) { updateView(scnView, context.coordinator) }
}
#endif

extension GraphScene3DView {
    @MainActor
    fileprivate func makeView(_ coordinator: Coordinator) -> SCNView {
        let scnView = SCNView()
        scnView.allowsCameraControl = true
        scnView.autoenablesDefaultLighting = false
        scnView.antialiasingMode = .multisampling4X
        scnView.backgroundColor = PlatformColor(style.backgroundColor)
        scnView.scene = buildScene()
        coordinator.structureHash = model.structureHash
        coordinator.scnView = scnView
        coordinator.onSelect = onSelect
        coordinator.nodeIDs = Set(model.nodes.map(\.id))
        coordinator.currentSelected = selectedID
        let tap = PlatformClickRecognizer(target: coordinator, action: #selector(Coordinator.handleTap(_:)))
        scnView.addGestureRecognizer(tap)
        return scnView
    }

    @MainActor
    fileprivate func updateView(_ scnView: SCNView, _ coordinator: Coordinator) {
        coordinator.onSelect = onSelect
        coordinator.currentSelected = selectedID
        if coordinator.structureHash != model.structureHash {
            // Structure changed: rebuild. Restore the camera on the new scene *before*
            // presenting it, so there's no one-frame flash of the default viewpoint.
            let pov = scnView.pointOfView?.transform
            let newScene = buildScene()
            if let pov, let camera = newScene.rootNode.childNode(withName: "camera", recursively: false) {
                camera.transform = pov
            }
            scnView.scene = newScene
            coordinator.structureHash = model.structureHash
            coordinator.nodeIDs = Set(model.nodes.map(\.id))
        } else {
            refreshMaterials(in: scnView)
        }
    }
}
#endif
