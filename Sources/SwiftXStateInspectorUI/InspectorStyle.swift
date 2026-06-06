#if SWIFTXSTATE_INSPECTOR_UI
import SwiftUI

/// "CSS for the inspector" — colors, fonts, and metrics for the actor list, JSON tree,
/// event feed, and sequence diagram. Inject with `.inspectorStyle(_:)`; presets `.dark`
/// and `.light`. Mirrors the `GraphStyle` pattern used by the graph module.
public struct InspectorStyle: Sendable {
    // MARK: Surfaces
    public var background: Color
    public var panelBackground: Color
    public var rowSelectedBackground: Color
    public var divider: Color
    public var chrome: Color

    // MARK: Text / JSON syntax colors
    public var primaryText: Color
    public var secondaryText: Color
    public var monoFontSize: CGFloat = 12
    public var keyColor: Color
    public var stringColor: Color
    public var numberColor: Color
    public var boolColor: Color
    public var nullColor: Color
    public var punctuationColor: Color
    public var summaryColor: Color

    // MARK: Metrics (touch-first: rows are full-width tap targets)
    public var rowMinHeight: CGFloat = 30
    public var indentWidth: CGFloat = 14
    public var disclosureSize: CGFloat = 11

    // MARK: State pill
    public var pillBackground: Color
    public var pillText: Color

    // MARK: Accents / event kinds
    public var accent: Color
    public var actorKindColor: Color
    public var eventKindColor: Color
    public var snapshotKindColor: Color
    public var statusActive: Color
    public var statusDone: Color
    public var statusError: Color

    public init(
        background: Color, panelBackground: Color, rowSelectedBackground: Color, divider: Color, chrome: Color,
        primaryText: Color, secondaryText: Color, keyColor: Color, stringColor: Color, numberColor: Color,
        boolColor: Color, nullColor: Color, punctuationColor: Color, summaryColor: Color,
        pillBackground: Color, pillText: Color, accent: Color,
        actorKindColor: Color, eventKindColor: Color, snapshotKindColor: Color,
        statusActive: Color, statusDone: Color, statusError: Color
    ) {
        self.background = background; self.panelBackground = panelBackground
        self.rowSelectedBackground = rowSelectedBackground; self.divider = divider; self.chrome = chrome
        self.primaryText = primaryText; self.secondaryText = secondaryText
        self.keyColor = keyColor; self.stringColor = stringColor; self.numberColor = numberColor
        self.boolColor = boolColor; self.nullColor = nullColor; self.punctuationColor = punctuationColor
        self.summaryColor = summaryColor; self.pillBackground = pillBackground; self.pillText = pillText
        self.accent = accent; self.actorKindColor = actorKindColor; self.eventKindColor = eventKindColor
        self.snapshotKindColor = snapshotKindColor
        self.statusActive = statusActive; self.statusDone = statusDone; self.statusError = statusError
    }

    public var monoFont: Font { .system(size: monoFontSize, design: .monospaced) }

