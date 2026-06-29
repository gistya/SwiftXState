/// Creates a state machine from a configuration — the Swift equivalent of XState's
/// `createMachine({ … })`. Optionally supply the `implementations` (named actions/guards/actors)
/// referenced by the config; you can also add them later with `provide(_:)` or up front via `setup`.
///
/// ```swift
/// let toggle = createMachine(MachineConfig(
///     id: "toggle", initial: "off", context: EmptyContext(),
///     states: [
///         "off": StateNodeConfig(on: ["TOGGLE": .to("on")]),
///         "on":  StateNodeConfig(on: ["TOGGLE": .to("off")]),
///     ]))
/// ```
public func createMachine<Context: Sendable>(
    _ config: MachineConfig<Context>,
    implementations: MachineImplementations<Context> = MachineImplementations<Context>()
) -> ResolvedMachine<Context> {
    ResolvedMachine(config: config, implementations: implementations)
}
