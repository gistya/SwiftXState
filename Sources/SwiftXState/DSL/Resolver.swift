import Foundation

// MARK: - Schema → engine resolution (the build-time "destringing" boundary)

public extension MachineSchema {
    /// Lower this typed schema to the engine's `ResolvedMachine`. This is the build-time resolution
    /// that turns typed ids into string node keys/targets (via `name`) and typed handlers into the
    /// engine's `assign`/`guard` refs. The result runs on the existing `Actor` / `MachineLogic` /
    /// macrostep unchanged — the typed DSL is, in the end, an alternate constructor for a machine.
    func resolve(id: String? = nil, context: Context? = nil) -> ResolvedMachine<Context> {
        let paths = pathsByName()
        var stateConfigs: [String: StateNodeConfig<Context>] = [:]
        for stateID in order {
            guard let node = states[stateID] else { continue }
            stateConfigs[stateID.name] = Self.nodeConfig(node, paths: paths)
        }
        return createMachine(MachineConfig<Context>(
            id: id,
            initial: initialState?.name,
            context: context,
            states: stateConfigs
        ))
    }

    /// Map each state-id `name` to its full dotted path(s) from the root (no machine-id prefix). A name
    /// with exactly one path is **unique** and can be targeted absolutely; a shared name (e.g. the
    /// four castling sides' `available`) keeps several paths and must resolve relatively.
    private func pathsByName() -> [String: [String]] {
        var map: [String: [String]] = [:]
        func walk(_ node: StateNode, prefix: String) {
            let path = prefix.isEmpty ? node.id.name : "\(prefix).\(node.id.name)"
            map[node.id.name, default: []].append(path)
            for child in node.children { walk(child, prefix: path) }
        }
        for stateID in order { if let node = states[stateID] { walk(node, prefix: "") } }
        return map
    }

    /// Lower a transition target id to an engine target string: a **unique** name becomes an absolute
    /// `#full.path` (so deep cross-branch jumps like `replaying → game.active.turn.idle` resolve via
    /// the engine's id map); a **shared** name stays bare for local sibling resolution.
    private static func targetString(_ id: StateID, paths: [String: [String]]) -> String {
        if let p = paths[id.name], p.count == 1 { return "#\(p[0])" }
        return id.name
    }

    /// Recursively lower a typed `StateNode` (and its children) to an engine `StateNodeConfig`.
    /// Compound is inferred by the engine from a non-nil `states`; parallel is set explicitly.
    private static func nodeConfig(_ node: StateNode, paths: [String: [String]]) -> StateNodeConfig<Context> {
        var childConfigs: [String: StateNodeConfig<Context>] = [:]
        for child in node.children {
            childConfigs[child.id.name] = nodeConfig(child, paths: paths)
        }
        let explicitType: StateNodeType? = node.isFinal ? .final : (node.isParallel ? .parallel : nil)
        return StateNodeConfig(
            initial: node.initialChild?.name,
            type: explicitType,
            states: childConfigs.isEmpty ? nil : childConfigs,
            on: transitionInputs(node.transitions, paths: paths),
            onDone: guardedInput(node.onDone, paths: paths),
            always: node.always.isEmpty ? nil : node.always.map { guardedConfig($0, paths: paths) },
            after: afterInputs(node.after, paths: paths),
            invoke: node.invokes.isEmpty ? nil : node.invokes.map { invokeConfig($0, paths: paths) },
            entry: node.entry.map { [handlerAction($0)] },
            exit: node.exit.map { [handlerAction($0)] },
            output: node.output.map { make in { @Sendable (args: ActionArgs<Context>) in make(args.context) } }
        )
    }

    /// Lower a typed `InvokeNode` to the engine's `InvokeConfig` (wrapping the context-only `input`
    /// closure into the engine's `ActionArgs` form; `onDone`/`onError` reuse the guarded lowering).
    private static func invokeConfig(_ n: InvokeNode, paths: [String: [String]]) -> InvokeConfig<Context> {
        InvokeConfig(
            id: n.id,
            src: n.src,
            input: n.input.map { make in { @Sendable (args: ActionArgs<Context>) in make(args.context) } },
            onDone: n.onDone.flatMap { guardedInput([$0], paths: paths) },
            onError: n.onError.flatMap { guardedInput([$0], paths: paths) },
            onSnapshot: n.onSnapshot.flatMap { guardedInput([$0], paths: paths) }
        )
    }

