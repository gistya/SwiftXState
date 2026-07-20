
func actionType<Context: Sendable>(for ref: ActionRef<Context>) -> String {
    switch ref {
    case let .named(name): return name
    case let .parameterized(name, _): return name
    case .assign: return "xstate.assign"
    case .inline: return "xstate.inline"
    case .spawn: return "xstate.spawnChild"
    case .stopChild: return "xstate.stopChild"
    case .forwardTo: return "xstate.forwardTo"
    case .sendTo: return "xstate.sendTo"
    case .sendToParent: return "xstate.sendToParent"
    case .raise: return "xstate.raise"
    case .cancel: return "xstate.cancel"
    case .enqueueActions: return "xstate.enqueueActions"
    case .log: return "xstate.log"
    case .emit: return "xstate.emit"
    case .listen: return "xstate.listen"
    case .subscribeToChild: return "xstate.subscribeTo"
    case .subscribeToAtom: return "xstate.subscribeToAtom"
    }
}

/// Executes only assign actions (used by pure transition functions).
func executeAssignOnly<Context: Sendable>(
    _ action: ExecutableAction<Context>,
    context: inout Context,
    args: ActionArgs<Context>,
    implementations: MachineImplementations<Context>
) {
    if case .assign = action.ref {
        executeAction(action, context: &context, args: args, implementations: implementations)
    }
}

/// Executes an action against the current context, returning the updated context.
public func executeAction<Context: Sendable>(
    _ action: ExecutableAction<Context>,
    context: inout Context,
    args: ActionArgs<Context>,
    implementations: MachineImplementations<Context>
) {
    switch action.ref {
    case let .named(name):
        implementations.actions[name]?(args, nil)
    case let .parameterized(name, params):
        implementations.actions[name]?(args, params)
    case let .assign(assignAction):
        executeAssign(assignAction, context: &context, args: args)
    case let .inline(fn):
        fn(args)
    case let .log(logAction):
        LogHandler.emit(
            label: logAction.label,
            value: resolveLogValue(logAction, args: args)
        )
    case .spawn, .stopChild, .forwardTo, .sendTo, .sendToParent, .raise, .cancel, .enqueueActions, .emit, .listen, .subscribeToChild, .subscribeToAtom:
        break
    }
}

private func executeAssign<Context: Sendable>(
    _ action: AssignAction<Context>,
    context: inout Context,
    args: ActionArgs<Context>
) {
    switch action {
    case let .properties(properties):
        applyPropertyAssigns(properties, context: &context, args: args)
    case let .function(fn):
        fn(&context, args)
    }
}

private func applyPropertyAssigns<Context: Sendable>(
    _ properties: [String: @Sendable (ActionArgs<Context>) -> SendableValue],
    context: inout Context,
    args: ActionArgs<Context>
) {
    guard case var .object(fields) = projectContext(context) else { return }

    for (key, assigner) in properties {
        fields[key] = InspectJSONEncoder.encode(assigner(args))
    }

    guard let updated = materializeContext(Context.self, from: .object(fields)) else {
        // Loud in development, ignored in release — previously this silently dropped the
        // assignment (and always did so under Embedded, where the old `Codable` path was stubbed out).
        assertionFailure("""
        assign(properties:) could not rebuild \(Context.self) from its projected JSON, so the \
        assignment was ignored. Conform \(Context.self) to `ContextPersistable` — with \
        `import SwiftXStateCodable` a `Codable` context gets both requirements for free.
        """)
        return
    }
    context = updated
}

/// Project a context to JSON, preferring the reflection-free ``ContextPersistable`` seam and falling
/// back to the `Mirror`-based encoder (which is unavailable under Embedded Swift).
private func projectContext<Context: Sendable>(_ context: Context) -> JSONValue {
    if let persistable = context as? any ContextPersistable,
       let json = try? persistable.persistedProjection() {
        return json
    }
    return InspectJSONEncoder.encode(context)
}

/// Rebuild a context from JSON via the ``ContextPersistable`` seam. No `Codable`, no JSON engine.
private func materializeContext<Context: Sendable>(_ type: Context.Type, from value: JSONValue) -> Context? {
    guard let persistableType = type as? any ContextPersistable.Type else { return nil }
    return (try? persistableType.materialized(from: value)) as? Context
}

/// Creates an assign action from a property map.
public func assign<Context: Sendable>(
    _ properties: [String: @Sendable (ActionArgs<Context>) -> SendableValue]
) -> ActionRef<Context> {
    .assign(.properties(properties))
}

/// Creates an assign action from a mutating function.
public func assign<Context: Sendable>(
    _ fn: @escaping @Sendable (inout Context, ActionArgs<Context>) -> Void
) -> ActionRef<Context> {
    .assign(.function(fn))
}

