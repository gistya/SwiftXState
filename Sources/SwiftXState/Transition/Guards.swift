import Foundation

/// Evaluates whether a guard passes for the given context and event.
public func evaluateGuard<Context: Sendable>(
    _ guardRef: GuardRef<Context>?,
    args: ActionArgs<Context>,
    implementations: MachineImplementations<Context>,
    stateValue: StateValue? = nil
) -> Bool {
    guard let guardRef else { return true }

    switch guardRef {
    case let .named(name):
        return implementations.guards[name]?(args, nil) ?? false
    case let .parameterized(name, params):
        return implementations.guards[name]?(args, params) ?? false
    case let .inline(predicate):
        return predicate(args)
    case let .composite(composite):
        return evaluateCompositeGuard(
            composite,
            args: args,
            implementations: implementations,
            stateValue: stateValue
        )
    }
}

private func evaluateCompositeGuard<Context: Sendable>(
    _ composite: CompositeGuard<Context>,
    args: ActionArgs<Context>,
    implementations: MachineImplementations<Context>,
    stateValue: StateValue?
) -> Bool {
    switch composite {
    case let .and(guards):
        return guards.allSatisfy {
            evaluateGuard($0, args: args, implementations: implementations, stateValue: stateValue)
        }
    case let .or(guards):
        return guards.contains {
            evaluateGuard($0, args: args, implementations: implementations, stateValue: stateValue)
        }
    case let .not(guardRef):
        return !evaluateGuard(guardRef, args: args, implementations: implementations, stateValue: stateValue)
    case let .stateIn(path):
        guard let stateValue else { return false }
        return stateIn(path, value: stateValue)
    }
}

/// Evaluates stateIn guard against a state value.
public func stateIn(_ path: String, value: StateValue) -> Bool {
    value.matches(path)
}

/// Guard builder: all conditions must pass.
public func and<Context: Sendable>(_ guards: GuardRef<Context>...) -> GuardRef<Context> {
    .composite(.and(guards))
}

/// Guard builder: at least one condition must pass.
public func or<Context: Sendable>(_ guards: GuardRef<Context>...) -> GuardRef<Context> {
    .composite(.or(guards))
}

/// Guard builder: negates a condition.
public func not<Context: Sendable>(_ guardRef: GuardRef<Context>) -> GuardRef<Context> {
    .composite(.not(guardRef))
}