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
        let showLabels = model.nodes.count <= style.labelDeclutterThreshold

        // Its OWN 3D layout — decoupled from the 2D grid. Nodes flow left-to-right along X by rank, and
        // the states at each rank fan around a Y-Z circle with a helical phase per rank, so every node
        // owns a distinct depth (Z) and the third dimension is genuinely used to keep arrows apart.
        let pos3D = compute3DLayout()
        func p(_ id: String) -> SCNVector3 { pos3D[id] ?? vec(0, 0, 0) }
        func vecF(_ s: SIMD3<Float>) -> SCNVector3 { vec(CGFloat(s.x), CGFloat(s.y), CGFloat(s.z)) }

        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for value in pos3D.values { let s = simd3(value); lo = simd_min(lo, s); hi = simd_max(hi, s) }
        if pos3D.isEmpty { lo = .zero; hi = .zero }
        let sceneCenter = (lo + hi) / 2
        let sceneRadius = max(simd_length(hi - lo) / 2, 3)
        let nodeHalf = Float(style.node3DSize) * Float(scale) / 2

        // Containers: translucent glass cubes bounding their descendants' 3D positions.
        let glassMat = glassMaterial()
        for node in model.nodes where node.type.isContainer {
            let descendants = leafDescendants(of: node.id)
            guard !descendants.isEmpty else { continue }
            var clo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
            var chi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
            for d in descendants { let s = simd3(p(d)); clo = simd_min(clo, s); chi = simd_max(chi, s) }
            // Extra vertical padding: the region box is deliberately taller than it needs to be so the
            // arrows and their labels around its states have room (top self-loops especially).
            let padXZ = nodeHalf + 0.4
            let padY = nodeHalf + 1.2
            clo -= SIMD3<Float>(padXZ, padY, padXZ)
            chi += SIMD3<Float>(padXZ, padY, padXZ)
            let sizeV = chi - clo
            let cube = SCNBox(width: CGFloat(sizeV.x), height: CGFloat(sizeV.y), length: CGFloat(sizeV.z), chamferRadius: 0.12)
            cube.firstMaterial = glassMat
            let cnode = SCNNode(geometry: cube)
            cnode.position = vecF((clo + chi) / 2)
            scene.rootNode.addChildNode(cnode)
            if showLabels, let title = labelPlaneNode(node.label, worldHeight: 0.5, fontSize: 15, weight: .bold) {
                // Fixed orientation (pinned to the cube — does not swivel to face the camera), lifted
                // above the box and nudged forward in Z so it never clips the glass.
                title.position = vec(0, CGFloat(sizeV.y) / 2 + 0.4, CGFloat(sizeV.z) / 2 + 0.06)
                cnode.addChildNode(title)
            }
        }
        
        

        // Edges: a cylinder + arrowhead grouped under one node named "edge|from|to", with the label
        // billboarded and ATTACHED to that group so it travels with the arrow.
        let autoLayout = model.useAutoLayoutForInspection
        var selfLoopCount: [String: Int] = [:]
        for edge in model.edges where edge.isSelfLoop { selfLoopCount[edge.from, default: 0] += 1 }
        var selfLoopSeen: [String: Int] = [:]
        for edge in model.edges {
            guard pos3D[edge.from] != nil, pos3D[edge.to] != nil else { continue }
            let highlighted = edge.from == selectedID || edge.to == selectedID
            let color = highlighted ? PlatformColor(style.activeEdgeColor)
                                    : (autoLayout ? edgeColor3D(edge) : PlatformColor(style.edgeColor))

            if edge.isSelfLoop {
                let idx = selfLoopSeen[edge.from, default: 0]; selfLoopSeen[edge.from] = idx + 1
                let loop = selfLoop3D(at: simd3(p(edge.from)), radius: nodeHalf, color: color,
                                      label: showLabels ? edge.label : "",
                                      loopIndex: idx, loopCount: selfLoopCount[edge.from, default: 1])
                loop.name = "edge|\(edge.from)|\(edge.to)"
                scene.rootNode.addChildNode(loop)
                continue
            }

            let pa = simd3(p(edge.from)), pb = simd3(p(edge.to))
            let len = simd_length(pb - pa)
            guard len > 1e-4 else { continue }
            let dir = (pb - pa) / len
            let start = pa + dir * (nodeHalf + 0.02)
            let tip = pb - dir * (nodeHalf + 0.02)
            let arrowSize: CGFloat = 0.16

            let group = SCNNode()
            group.name = "edge|\(edge.from)|\(edge.to)"
            let cyl = edgeNode(from: vecF(start), to: vecF(tip - dir * Float(arrowSize)), color: color, radius: 0.026)
            group.addChildNode(cyl)
            let arrow = arrowheadNode(tip: tip, direction: dir, color: color, size: arrowSize)
            arrow.name = "arrow|\(edge.from)|\(edge.to)"
            group.addChildNode(arrow)
            if showLabels, !edge.label.isEmpty, let lbl = labelPlaneNode(edge.label, worldHeight: 0.32, fontSize: 12) {
                // Pinned to the edge group (rotates with the scene, not the camera) but kept UPRIGHT:
                // it faces +Z and is tilted only by the arrow's screen-projected angle, so the top edge
                // stays roughly horizontal (a slight lean on diagonal arrows). Offset forward in Z so it
                // never clips the tube.
                var angle = atan2(Double(pb.y - pa.y), Double(pb.x - pa.x))
                if cos(angle) < 0 { angle += .pi }
                lbl.eulerAngles = vec(0, 0, CGFloat(angle))
                lbl.position = vecF((start + tip) / 2 + SIMD3<Float>(0, 0, 0.18))
                group.addChildNode(lbl)
            }
            scene.rootNode.addChildNode(group)
        }

        // Leaf nodes as brushed-metal plates at their 3D position, label billboarded on the front.
        for node in model.nodes where !node.type.isContainer {
            let s = CGFloat(style.node3DSize) * scale
            // Widen so all fanned self-loops (spaced 0.62 apart) still sit over the node.
            let loops = selfLoopCount[node.id] ?? 0
            let width = loops > 1 ? max(s * 1.7, CGFloat(loops - 1) * 0.62 + 0.72) : s * 1.7
            let box = SCNBox(width: width, height: s, length: s, chamferRadius: CGFloat(style.nodeCornerRadius) * scale)
            let mat = brushedMetalMaterial()
            box.materials = [mat]
            let snode = SCNNode(geometry: box)
            snode.name = node.id
            snode.position = p(node.id)
            applyMaterial(mat, for: node)
            scene.rootNode.addChildNode(snode)
            if showLabels, let label = labelPlaneNode(node.label, worldHeight: 0.42, fontSize: 13) {
                // Pinned to the node front face (rotates with the node, not the camera), proud of it in Z.
                label.position = vec(0, 0, s / 2 + 0.04)
                snode.addChildNode(label)
            }
        }

        addCamera3D(to: scene, center: sceneCenter, radius: sceneRadius)
        addLighting(to: scene)
        return scene
    }

    // MARK: - Decoupled 3D layout

    /// Assigns every (leaf) node its own 3D position: rank → X (left-to-right flow); the states at each
    /// rank fan around a circle in the Y-Z plane, and each rank's circle is rotated by a helical phase
    /// so nodes spiral through depth. A tiny per-node Z stagger guarantees no two share an exact Z.
    func compute3DLayout() -> [String: SCNVector3] {
        let leaves = model.nodes.filter { !$0.type.isContainer }
        guard !leaves.isEmpty else { return [:] }
        let leafIDs = Set(leaves.map(\.id))

        // Rank by BFS over leaf→leaf edges from the sources (no incoming), else the first node.
        var adjacency: [String: [String]] = [:]
        var indegree: [String: Int] = [:]
        for id in leafIDs { indegree[id] = 0 }
        for edge in model.edges where !edge.isSelfLoop && leafIDs.contains(edge.from) && leafIDs.contains(edge.to) {
            adjacency[edge.from, default: []].append(edge.to)
            indegree[edge.to, default: 0] += 1
        }
        var rank: [String: Int] = [:]
        var queue = leaves.map(\.id).filter { (indegree[$0] ?? 0) == 0 }.sorted()
        if queue.isEmpty { queue = [leaves.map(\.id).sorted()[0]] }   // fully cyclic → seed lowest id
        for id in queue { rank[id] = 0 }
        var head = 0
        while head < queue.count {
            let node = queue[head]; head += 1
            for next in (adjacency[node] ?? []).sorted() where rank[next] == nil {
                rank[next] = (rank[node] ?? 0) + 1
                queue.append(next)
            }
        }
        for leaf in leaves where rank[leaf.id] == nil { rank[leaf.id] = 0 }

        var byRank: [Int: [String]] = [:]
        for leaf in leaves { byRank[rank[leaf.id] ?? 0, default: []].append(leaf.id) }
        let maxRank = byRank.keys.max() ?? 0

        let xStep = CGFloat(style.layerZSpacing) * scale * 1.5
        var positions: [String: SCNVector3] = [:]
        var globalIndex = 0
        for r in 0...maxRank {
            let ids = (byRank[r] ?? []).sorted()
            let count = ids.count
            let radius = max(0.9, CGFloat(count) * 0.6)                 // Y-Z circle radius
            let x = (CGFloat(r) - CGFloat(maxRank) / 2) * xStep
            for (j, id) in ids.enumerated() {
                let angle = (count <= 1 ? 0 : CGFloat(j) / CGFloat(count) * 2 * .pi) + CGFloat(r) * 0.7
                let y = radius * cos(angle)
                let zc = radius * sin(angle) + CGFloat(globalIndex) * 0.02   // depth + unique-Z stagger
                positions[id] = vec(x, y, zc)
                globalIndex += 1
            }
        }
        return positions
    }

    /// Leaf-node ids anywhere under `id` (for sizing a container's bounding cube in 3D).
    private func leafDescendants(of id: String) -> [String] {
        var result: [String] = []
        for child in model.children(of: id) {
            if model.node(child)?.type.isContainer == true { result.append(contentsOf: leafDescendants(of: child)) }
            else { result.append(child) }
        }
        return result
    }

    /// A self-loop as a small torus + arrowhead at a node's position (billboarded label above it).
    private func selfLoop3D(at center: SIMD3<Float>, radius nodeHalf: Float, color: PlatformColor, label: String,
                            loopIndex: Int = 0, loopCount: Int = 1) -> SCNNode {
        // Fan multiple self-loops on the same node apart along X so none hides beneath another.
        let fan = Float(loopIndex) - Float(loopCount - 1) / 2
        let container = SCNNode()
        container.position = vec(CGFloat(center.x + fan * 0.62), CGFloat(center.y + nodeHalf + 0.28), CGFloat(center.z))
        let loopR: CGFloat = 0.26
        let ring = SCNTorus(ringRadius: loopR, pipeRadius: 0.024)
        let mat = SCNMaterial(); mat.diffuse.contents = color; mat.lightingModel = .constant
        ring.firstMaterial = mat
        let ringNode = SCNNode(geometry: ring)
        ringNode.eulerAngles = vec(CGFloat.pi / 2, 0, 0)   // face the camera plane
        container.addChildNode(ringNode)
        let arrow = arrowheadNode(tip: SIMD3<Float>(Float(loopR) * 0.7, -Float(loopR) * 0.7, 0),
                                  direction: SIMD3<Float>(0, -1, 0), color: color, size: 0.12)
        container.addChildNode(arrow)
        if !label.isEmpty, let lbl = labelPlaneNode(label, worldHeight: 0.3, fontSize: 12) {
            lbl.position = vec(0, CGFloat(loopR) + 0.2, 0.06)   // pinned above the ring, nudged forward
            container.addChildNode(lbl)
        }
        return container
    }

    /// Places the camera at a three-quarter angle so the depth is obvious immediately (SceneKit's
    /// built-in controller then lets the user orbit freely).
    private func addCamera3D(to scene: SCNScene, center: SIMD3<Float>, radius: Float) {
        let camera = SCNCamera()
        camera.zFar = 5000
        camera.fieldOfView = 50
        let node = SCNNode()
        node.camera = camera
        let d = max(radius * 1.9, 6)
        node.position = vec(CGFloat(center.x - d * 0.45), CGFloat(center.y + d * 0.35), CGFloat(center.z + d * 0.95))
        node.look(at: SCNVector3(center.x, center.y, center.z))
        node.name = "camera"
        scene.rootNode.addChildNode(node)
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

    /// The deepest nesting depth among this node and all its descendants — the far end of a container
    /// cube's depth span, so the cube reaches in front of its deepest substate.
    private func maxDescendantDepth(of id: String) -> Int {
        var maxDepth = nestingDepth(of: id)
        for kid in model.children(of: id) { maxDepth = max(maxDepth, maxDescendantDepth(of: kid)) }
        return maxDepth
    }

    /// The per-event edge colour (see `GraphEdge.stableHue`), so a 3D transition matches its 2D line.
    private func edgeColor3D(_ edge: GraphEdge) -> PlatformColor {
        PlatformColor(hue: CGFloat(edge.stableHue), saturation: 0.60, brightness: 0.82, alpha: 1)
    }

    /// A self-loop drawn as a small ring on the node's near face, with an arrowhead and an optional
    /// label above it. (Self-loops were previously skipped entirely in the 3D scene.)
    private func selfLoopNode(rect: CGRect, center: CGPoint, z: CGFloat, color: PlatformColor, label: String) -> SCNNode {
        let container = SCNNode()
        let loopR = max(min(rect.width, rect.height) * scale * 0.42, 0.18)

        let ring = SCNTorus(ringRadius: loopR, pipeRadius: 0.022)
        let mat = SCNMaterial()
        mat.diffuse.contents = color
        mat.lightingModel = .constant
        ring.firstMaterial = mat
        let ringNode = SCNNode(geometry: ring)
        ringNode.eulerAngles = vec(CGFloat.pi / 2, 0, 0)  // torus rings around Y; tilt it to face the camera (XY plane)
        container.addChildNode(ringNode)

        // Arrowhead at the ring's lower-right, pointing down into the node.
        let arrow = arrowheadNode(
            tip: SIMD3<Float>(Float(loopR) * 0.7, -Float(loopR) * 0.7, 0.02),
            direction: SIMD3<Float>(0, -1, 0), color: color, size: 0.12
        )
        container.addChildNode(arrow)

        if !label.isEmpty, let lbl = labelPlaneNode(label, worldHeight: 0.3, fontSize: 12) {
            lbl.position = vec(0, loopR + 0.22, 0.02)
            container.addChildNode(lbl)
        }

        // Sit above the node's top-centre, just proud of the node's front face.
        let top = CGPoint(x: rect.midX, y: rect.minY)
        container.position = vec(
            (top.x - center.x) * scale,
            -(top.y - center.y) * scale + loopR,
            z + CGFloat(style.node3DSize) * scale / 2 + 0.05
        )
        return container
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
    @MainActor private func refreshMaterials(in scnView: SCNView) {
        guard let root = scnView.scene?.rootNode else { return }
        for node in model.nodes where !node.type.isContainer {
            guard let snode = root.childNode(withName: node.id, recursively: false),
                  let mat = snode.geometry?.firstMaterial else { continue }
            applyMaterial(mat, for: node)
        }
        // Recolor edges: highlight those touching the selection, otherwise per-event colour. Recurse
        // so multi-part edges (e.g. self-loop rings) recolour too, but skip label planes (whose
        // "diffuse" is the text image, not a tint).
        let activeC = PlatformColor(style.activeEdgeColor)
        let neutralC = PlatformColor(style.edgeColor)
        let autoLayout = model.useAutoLayoutForInspection
        func tint(_ node: SCNNode?, _ color: PlatformColor) {
            guard let node else { return }
            if let geometry = node.geometry, !(geometry is SCNPlane) {
                geometry.firstMaterial?.diffuse.contents = color
            }
            for child in node.childNodes { tint(child, color) }
        }
        for edge in model.edges {
            let highlighted = edge.from == selectedID || edge.to == selectedID
            let color = highlighted ? activeC : (autoLayout ? edgeColor3D(edge) : neutralC)
            tint(root.childNode(withName: "edge|\(edge.from)|\(edge.to)", recursively: false), color)
            tint(root.childNode(withName: "arrow|\(edge.from)|\(edge.to)", recursively: false), color)
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
    
    struct Route3D { let curve: CubicBezier; let laneRank: Float }

    /// Bundles cross-transitions by unordered node pair, assigns lanes, and builds a cubic Bézier per
    /// edge that bows out along a **canonical** lateral axis (low-id → high-id) so a forward edge and
    /// its back-edge fan to opposite sides instead of coinciding. Nodes already sit at distinct 3D
    /// positions, so a modest bow is enough; a short lift clears any node the arc would otherwise graze.
    static func routeEdges3D(edges: [GraphEdge], pos: [String: SIMD3<Float>], foot: [String: Float],
                             obstacleIDs: Set<String>) -> [String: Route3D] {
        let up = SIMD3<Float>(0, 1, 0)
        let laneWidth: Float = 0.55
        var routes: [String: Route3D] = [:]

        func radius(_ id: String) -> Float { (foot[id] ?? 1) * 0.55 }

        func clears(_ curve: CubicBezier, _ from: String, _ to: String) -> Bool {
            for pt in curve.samples(18) {
                for id in obstacleIDs where id != from && id != to {
                    guard let p = pos[id] else { continue }
                    let rr = radius(id) + 0.1
                    let dx = pt.x - p.x, dy = pt.y - p.y, dz = pt.z - p.z
                    if dx * dx + dy * dy + dz * dz < rr * rr { return false }
                }
            }
            return true
        }

        var bundles: [String: [GraphEdge]] = [:]
        for e in edges where !e.isSelfLoop && pos[e.from] != nil && pos[e.to] != nil {
            let key = e.from < e.to ? "\(e.from)\u{1}\(e.to)" : "\(e.to)\u{1}\(e.from)"
            bundles[key, default: []].append(e)
        }
        for (_, members) in bundles {
            let sorted = members.sorted { $0.id < $1.id }
            let n = sorted.count
            let loID = min(sorted[0].from, sorted[0].to), hiID = max(sorted[0].from, sorted[0].to)
            guard let pl = pos[loID], let ph = pos[hiID] else { continue }
            var canon = ph - pl
            canon = vlength(canon) < 1e-5 ? SIMD3(1, 0, 0) : vnormalize(canon)
            var lateral = vcross(canon, up)
            lateral = vlength(lateral) < 1e-5 ? SIMD3(1, 0, 0) : vnormalize(lateral)

            for (i, e) in sorted.enumerated() {
                guard let a = pos[e.from], let b = pos[e.to] else { continue }
                let k = Float(i) - Float(n - 1) / 2
                let along = vnormalize(b - a)
                let p0 = a + along * radius(e.from)
                let p3 = b - along * radius(e.to)
                let dist = vlength(p3 - p0)
                let side: SIMD3<Float> = lateral * (k * laneWidth)
                let bow: SIMD3<Float> = up * (dist * 0.12 + 0.3)
                let ctrl: SIMD3<Float> = side + bow
                let step: SIMD3<Float> = along * (0.3 * dist)
                let p1 = p0 + step + ctrl
                let p2 = p3 - step + ctrl
                var curve = CubicBezier(p0, p1, p2, p3)
                var lift: Float = 0
                for _ in 0..<6 {
                    let liftV: SIMD3<Float> = up * lift
                    curve = CubicBezier(p0, p1 + liftV, p2 + liftV, p3)
                    if clears(curve, e.from, e.to) { break }
                    lift += 0.4
                }
                routes[e.id] = Route3D(curve: curve, laneRank: k)
            }
        }

        // "Drones must not hit each other": lift any two flightpaths that come too close onto separate
        // altitude bands. Edges sharing an asteroid legitimately meet there, so they're exempt. Runs a
        // few relaxation passes, always lifting the higher-id edge so it's deterministic and converges.
        let edgeByID = Dictionary(edges.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let clearance: Float = 0.5
        let ids = routes.keys.sorted()
        var samples: [String: [SIMD3<Float>]] = [:]
        for id in ids { samples[id] = routes[id]?.curve.samples(14) }
        for _ in 0..<6 {
            var moved = false
            for ia in 0..<ids.count {
                for ib in (ia + 1)..<ids.count {
                    guard let ea = edgeByID[ids[ia]], let eb = edgeByID[ids[ib]] else { continue }
                    if ea.from == eb.from || ea.from == eb.to || ea.to == eb.from || ea.to == eb.to { continue }
                    guard let sa = samples[ids[ia]], let sb = samples[ids[ib]] else { continue }
                    var minD: Float = .greatestFiniteMagnitude
                    for pa in sa { for pb in sb {
                        let d = vlength(pa - pb)
                        if d < minD { minD = d }
                    } }
                    if minD < clearance {
                        guard let rb = routes[ids[ib]] else { continue }
                        let push: Float = (clearance - minD) * 0.75 + 0.05
                        let liftV: SIMD3<Float> = SIMD3(0, push, 0)
                        let c = rb.curve
                        let nc = CubicBezier(c.p0, c.p1 + liftV, c.p2 + liftV, c.p3)
                        routes[ids[ib]] = Route3D(curve: nc, laneRank: rb.laneRank)
                        samples[ids[ib]] = nc.samples(14)
                        moved = true
                    }
                }
            }
            if !moved { break }
        }
        return routes
    }
}
#endif