    /// Lower an eventless guarded transition (`Always` / `After` / `OnDone`) to a `TransitionConfig`.
    /// Output/error-reading actions pull from the triggering `DoneActorEvent` / `DoneStateEvent` /
    /// `ErrorActorEvent` (XState v6's `onDone: ({ output })` / `onError`).
    private static func guardedConfig(_ t: GuardedTransition, paths: [String: [String]]) -> TransitionConfig<Context> {
        var actions: [ActionRef<Context>] = []
        if let action = t.action {
            actions.append(handlerAction(action))
        }
        if let outputAction = t.outputAction {
            actions.append(assign { (ctx: inout Context, args: ActionArgs<Context>) in
                let output: SendableValue?
                switch args.event {
                case let done as DoneActorEvent: output = done.output
                case let done as DoneStateEvent: output = done.output
                default: output = nil
                }
                ctx = outputAction(output, ctx)
            })
        }
        if let errorAction = t.errorAction {
            actions.append(assign { (ctx: inout Context, args: ActionArgs<Context>) in
                if let error = (args.event as? ErrorActorEvent)?.error {
                    ctx = errorAction(error, ctx)
                }
            })
        }
        return TransitionConfig(
            target: targetString(t.target, paths: paths),
            guard: t.`guard`.map { g in GuardRef.inline { args in g(args.context) } },
            actions: actions.isEmpty ? nil : actions
        )
    }

    /// Bundle a guarded-transition list into a `TransitionInput` (single / multiple-candidate).
    private static func guardedInput(_ list: [GuardedTransition], paths: [String: [String]]) -> TransitionInput<Context>? {
        guard !list.isEmpty else { return nil }
        let configs = list.map { guardedConfig($0, paths: paths) }
        return configs.count == 1 ? .single(configs[0]) : .multiple(configs)
    }

    /// Group delayed transitions by delay-ms, producing the engine's `after` map (keyed by ms string).
    private static func afterInputs(_ list: [AfterEntry], paths: [String: [String]]) -> [String: TransitionInput<Context>]? {
        guard !list.isEmpty else { return nil }
        var grouped: [String: [TransitionConfig<Context>]] = [:]
        var keyOrder: [String] = []
        for entry in list {
            let key = String(entry.delayMS)
            if grouped[key] == nil { keyOrder.append(key) }
            grouped[key, default: []].append(guardedConfig(entry.transition, paths: paths))
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

    private static func transitionInputs(_ transitions: [TransitionNode], paths: [String: [String]]) -> [String: TransitionInput<Context>]? {
        guard !transitions.isEmpty else { return nil }
        var grouped: [String: [TransitionConfig<Context>]] = [:]
        var keyOrder: [String] = []
        for t in transitions {
            // A case-matched transition (no `event`) routes under the wildcard, gated by `caseMatch`.
            let key = t.event?.name ?? wildcardEventDescriptor
            if grouped[key] == nil { keyOrder.append(key) }
            grouped[key, default: []].append(transitionConfig(t, paths: paths))
        }
        var on: [String: TransitionInput<Context>] = [:]
        for key in keyOrder {
            let configs = grouped[key]!
            on[key] = configs.count == 1 ? .single(configs[0]) : .multiple(configs)
        }
        return on
    }

    private static func transitionConfig(_ t: TransitionNode, paths: [String: [String]]) -> TransitionConfig<Context> {
        TransitionConfig(
            target: targetString(t.target, paths: paths),
            guard: combinedGuard(caseMatch: t.caseMatch, contextGuard: t.`guard`, eventGuard: t.eventGuard),
            actions: t.action.map { [handlerAction($0)] }
        )
    }

    /// AND-combine the optional case matcher (event-aware), the context-only `guard`, and the
    /// event-aware `eventGuard` into one engine `GuardRef`: the transition is taken only when the
    /// incoming event is the right case *and* every guard passes.
    private static func combinedGuard(
        caseMatch: (@Sendable (EventID) -> Bool)?,
        contextGuard: Guard?,
        eventGuard: (@Sendable (Context, EventID?) -> Bool)?
    ) -> GuardRef<Context>? {
        guard caseMatch != nil || contextGuard != nil || eventGuard != nil else { return nil }
        return GuardRef.inline { args in
            let typedID = (args.event as? TypedEvent<EventID>)?.id
            if let caseMatch {
                guard let typedID, caseMatch(typedID) else { return false }
            }
            if let contextGuard, !contextGuard(args.context) { return false }
            if let eventGuard, !eventGuard(args.context, typedID) { return false }
            return true
        }
    }

    /// Lower a transition `Handler` (`(args, enq) -> context`) to an engine `enqueueActions`: run the
    /// handler at transition time, apply its context patch first, then the collected effects (so a
    /// raised event queues after the patch — run-to-completion safe).
    private static func handlerAction(_ handler: @escaping Handler) -> ActionRef<Context> {
        enqueueActions { builder in
            // Recover the typed id if this transition was triggered by a directly-sent typed event.
            let triggeringID = (builder.event as? TypedEvent<EventID>)?.id
            let enq = Enqueue<Context, EventID>(context: builder.context, event: triggeringID)
            let args = XTransitionArgs<Context, EventID>(context: builder.context, event: triggeringID)
            let next = handler(args, enq)
            builder.enqueue(assign { (ctx: inout Context, _: ActionArgs<Context>) in ctx = next })
            for effect in enq.collected { builder.enqueue(effect) }
        }
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
    /// The engine event this id sends — `actor.send(LightEvent.go.event)`. A `TypedEvent` so a
    /// payload-carrying case survives the send and is readable, typed, in the handler.
    var event: TypedEvent<Self> { TypedEvent(self) }
}
