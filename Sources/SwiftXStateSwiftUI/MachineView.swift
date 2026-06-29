#if SWIFTXSTATE_APPLE_UI
import SwiftUI
import SwiftXState

// MARK: - @Machine — own a typed machine in a view

/// Owns a typed machine in a SwiftUI view, the way `@StateObject` owns an object — the Plan-D-typed
/// counterpart of `@MachineState`. `wrappedValue` is the live `MachineStore<M>`, so the body reads
/// `light.configuration` / `light.matches(.green)` / `light.context` and drives it with
/// `light.send(.go)`, all typed.
///
/// ```swift
/// struct LightView: View {
///     @Machine(TrafficLight()) var light
///     var body: some View {
///         MachineView(light) { state, light in … }
///     }
/// }
/// ```
@propertyWrapper
@MainActor
public struct Machine<M: StateMachine>: DynamicProperty {
    @State private var store: MachineStore<M>

    public init(_ machine: M) {
        _store = State(initialValue: MachineStore(machine))
    }

    public var wrappedValue: MachineStore<M> { store }

    /// `$light` — the same store, for passing to `MachineView` / binding helpers.
    public var projectedValue: MachineStore<M> { store }
}

// MARK: - MachineView — the chart IS the screen graph

/// Renders the view for the machine's **active** state(s): the live `Configuration` selects which
/// content shows. A flat/compound machine shows its one active leaf; a **parallel** machine shows all
/// its active leaves at once (stacked). State changes animate.
///
/// The content closure receives the active leaf `StateID` (switch on it — the compiler makes the map
/// exhaustive) and the `MachineStore` (to `send` typed events). Co-locate the chart and its UI:
///
/// ```swift
/// MachineView(TrafficLight()) { state, light in
///     switch state {
///     case .red:    RedLight()    { Button("Go")      { light.send(.go) } }
///     case .green:  GreenLight()  { Button("Caution") { light.send(.caution) } }
///     case .yellow: YellowLight() { Button("Stop")    { light.send(.stop) } }
///     }
/// }
/// ```
/// How `MachineView` arranges the **active leaves** — the AND/OR → container half of the statechart
/// correspondence. A compound (OR) state has one active leaf, so layout is moot; a **parallel** (AND)
/// state has several simultaneously-active leaves, and this chooses how to lay them out: overlapped
/// (`.zStack`, the default), side by side / stacked, or one tab per region.
public enum MachineLayout: Sendable {
    case zStack
    case vStack
    case hStack
    case tabs
}

public struct MachineView<M: StateMachine, Content: View>: View {
    @State private var store: MachineStore<M>
    private let layout: MachineLayout
    private let content: (M.StateID, MachineStore<M>) -> Content

    /// Own a fresh machine for the lifetime of this view.
    public init(
        _ machine: M,
        layout: MachineLayout = .zStack,
        @ViewBuilder content: @escaping (M.StateID, MachineStore<M>) -> Content
    ) {
        _store = State(initialValue: MachineStore(machine))
        self.layout = layout
        self.content = content
    }

    /// Render an existing store (e.g. from `@Machine` or a shared `MainStore`).
    public init(
        _ store: MachineStore<M>,
        layout: MachineLayout = .zStack,
        @ViewBuilder content: @escaping (M.StateID, MachineStore<M>) -> Content
    ) {
        _store = State(initialValue: store)
        self.layout = layout
        self.content = content
    }

    public var body: some View {
        Group {
            let leaves = activeLeaves(of: store.configuration)
            switch layout {
            case .zStack:
                ZStack { cells(leaves) }
            case .vStack:
                VStack { cells(leaves) }
            case .hStack:
                HStack { cells(leaves) }
            case .tabs:
                TabView {
                    ForEach(leaves, id: \.self) { leaf in
                        content(leaf, store).tabItem { Text(leaf.name) }
                    }
                }
            }
        }
        .animation(.default, value: store.configuration)
    }

    @ViewBuilder
    private func cells(_ leaves: [M.StateID]) -> some View {
        ForEach(leaves, id: \.self) { leaf in
            content(leaf, store)
        }
    }
}

/// The active leaf states to render, sorted by `name` for stable identity/ordering. One for an
/// atomic/compound configuration; several for parallel regions.
@inlinable
func activeLeaves<StateID: StateIdentifying>(
    of configuration: Configuration<StateID>?
) -> [StateID] {
    (configuration?.activeLeaves ?? []).sorted { $0.name < $1.name }
}

// MARK: - Typed event sugar

public extension Button where Label == Text {
    /// `Button("Go", send: .go, to: light)` — a button that sends a typed event.
    init<M: StateMachine>(_ title: String, send id: M.EventID, to store: MachineStore<M>) {
        self.init(title) { store.send(id) }
    }
}

public extension View {
    /// Send a typed event when this view appears — `.onAppear(send: .enter, to: store)`.
    func onAppear<M: StateMachine>(send id: M.EventID, to store: MachineStore<M>) -> some View {
        onAppear { store.send(id) }
    }
}
#endif
