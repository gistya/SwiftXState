import SwiftUI

/// Background grid styles for the graph canvas / 3D backdrop.
public enum GraphGridStyle: String, Sendable, CaseIterable {
    case none
    case square
    case hexagonal
}

/// A customizable style descriptor for the state-machine graph visualizer.
///
/// Think of `GraphStyle` as "CSS for the graph". Construct one (or start from a
/// preset like `.default` / `.dark` / `.compact`), tweak whatever you like, and
/// inject it into the view hierarchy with `.graphStyle(_:)`. Every renderer — the
/// 2D Canvas and the 3D SceneKit view — reads from the same struct, so consumers
/// fully control appearance, layout metrics, and interaction tuning without forking
/// the library.
///
/// ```swift
/// var style = GraphStyle.dark
/// style.nodeCornerRadius = 14
/// style.activeNodeFill = .green
///
/// MachineGraphView(actor: actor, machine: machine)
///     .graphStyle(style)
/// ```
public struct GraphStyle: Sendable {
    // Not `Equatable`: it carries the customizable `layerForNodeID` closure.

    // MARK: - Canvas / background

    public var backgroundColor: Color = Color(white: 0.97)
    /// Background grid style: `.none`, `.square`, or `.hexagonal` (default).
    public var gridStyle: GraphGridStyle = .hexagonal
    /// Swift-orange grid lines (matches the SwiftXState logo, `#F05138`).
    public var gridColor: Color = Color(.sRGB, red: 0.941, green: 0.318, blue: 0.220, opacity: 0.18)
    public var gridSpacing: CGFloat = 28

    // MARK: - Leaf nodes (atomic / final / history)

    public var nodeCornerRadius: CGFloat = 10
    public var nodeBorderWidth: CGFloat = 1.5
    public var nodeMinWidth: CGFloat = 104
    public var nodeMinHeight: CGFloat = 44
    public var nodePadding: CGFloat = 16
    public var nodeShadowRadius: CGFloat = 4
    public var nodeShadowOpacity: Double = 0.18

    public var idleNodeFill: Color = .white
    public var idleNodeStroke: Color = Color(.sRGB, red: 0.72, green: 0.74, blue: 0.80, opacity: 1)
    public var idleNodeTextColor: Color = Color(white: 0.15)

    public var activeNodeFill: Color = Color(.sRGB, red: 0.20, green: 0.52, blue: 0.96, opacity: 1)
    public var activeNodeStroke: Color = Color(.sRGB, red: 0.13, green: 0.36, blue: 0.78, opacity: 1)
    public var activeNodeTextColor: Color = .white
    public var activeNodeGlowRadius: CGFloat = 10

    public var finalNodeFill: Color = Color(.sRGB, red: 0.27, green: 0.66, blue: 0.42, opacity: 1)
    public var finalNodeStroke: Color = Color(.sRGB, red: 0.16, green: 0.45, blue: 0.28, opacity: 1)
    public var finalNodeTextColor: Color = .white

    public var historyNodeFill: Color = Color(.sRGB, red: 0.85, green: 0.80, blue: 0.55, opacity: 1)

    public var selectedNodeStroke: Color = Color(.sRGB, red: 0.98, green: 0.62, blue: 0.10, opacity: 1)
    public var selectedNodeStrokeWidth: CGFloat = 3

    public var nodeLabelFontSize: CGFloat = 13
    public var nodeLabelWeight: Font.Weight = .semibold

    // MARK: - Regions (compound / parallel containers)

    public var regionCornerRadius: CGFloat = 16
    public var regionBorderWidth: CGFloat = 1.5
    public var regionHeaderHeight: CGFloat = 30
    public var regionPadding: CGFloat = 22
    /// Vertical gap between stacked regions inside a parallel state.
    public var regionSpacing: CGFloat = 28

    public var compoundRegionFill: Color = Color(.sRGB, red: 0.93, green: 0.95, blue: 0.99, opacity: 0.55)
    public var compoundRegionStroke: Color = Color(.sRGB, red: 0.70, green: 0.76, blue: 0.88, opacity: 1)

    public var parallelRegionFill: Color = Color(.sRGB, red: 0.99, green: 0.96, blue: 0.90, opacity: 0.55)
    public var parallelRegionStroke: Color = Color(.sRGB, red: 0.85, green: 0.74, blue: 0.55, opacity: 1)
    /// Color of the dashed divider drawn between parallel sub-regions.
    public var parallelDividerColor: Color = Color(.sRGB, red: 0.80, green: 0.68, blue: 0.45, opacity: 0.7)

    public var regionTitleFontSize: CGFloat = 12
    public var regionTitleWeight: Font.Weight = .bold
    public var regionTitleColor: Color = Color(white: 0.32)
    /// Highlight tint applied to a region's header when the region is active.
    public var activeRegionTitleColor: Color = Color(.sRGB, red: 0.13, green: 0.36, blue: 0.78, opacity: 1)

    // MARK: - Layout metrics

