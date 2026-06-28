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
            stateConfigs[stateID.name] = StateNodeConfig(
                on: Self.transitionInputs(node.transitions),
                entry: node.entry.map { [Self.assignAction($0)] },
                exit: node.exit.map { [Self.assignAction($0)] }
            )
        }
        return createMachine(MachineConfig<Context>(
            id: id,
            initial: initialState?.name,
            context: context,
            states: stateConfigs
        ))
    }

    /// Project an engine `StateValue` back into a typed `Configuration` by matching id `name`s.
    /// (Flat/atomic today; nested projection arrives with the hierarchy phase.)
    func configuration(from value: StateValue) -> Configuration<StateID>? {
        let byName = Dictionary(order.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
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
