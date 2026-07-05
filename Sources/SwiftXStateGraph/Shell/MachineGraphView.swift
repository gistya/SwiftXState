#if SWIFTXSTATE_GRAPH_UI
import SwiftUI
import SwiftXState

#if canImport(AppKit)
import AppKit
#endif

/// The root SwiftUI view for rendering a live state-machine graph from a typed actor.
///
/// ```swift
/// MachineGraphView(actor: myActor, machine: MyMachine.machine)
///     .graphStyle(.dark)
///     .frame(minWidth: 800, minHeight: 600)
/// ```
///
/// Constructed with an `actor`, it subscribes to live snapshots and highlights the active
/// configuration in real time. The snapshot-only initializer renders a static configuration.
@MainActor
public struct MachineGraphView<Context: Sendable>: View {
    @State private var render: GraphRenderModel
    @State private var subscription = SubscriptionBox()
    private let actor: Actor<MachineLogic<Context>>?

    /// Live graph driven by an actor.
    public init(actor: Actor<MachineLogic<Context>>, machine: ResolvedMachine<Context>) async {
        self.actor = actor
        let model = GraphModelBuilder.build(from: machine)
        let render = GraphRenderModel(model: model)
        let snapshot = await actor.snapshot
        render.setActive(stateValue: snapshot.value)
        _render = State(initialValue: render)
    }

    /// Static / replay graph from a snapshot (no live subscription).
    public init(machine: ResolvedMachine<Context>, snapshot: MachineSnapshot<Context>) {
        self.actor = nil
        let model = GraphModelBuilder.build(from: machine)
        let render = GraphRenderModel(model: model)
        render.setActive(stateValue: snapshot.value)
        _render = State(initialValue: render)
    }

    public var body: some View {
        GraphRenderView(render: render)
            .onAppear {
                guard let actor, subscription.handle == nil else { return }
                Task { @MainActor in
                    render.setActive(stateValue: await actor.snapshot.value)
                    subscription.handle = await actor.subscribe { [weak render] snapshot in
                        Task { @MainActor in render?.setActive(stateValue: snapshot.value) }
                    }
                }
            }
            .onDisappear { subscription.cancel() }
    }
}

// MARK: - Subscription lifetime holder

@MainActor
final class SubscriptionBox {
    var handle: Subscription?
    func cancel() { handle?.cancel(); handle = nil }
}

// MARK: - macOS scroll-wheel bridge

#if canImport(AppKit)
/// Installs a local scroll-wheel monitor so mouse-wheel zoom works on macOS.
@MainActor
final class ScrollWheelBridge {
    private var monitor: Any?

    /// `handler` receives `(deltaX, deltaY, isPrecise, location)` — `isPrecise` is true for
    /// trackpad gestures (→ pan) and false for mouse wheels (→ zoom). Location is in the key
    /// window's content view (top-left origin). Returns `true` if it consumed the event.
    func start(_ handler: @escaping (CGFloat, CGFloat, Bool, CGPoint) -> Bool) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard let contentView = event.window?.contentView else { return event }
            let point = contentView.convert(event.locationInWindow, from: nil)
            let flipped = CGPoint(x: point.x, y: contentView.bounds.height - point.y)
            if (event.scrollingDeltaX != 0 || event.scrollingDeltaY != 0),
               handler(event.scrollingDeltaX, event.scrollingDeltaY, event.hasPreciseScrollingDeltas, flipped) {
                return nil
            }
            return event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
#endif
#endif