    /// **Horizontal** gap between successive layered "ranks" (columns) of an auto-laid-out
    /// compound region — i.e. how far apart left-to-right the steps of a flow are. Smaller =
    /// a tighter graph (nodes look bigger when zoomed to fit). Ignored for `nodeLayoutOverride`
    /// (custom) placement.
    public var rankSpacing: CGFloat = 60
    /// **Vertical** gap between sibling nodes stacked within the same rank (column) of an
    /// auto-laid-out region. Smaller = a tighter graph. Ignored for custom placement.
    public var nodeSpacing: CGFloat = 22
    /// Back-compat aliases (older code referenced these names).
    public var horizontalSpacing: CGFloat { rankSpacing }
    public var verticalSpacing: CGFloat { nodeSpacing }

    // MARK: - Edges / transitions

    public var edgeWidth: CGFloat = 1.8
    public var edgeColor: Color = Color(.sRGB, red: 0.45, green: 0.48, blue: 0.55, opacity: 0.85)
    public var activeEdgeColor: Color = Color(.sRGB, red: 0.20, green: 0.52, blue: 0.96, opacity: 1)
    public var activeEdgeWidth: CGFloat = 2.6
    /// 0 = straight lines, higher = more curvature.
    public var edgeCurveTension: CGFloat = 0.32

    public var arrowLength: CGFloat = 9
    public var arrowWidth: CGFloat = 7

    public var selfLoopRadius: CGFloat = 26

    /// Dash pattern applied to guarded transitions (empty = solid).
    public var guardedEdgeDash: [CGFloat] = [5, 4]

    public var edgeLabelFontSize: CGFloat = 11
    public var edgeLabelColor: Color = Color(white: 0.28)
    public var edgeLabelBackground: Color = Color(white: 1.0, opacity: 0.88)

    // MARK: - Initial-state indicator

    public var initialDotRadius: CGFloat = 5
    public var initialDotColor: Color = Color(white: 0.25)

    // MARK: - Custom layout

    /// Optional explicit placement for nodes, overriding the automatic layered layout.
    /// Given a node's id and its dotted relative path, return the **center** of that node in
    /// logical coordinates (any consistent scale), or `nil` to auto-place it.
    ///
    /// When *every* direct child of a container has an override, that container switches to
    /// custom placement and is sized to enclose them — this is how, e.g., a chess board's 64
    /// square states can be arranged as an 8×8 grid even though they share no transitions.
    /// Partial overrides within a container are ignored (the container stays auto-laid-out).
    public var nodeLayoutOverride: (@Sendable (_ id: String, _ relativePath: String) -> CGPoint?)?

    // MARK: - Interaction

    public var zoomMin: CGFloat = 0.01
    public var zoomMax: CGFloat = 6.0
    public var zoomStep: CGFloat = 1.15
    /// How much fit-to-view padding to leave around the graph (fraction of viewport).
    public var fitPadding: CGFloat = 0.08

    // MARK: - 3D / layers

    /// Distance between logical layers along the depth axis in the 3D renderer.
    public var layerZSpacing: Float = 90
    /// Base size of a node in the 3D scene.
    public var node3DSize: Float = 26
    public var enable3DRotation: Bool = true
    /// Whether the 3D scene draws the floor grid.
    public var show3DFloor: Bool = true

    /// Assigns a logical depth layer to a node (higher renders "above"/closer).
    /// Defaults to type-based banding; override to push specific nodes forward/back.
    public var layerForNodeID: @Sendable (_ id: String, _ isParallel: Bool, _ isFinal: Bool) -> Float = { _, isParallel, isFinal in
        if isFinal { return 1 }
        if isParallel { return 2 }
        return 0
    }

    // MARK: - Animation

    public var layoutAnimationDuration: Double = 0.4
    public var stateChangeHighlightDuration: Double = 0.45

    // MARK: - Misc

    /// Above this node count the 2D renderer drops edge labels and node shadows to
    /// keep large graphs smooth.
    public var labelDeclutterThreshold: Int = 220

    public init() {}

    public static let `default` = GraphStyle()

    /// Compact metrics for dense machines or side panels.
    public static var compact: GraphStyle {
        var style = GraphStyle()
        style.nodeMinWidth = 78
        style.nodeMinHeight = 34
        style.nodePadding = 10
        style.rankSpacing = 40
        style.nodeSpacing = 14
        style.regionPadding = 14
        style.regionHeaderHeight = 24
        style.nodeLabelFontSize = 11
        style.regionTitleFontSize = 10
        style.edgeWidth = 1.4
        style.nodeShadowRadius = 2
        return style
    }

