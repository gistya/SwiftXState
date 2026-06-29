#if SWIFTXSTATE_APPLE_UI
import SwiftUI
import SwiftXState

// MARK: - Two-way binding: read context (lens), write events (prism)

public extension MachineStore {
    /// A SwiftUI `Binding` whose **read** projects the context through a key path (the lens) and whose
    /// **write** sends a typed event (the prism) — so a control stays a pure statechart: every edit is
    /// an auditable event, never a direct mutation.
    ///
    /// ```swift
    /// TextField("Name", text: store.bind(\.name, send: FormEvent.setName))
    /// Slider(value: store.bind(\.volume, send: AudioEvent.setVolume), in: 0...1)
    /// ```
    ///
    /// The `send` closure is usually just a payload-carrying event case — `FormEvent.setName` is
    /// `(String) -> FormEvent` — which is exactly the prism half of the lens/prism duality.
    func bind<Value>(
        _ keyPath: KeyPath<M.Context, Value>,
        send event: @escaping @Sendable (Value) -> M.EventID
    ) -> Binding<Value> {
        Binding(
            get: { self.context[keyPath: keyPath] },
            set: { self.send(event($0)) }
        )
    }

    /// A `Binding<Bool>` that is `true` while the machine is in `state`, and sends `event` when toggled
    /// on (and `off`, if given, when toggled off) — for `Toggle`s driven by state rather than a flag.
    ///
    /// ```swift
    /// Toggle("Playing", isOn: store.bind(.playing, on: .play, off: .pause))
    /// ```
    func bind(
        _ state: M.StateID,
        on: M.EventID,
        off: M.EventID? = nil
    ) -> Binding<Bool> {
        Binding(
            get: { self.matches(state) },
            set: { isOn in
                if isOn { self.send(on) }
                else if let off { self.send(off) }
            }
        )
    }
}
#endif