    /// Dark theme, in the spirit of the Stately Inspector.
    public static let dark = InspectorStyle(
        background: Color(.sRGB, red: 0.09, green: 0.10, blue: 0.12, opacity: 1),
        panelBackground: Color(.sRGB, red: 0.13, green: 0.14, blue: 0.17, opacity: 1),
        rowSelectedBackground: Color(.sRGB, red: 0.20, green: 0.30, blue: 0.52, opacity: 0.55),
        divider: Color(white: 1, opacity: 0.08),
        chrome: Color(.sRGB, red: 0.11, green: 0.12, blue: 0.15, opacity: 1),
        primaryText: Color(white: 0.92),
        secondaryText: Color(white: 0.55),
        keyColor: Color(white: 0.88),
        stringColor: Color(.sRGB, red: 0.95, green: 0.55, blue: 0.45, opacity: 1),
        numberColor: Color(.sRGB, red: 0.55, green: 0.80, blue: 0.98, opacity: 1),
        boolColor: Color(.sRGB, red: 0.78, green: 0.62, blue: 0.98, opacity: 1),
        nullColor: Color(white: 0.50),
        punctuationColor: Color(white: 0.55),
        summaryColor: Color(white: 0.55),
        pillBackground: Color(.sRGB, red: 0.16, green: 0.42, blue: 0.30, opacity: 0.55),
        pillText: Color(.sRGB, red: 0.70, green: 0.95, blue: 0.80, opacity: 1),
        accent: Color(.sRGB, red: 0.36, green: 0.62, blue: 0.99, opacity: 1),
        actorKindColor: Color(.sRGB, red: 0.55, green: 0.80, blue: 0.98, opacity: 1),
        eventKindColor: Color(.sRGB, red: 0.95, green: 0.72, blue: 0.40, opacity: 1),
        snapshotKindColor: Color(.sRGB, red: 0.55, green: 0.85, blue: 0.60, opacity: 1),
        statusActive: Color(.sRGB, red: 0.40, green: 0.80, blue: 0.55, opacity: 1),
        statusDone: Color(.sRGB, red: 0.55, green: 0.80, blue: 0.98, opacity: 1),
        statusError: Color(.sRGB, red: 0.95, green: 0.45, blue: 0.45, opacity: 1)
    )

    /// Light theme.
    public static let light = InspectorStyle(
        background: Color(white: 0.98),
        panelBackground: .white,
        rowSelectedBackground: Color(.sRGB, red: 0.82, green: 0.88, blue: 0.99, opacity: 1),
        divider: Color(white: 0, opacity: 0.10),
        chrome: Color(white: 0.95),
        primaryText: Color(white: 0.12),
        secondaryText: Color(white: 0.45),
        keyColor: Color(white: 0.20),
        stringColor: Color(.sRGB, red: 0.72, green: 0.22, blue: 0.18, opacity: 1),
        numberColor: Color(.sRGB, red: 0.10, green: 0.36, blue: 0.78, opacity: 1),
        boolColor: Color(.sRGB, red: 0.45, green: 0.22, blue: 0.78, opacity: 1),
        nullColor: Color(white: 0.55),
        punctuationColor: Color(white: 0.45),
        summaryColor: Color(white: 0.50),
        pillBackground: Color(.sRGB, red: 0.80, green: 0.92, blue: 0.82, opacity: 1),
        pillText: Color(.sRGB, red: 0.10, green: 0.40, blue: 0.22, opacity: 1),
        accent: Color(.sRGB, red: 0.13, green: 0.45, blue: 0.92, opacity: 1),
        actorKindColor: Color(.sRGB, red: 0.13, green: 0.45, blue: 0.78, opacity: 1),
        eventKindColor: Color(.sRGB, red: 0.78, green: 0.50, blue: 0.10, opacity: 1),
        snapshotKindColor: Color(.sRGB, red: 0.20, green: 0.55, blue: 0.30, opacity: 1),
        statusActive: Color(.sRGB, red: 0.20, green: 0.60, blue: 0.35, opacity: 1),
        statusDone: Color(.sRGB, red: 0.13, green: 0.45, blue: 0.78, opacity: 1),
        statusError: Color(.sRGB, red: 0.80, green: 0.25, blue: 0.25, opacity: 1)
    )

    public static let `default` = InspectorStyle.dark
}

// MARK: - Environment

public struct InspectorStyleKey: EnvironmentKey {
    public static let defaultValue: InspectorStyle = .dark
}

public extension EnvironmentValues {
    var inspectorStyle: InspectorStyle {
        get { self[InspectorStyleKey.self] }
        set { self[InspectorStyleKey.self] = newValue }
    }
}

public extension View {
    /// Injects an `InspectorStyle` for the inspector view hierarchy.
    func inspectorStyle(_ style: InspectorStyle) -> some View {
        environment(\.inspectorStyle, style)
    }
}
#endif
