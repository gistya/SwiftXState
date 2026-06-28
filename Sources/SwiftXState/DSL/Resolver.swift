import Foundation

// MARK: - Schema → engine resolution (the build-time "destringing" boundary)

public extension MachineSchema {
    /// Lower this typed schema to the engine's `ResolvedMachine`. This is the build-time resolution
    /// that turns typed ids into string node keys/targets (via `name`) and typed handlers into the
    /// engine's `assign`/`guard` refs. The result runs on the existing `Actor` / `MachineLogic` /
    /// macrostep unchanged — the typed DSL is, in the end, an alternate constructor for a machine.
    func resolve(id: String? = nil, context: Context? = nil) -> ResolvedMachine<Context> {
        var stateConfigs: [String: StateNodeConfig<Context>] = [:]
        for stateID in order {
            guard let node = states[stateID] else { continue }
            stateConfigs[stateID.name] = Self.nodeConfig(node)
        }
        return createMachine(MachineConfig<Context>(
            id: id,
            initial: initialState?.name,
            context: context,
            states: stateConfigs
        ))
    }

    /// Recursively lower a typed `StateNode` (and its children) to an engine `StateNodeConfig`.
    /// Compound is inferred by the engine from a non-nil `states`; parallel is set explicitly.
    private static func nodeConfig(_ node: StateNode) -> StateNodeConfig<Context> {
        var childConfigs: [String: StateNodeConfig<Context>] = [:]
        for child in node.children {
            childConfigs[child.id.name] = nodeConfig(child)
        }
        let explicitType: StateNodeType? = node.isFinal ? .final : (node.isParallel ? .parallel : nil)
        return StateNodeConfig(
            initial: node.initialChild?.name,
            type: explicitType,
            states: childConfigs.isEmpty ? nil : childConfigs,
            on: transitionInputs(node.transitions),
            onDone: guardedInput(node.onDone),
            always: node.always.isEmpty ? nil : node.always.map { guardedConfig($0) },
            after: afterInputs(node.after),
            entry: node.entry.map { [assignAction($0)] },
            exit: node.exit.map { [assignAction($0)] }
        )
    }

    /// Lower an eventless guarded transition (`Always` / `After` / `OnDone`) to a `TransitionConfig`.
    private static func guardedConfig(_ t: GuardedTransition) -> TransitionConfig<Context> {
        TransitionConfig(
            target: t.target.name,
            guard: t.`guard`.map { g in GuardRef.inline { args in g(args.context) } },
            actions: t.action.map { [handlerAction($0)] }
        )
    }

    /// Bundle a guarded-transition list into a `TransitionInput` (single / multiple-candidate).
    private static func guardedInput(_ list: [GuardedTransition]) -> TransitionInput<Context>? {
        guard !list.isEmpty else { return nil }
        let configs = list.map { guardedConfig($0) }
        return configs.count == 1 ? .single(configs[0]) : .multiple(configs)
    }

    /// Group delayed transitions by delay-ms, producing the engine's `after` map (keyed by ms string).
    private static func afterInputs(_ list: [AfterEntry]) -> [String: TransitionInput<Context>]? {
        guard !list.isEmpty else { return nil }
        var grouped: [String: [TransitionConfig<Context>]] = [:]
        var keyOrder: [String] = []
        for entry in list {
            let key = String(entry.delayMS)
            if grouped[key] == nil { keyOrder.append(key) }
            grouped[key, default: []].append(guardedConfig(entry.transition))
        }
        var out: [String: TransitionInput<Context>] = [:]
        for key in keyOrder {
            let configs = grouped[key]!
            out[key] = configs.count == 1 ? .single(configs[0]) : .multiple(configs)
        }
        return out
    }

    /// Project an engine `StateValue` back into a typed `Configuration` by matching id `name`s — at
    /// every depth, so a nested compound (`.compound([parent: .atomic(child)])`) or parallel
    /// (`.compound` with several keys) value resolves to a typed `Configuration.nested` tree.
    func configuration(from value: StateValue) -> Configuration<StateID>? {
        let byName = Self.idsByName(states)
        func project(_ v: StateValue) -> Configuration<StateID>? {
            switch v {
            case let .atomic(name):
                guard let id = byName[name] else { return nil }
                return .atomic(id)
            case let .compound(dict):
                var nested: [StateID: Configuration<StateID>] = [:]
                for (name, sub) in dict {
                    guard let id = byName[name], let child = project(sub) else { return nil }
                    nested[id] = child
                }
                return .nested(nested)
            }
        }
        return project(value)
    }

    /// Index every state id in the tree by its lowered `name` — the lookup the `StateValue → typed
    /// Configuration` projection needs at all depths (engine values are dotted/nested by name).
    private static func idsByName(_ nodes: [StateID: StateNode]) -> [String: StateID] {
        var map: [String: StateID] = [:]
        func walk(_ node: StateNode) {
            map[node.id.name] = node.id
            for child in node.children { walk(child) }
        }
        for node in nodes.values { walk(node) }
        return map
    }

    private static func transitionInputs(_ transitions: [TransitionNode]) -> [String: TransitionInput<Context>]? {
        guard !transitions.isEmpty else { return nil }
        var grouped: [String: [TransitionConfig<Context>]] = [:]
        var keyOrder: [String] = []
        for t in transitions {
            let key = t.event.name
            if grouped[key] == nil { keyOrder.append(key) }
            grouped[key, default: []].append(transitionConfig(t))
        }
        var on: [String: TransitionInput<Context>] = [:]
        for key in keyOrder {
            let configs = grouped[key]!
            on[key] = configs.count == 1 ? .single(configs[0]) : .multiple(configs)
        }
        return on
    }

    private static func transitionConfig(_ t: TransitionNode) -> TransitionConfig<Context> {
        TransitionConfig(
            target: t.target.name,
            guard: t.`guard`.map { g in GuardRef.inline { args in g(args.context) } },
            actions: t.action.map { [handlerAction($0)] }
        )
    }

    /// Lower a transition `Handler` (`(args, enq) -> context`) to an engine `enqueueActions`: run the
    /// handler at transition time, apply its context patch first, then the collected effects (so a
    /// raised event queues after the patch — run-to-completion safe).
    private static func handlerAction(_ handler: @escaping Handler) -> ActionRef<Context> {
        enqueueActions { builder in
            let enq = Enqueue<Context, EventID>(context: builder.context, event: builder.event)
            let args = XTransitionArgs<Context, EventID>(context: builder.context, event: builder.event)
            let next = handler(args, enq)
            builder.enqueue(assign { (ctx: inout Context, _: ActionArgs<Context>) in ctx = next })
            for effect in enq.collected { builder.enqueue(effect) }
        }
    }

    /// Lower a pure entry/exit transform (`(consuming Context) -> Context`) to an engine `assign`.
    private static func assignAction(_ transform: @escaping Action) -> ActionRef<Context> {
        assign { (ctx: inout Context, _: ActionArgs<Context>) in ctx = transform(ctx) }
    }
}

public extension StateMachine {
    /// Fold + resolve in one step — the running machine for the engine, with the declared `context`
    /// baked into the `MachineConfig` so `start()` needs no argument.
    func resolvedMachine(id: String? = nil) -> ResolvedMachine<Context> {
        buildSchema().resolve(id: id, context: context)
    }
}

public extension EventIdentifying {
    /// The engine event this id sends — `actor.send(LightEvent.go.event)`.
    var event: Event { Event(name) }
}