    /// A dark theme suitable for an inspector window.
    public static var dark: GraphStyle {
        var style = GraphStyle()
        style.backgroundColor = Color(.sRGB, red: 0.10, green: 0.11, blue: 0.13, opacity: 1)
        style.gridStyle = .hexagonal
        style.gridColor = Color(.sRGB, red: 0.941, green: 0.318, blue: 0.220, opacity: 0.22)

        style.idleNodeFill = Color(.sRGB, red: 0.18, green: 0.20, blue: 0.24, opacity: 1)
        style.idleNodeStroke = Color(.sRGB, red: 0.34, green: 0.38, blue: 0.45, opacity: 1)
        style.idleNodeTextColor = Color(white: 0.86)

        style.activeNodeFill = Color(.sRGB, red: 0.24, green: 0.58, blue: 0.99, opacity: 1)
        style.activeNodeStroke = Color(.sRGB, red: 0.50, green: 0.76, blue: 1.0, opacity: 1)
        style.activeNodeTextColor = .white

        style.finalNodeFill = Color(.sRGB, red: 0.28, green: 0.70, blue: 0.45, opacity: 1)
        style.finalNodeStroke = Color(.sRGB, red: 0.45, green: 0.85, blue: 0.60, opacity: 1)

        style.compoundRegionFill = Color(white: 1.0, opacity: 0.04)
        style.compoundRegionStroke = Color(white: 1.0, opacity: 0.16)
        style.parallelRegionFill = Color(.sRGB, red: 0.55, green: 0.45, blue: 0.20, opacity: 0.10)
        style.parallelRegionStroke = Color(.sRGB, red: 0.70, green: 0.58, blue: 0.30, opacity: 0.6)
        style.parallelDividerColor = Color(.sRGB, red: 0.70, green: 0.58, blue: 0.30, opacity: 0.5)

        style.regionTitleColor = Color(white: 0.70)
        style.activeRegionTitleColor = Color(.sRGB, red: 0.50, green: 0.76, blue: 1.0, opacity: 1)

        style.edgeColor = Color(white: 1.0, opacity: 0.30)
        style.activeEdgeColor = Color(.sRGB, red: 0.50, green: 0.76, blue: 1.0, opacity: 1)
        style.edgeLabelColor = Color(white: 0.82)
        style.edgeLabelBackground = Color(white: 0.10, opacity: 0.85)
        style.initialDotColor = Color(white: 0.80)
        return style
    }

    /// Chess-themed warm palette used by the SwiftXChess demo window.
    public static var chessDefault: GraphStyle {
        var style = GraphStyle()
        style.backgroundColor = Color(.sRGB, red: 0.96, green: 0.93, blue: 0.87, opacity: 1)
        style.gridColor = Color(.sRGB, red: 0.40, green: 0.28, blue: 0.16, opacity: 0.05)
        style.nodeCornerRadius = 7

        style.idleNodeFill = Color(.sRGB, red: 0.98, green: 0.95, blue: 0.89, opacity: 1)
        style.idleNodeStroke = Color(.sRGB, red: 0.55, green: 0.42, blue: 0.28, opacity: 1)
        style.idleNodeTextColor = Color(.sRGB, red: 0.30, green: 0.22, blue: 0.13, opacity: 1)

        style.activeNodeFill = Color(.sRGB, red: 0.20, green: 0.52, blue: 0.82, opacity: 1)
        style.activeNodeStroke = Color(.sRGB, red: 0.10, green: 0.33, blue: 0.58, opacity: 1)
        style.activeNodeGlowRadius = 12

        style.rankSpacing = 96
        style.nodeSpacing = 30

        style.finalNodeFill = Color(.sRGB, red: 0.40, green: 0.55, blue: 0.30, opacity: 1)
        style.finalNodeStroke = Color(.sRGB, red: 0.26, green: 0.38, blue: 0.18, opacity: 1)

        style.compoundRegionFill = Color(.sRGB, red: 0.94, green: 0.90, blue: 0.82, opacity: 0.55)
        style.compoundRegionStroke = Color(.sRGB, red: 0.62, green: 0.50, blue: 0.34, opacity: 1)
        style.parallelRegionFill = Color(.sRGB, red: 0.90, green: 0.84, blue: 0.72, opacity: 0.55)
        style.parallelRegionStroke = Color(.sRGB, red: 0.55, green: 0.42, blue: 0.26, opacity: 1)
        style.parallelDividerColor = Color(.sRGB, red: 0.55, green: 0.42, blue: 0.26, opacity: 0.6)
        style.regionTitleColor = Color(.sRGB, red: 0.42, green: 0.30, blue: 0.18, opacity: 1)

        style.edgeColor = Color(.sRGB, red: 0.45, green: 0.35, blue: 0.25, opacity: 0.85)
        style.activeEdgeColor = Color(.sRGB, red: 0.15, green: 0.40, blue: 0.68, opacity: 1)
        style.edgeWidth = 2.0
        style.activeEdgeWidth = 3.0
        style.nodeLabelWeight = .semibold
        style.initialDotColor = Color(.sRGB, red: 0.42, green: 0.30, blue: 0.18, opacity: 1)
        return style
    }
}

// MARK: - Environment support

public struct GraphStyleKey: EnvironmentKey {
    public static let defaultValue: GraphStyle = .default
}

public extension EnvironmentValues {
    var graphStyle: GraphStyle {
        get { self[GraphStyleKey.self] }
        set { self[GraphStyleKey.self] = newValue }
    }
}

public extension View {
    /// Injects a `GraphStyle` into the environment for the whole graph view hierarchy.
    /// This is the recommended way to theme/customize the visualizer.
    func graphStyle(_ style: GraphStyle) -> some View {
        environment(\.graphStyle, style)
    }
}
