import Foundation

/// The host operations the side-effect dispatch loop needs from its owning actor.
///
/// Extracting the dispatch out of `Actor` (so the generics refactor's `StateActor` can reuse the
/// exact same logic) means the loop can no longer reach the actor's private methods directly. This
/// protocol is that seam: a small set of effect operations the host actor implements.
///
/// Crucially the protocol refines `Actor`, and `ActionEffectRunner.run` takes the host as an
/// **`isolated`** parameter (SE-0313). That means the dispatch body executes *inside the host
/// actor's isolation domain* — every call below is a same-actor, non-hopping call, identical to
/// when the loop lived on `Actor` itself. No new suspension points are introduced, so the
/// `isProcessing` run-to-completion / reentrancy guard keeps holding.
protocol EffectHost: _Concurrency.Actor {
    associatedtype Context: Sendable

    /// The actor's current snapshot — re-read after `spawnFromAction` / `stopChild` mutate it
    /// (mirrors the old `result = _snapshot ?? result`).
    var effectSnapshot: MachineSnapshot<Context>? { get }

    func notifyEmitted(_ event: EmittedEvent)
    func spawnFromAction(_ spawn: SpawnRef<Context>, args: ActionArgs<Context>) async
    func stopChild(id: String) async
    func deliverToChild(id childId: String, event: any Eventable) async
    func scheduleDelayedSendTo(childId: String, event: Event, delay: Int, timerId: String)
    func enqueueToParent(_ event: any Eventable) async
    func scheduleDelayedTransition(eventType: String, delay: Int, timerId: String)
    func cancelScheduledTimer(_ timerId: String)
}

/// Runs a macrostep's resolved side-effect actions against a host actor, returning the snapshot
/// that results (context mutated by `assign`/inline actions, value/children carried from any
/// spawn/stop that updated the host's snapshot mid-loop).
///
/// Stateless: it owns nothing, holding all per-run state in locals. Pure dispatch — the heavy
/// operations live on the `host`; the resolver helpers (`resolveSendTo`, `resolveChildTarget`,
/// `resolveCancelId`, `resolveEmitEvent`) are free functions called directly.
struct ActionEffectRunner {
    func run<H: EffectHost>(
        snapshot: MachineSnapshot<H.Context>,
        actions: [ExecutableAction<H.Context>],
        event: any Eventable,
        machine: StateMachine<H.Context>,
        host: isolated H
    ) async -> MachineSnapshot<H.Context> {
        var context = snapshot.context
        var result = snapshot

        for action in actions {
            switch action.ref {
            case .assign:
                continue
            case .named, .parameterized, .inline, .log:
                let args = ActionArgs(context: context, event: event)
                executeAction(action, context: &context, args: args, implementations: machine.implementations)
            case let .emit(emitAction):
                let args = ActionArgs(context: context, event: event)
                host.notifyEmitted(resolveEmitEvent(emitAction, args: args))
            case let .spawn(spawn):
                let args = ActionArgs(context: context, event: event)
                await host.spawnFromAction(spawn, args: args)
                result = host.effectSnapshot ?? result
            case let .stopChild(target):
                let args = ActionArgs(context: context, event: event)
                await host.stopChild(id: resolveChildTarget(target, args: args))
                result = host.effectSnapshot ?? result
            case let .forwardTo(target):
                let args = ActionArgs(context: context, event: event)
                await host.deliverToChild(id: resolveChildTarget(target, args: args), event: event)
            case let .sendTo(sendToAction):
                let args = ActionArgs(context: context, event: event)
                let resolved = resolveSendTo(
                    sendToAction,
                    args: args,
                    delays: machine.implementations.delays
                )
                if let delayMs = resolved.delayMs {
                    host.scheduleDelayedSendTo(
                        childId: resolved.childId,
                        event: resolved.event,
                        delay: delayMs,
                        timerId: resolved.id ?? "sendTo.\(resolved.childId).\(resolved.event.type)"
                    )
                } else {
                    await host.deliverToChild(id: resolved.childId, event: resolved.event)
                }
            case let .sendParent(parentEvent):
                await host.enqueueToParent(parentEvent)
            case .raise:
                if let delayedEvent = action.delayedEvent,
                   let delayMs = action.delayMs,
                   let timerId = action.timerId {
                    host.scheduleDelayedTransition(
                        eventType: delayedEvent.type,
                        delay: delayMs,
                        timerId: timerId
                    )
                }
            case let .cancel(cancelId):
                let args = ActionArgs(context: context, event: event)
                host.cancelScheduledTimer(resolveCancelId(cancelId, args: args))
            case .enqueueActions:
                break
            }
        }

        return MachineSnapshot(
            machine: result.machine,
            value: result.value,
            context: context,
            nodes: result._nodes,
            tags: result.tags,
            status: result.status,
            historyValue: result.historyValue,
            output: result.output,
            error: result.error,
            children: result.children
        )
    }
}

extension Actor: EffectHost {}
