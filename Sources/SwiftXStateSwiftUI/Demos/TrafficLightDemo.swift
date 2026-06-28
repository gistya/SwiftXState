#if SWIFTXSTATE_APPLE_UI
import SwiftUI
import SwiftXState

// A self-contained demo of mixing the SwiftXState (Plan D) and SwiftUI DSLs: a typed statechart whose
// active state drives the UI, with typed events sent from buttons. This is the "the chart is the
// screen graph" pattern end to end.

public enum DemoLight: String, StateIdentifying {
    case red, green, yellow
    public static var _blank: DemoLight { .red }
}

public enum DemoLightEvent: String, EventIdentifying {
    case go, caution, stop
    public static var _blank: DemoLightEvent { .stop }
}

public struct DemoTrafficContext: Sendable, Equatable {
    public var cycles: Int = 0
    public func incrementingCycles() -> Self { .init(cycles: cycles + 1) }
}

/// The chart: red → green → yellow → red, counting completed cycles on the yellow→red action.
public struct DemoTrafficLight: StateMachine {
    public typealias Context = DemoTrafficContext
    public typealias StateID = DemoLight
    public typealias EventID = DemoLightEvent

    public init() {}
    public var context: DemoTrafficContext { .init() }

    public var machine: some XStateMachine {
        XState(.red)    { XTransition(on: .go,      to: .green)  }.initial()
        XState(.green)  { XTransition(on: .caution, to: .yellow) }
        XState(.yellow) { XTransition(on: .stop, to: .red).action { $0.incrementingCycles() } }
    }
}

/// The view: `@Machine` owns the chart, `MachineView` renders the active state, and each state's UI is
/// co-located in one exhaustive `switch` (a new state can't compile without a screen).
public struct TrafficLightDemo: View {
    @Machine(DemoTrafficLight()) private var light

    public init() {}

    public var body: some View {
        VStack(spacing: 24) {
            MachineView(light) { state, light in
                switch state {
                case .red:
                    LightFace(color: .red, label: "STOP", action: "Go") { light.send(.go) }
                case .green:
                    LightFace(color: .green, label: "GO", action: "Caution") { light.send(.caution) }
                case .yellow:
                    LightFace(color: .yellow, label: "SLOW", action: "Stop") { light.send(.stop) }
                }
            }

            Text("Completed cycles: \(light.context.cycles)")
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

private struct LightFace: View {
    let color: Color
    let label: String
    let action: String
    let onAction: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Circle()
                .fill(color.gradient)
                .frame(width: 120, height: 120)
                .overlay(Text(label).font(.headline.bold()).foregroundStyle(.white))
                .shadow(color: color.opacity(0.6), radius: 16)
            Button(action, action: onAction)
                .buttonStyle(.borderedProminent)
                .tint(color)
        }
        .transition(.scale.combined(with: .opacity))
    }
}

#Preview("Traffic Light") {
    TrafficLightDemo()
}
#endif
