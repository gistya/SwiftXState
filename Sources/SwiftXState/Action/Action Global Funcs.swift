import FridayTheCodable

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
    guard case var .object(fields) = InspectJSONEncoder.encode(context) else { return }

    for (key, assigner) in properties {
        fields[key] = InspectJSONEncoder.encode(assigner(args))
    }

    guard let updated = decodeContext(Context.self, from: .object(fields)) else { return }
    context = updated
}

private func decodeContext<Context: Sendable>(_ type: Context.Type, from value: JSONValue) -> Context? {
    guard let bytes = try? FridayJSONEncoder.swiftXState.encode(value) else { return nil }
    guard let decodable = type as? any Decodable.Type else { return nil }
    return (try? FridayJSONDecoder().decode(decodable, from: bytes)) as? Context
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

