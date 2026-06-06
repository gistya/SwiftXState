#if SWIFTXSTATE_INSPECTOR_UI
import SwiftUI
import SwiftXState

/// The green state pill shown for an actor — the compact JSON of its current value,
/// e.g. `{"game":{"active":{"turn":"idle"}}}` or `"board"`.
struct StatePillView: View {
    let stateValue: StateValue
    @Environment(\.inspectorStyle) private var style

    private var text: String {
        (try? JSONValue.encode(stateValue.toJSONValue())) ?? stateValue.description
    }

    var body: some View {
        Text(text)
            .font(.system(size: style.monoFontSize - 1, design: .monospaced))
            .foregroundStyle(style.pillText)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(style.pillBackground, in: RoundedRectangle(cornerRadius: 6))
    }
}

/// A small status indicator (active / done / error / stopped).
struct StatusDot: View {
    let status: SnapshotStatus
    @Environment(\.inspectorStyle) private var style

    private var color: Color {
        switch status {
        case .active: return style.statusActive
        case .done: return style.statusDone
        case .error: return style.statusError
        case .stopped: return style.secondaryText
        }
    }

    var body: some View {
        Circle().fill(color).frame(width: 7, height: 7)
    }
}

/// A colored kind badge for the event feed (`ACTOR` / `EVENT` / `SNAPSHOT` / …).
struct EventKindBadge: View {
    let kind: InspectionEventKind
    @Environment(\.inspectorStyle) private var style

    private var color: Color {
        switch kind {
        case .actor: return style.actorKindColor
        case .event: return style.eventKindColor
        case .snapshot, .transition: return style.snapshotKindColor
        case .microstep, .action: return style.secondaryText
        }
    }

    private var label: String {
        switch kind {
        case .actor: return "ACTOR"
        case .event: return "EVENT"
        case .snapshot: return "SNAPSHOT"
        case .transition: return "TRANSITION"
        case .microstep: return "MICROSTEP"
        case .action: return "ACTION"
        }
    }

    var body: some View {
        Text(label)
            .font(.system(size: 9, weight: .bold))
            .tracking(0.5)
            .foregroundStyle(color)
    }
}

enum InspectorTime {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    static func string(_ timestamp: TimeInterval) -> String {
        formatter.string(from: Date(timeIntervalSince1970: timestamp))
    }
}

extension SnapshotStatus {
    var displayName: String {
        switch self {
        case .active: return "ACTIVE"
        case .done: return "DONE"
        case .error: return "ERROR"
        case .stopped: return "STOPPED"
        }
    }
}
#endif
