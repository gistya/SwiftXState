import Foundation

/// The effectful side of `MachineLogic`'s `ActorLogic` conformance: the machine orchestration
/// (side-effect dispatch, `after`, `invoke`) run against a `MachineHosting`. This is the same logic
/// `StateActor` performs inline, lifted to run on the generic `Actor` via the `isolated` host
/// aspect — the Context-specific work (the action switch, `makeChildActor`) lives here in the logic,
/// while the host supplies only Context-agnostic primitives (timers, child registry, emit, parent).
extension MachineLogic {
    public func started<H: MachineHosting>(input: SendableValue?, host: isolated H) async -> MachineSnapshot<Context> {
        let (snapshot, actions) = initialSnapshot(input: input, context: contextOverride)
        var result = await runEffects(snapshot, actions: actions, event: SystemEvent.`init`, host: host)
        // Startup `.action` events are emitted by Actor *after* the `.actor` registration
        // (see startupActionTypes) to match Actor's ordering — not inline here.
        let entered = StateNodeSet(result._nodes)
        let exited = StateNodeSet<Context>()
        applyAfter(entered: entered, exited: exited, snapshot: result, event: SystemEvent.`init`, host: host)
        result = await applyInvokes(entered: entered, exited: exited, snapshot: result, event: SystemEvent.`init`, host: host)
        return result
    }

    public func handle<H: MachineHosting>(
        _ event: any Eventable,
        _ snapshot: MachineSnapshot<Context>,
        host: isolated H
    ) async -> MachineSnapshot<Context> {
        let previousNodes = snapshot._nodes
        let (next, actions, microsteps) = macrostep(
            snapshot: snapshot,
            event: event,
            isInitial: false,
            recordMicrosteps: host.recordsMicrosteps
        )
        var result = await runEffects(next, actions: actions, event: event, host: host)
        for step in microsteps {
            host.emitInspection(.microstep(
                rootId: host.inspectionRootId,
                actor: host.inspectionActorRef,
                triggeringEvent: step.event,
                machineSnapshot: step.snapshot,
                transitions: step.transitions
            ))
        }
        emitActionInspection(actions, event: event, host: host)

        let previousSet = StateNodeSet(previousNodes)
        let newSet = StateNodeSet(result._nodes)
        var entered = StateNodeSet<Context>()
        var exited = StateNodeSet<Context>()
        for node in newSet where !previousSet.contains(node) { entered.insert(node) }
        for node in previousSet where !newSet.contains(node) { exited.insert(node) }

        applyAfter(entered: entered, exited: exited, snapshot: result, event: event, host: host)
        result = await applyInvokes(entered: entered, exited: exited, snapshot: result, event: event, host: host)
        return result
    }

    /// Emits an `@xstate.action` event per inspectable action (mirrors `Actor.inspectAction`).
    private func emitActionInspection<H: MachineHosting>(
        _ actions: [ExecutableAction<Context>],
        event: any Eventable,
        host: isolated H
    ) {
        for action in actions {
            if case let .spawn(spawn) = action.ref, !spawn.inspectable { continue }
            host.emitInspection(.action(
                rootId: host.inspectionRootId,
                actor: host.inspectionActorRef,
                actionType: action.type,
                triggeringEvent: event
            ))
        }
    }

    // MARK: side-effect dispatch (mirrors ActionEffectRunner, against Context-agnostic primitives)

    private func runEffects<H: MachineHosting>(
        _ snapshot: MachineSnapshot<Context>,
        actions: [ExecutableAction<Context>],
        event: any Eventable,
        host: isolated H
    ) async -> MachineSnapshot<Context> {
        var context = snapshot.context
        var children = snapshot.children

        for action in actions {
            switch action.ref {
            case .assign:
                continue
            case .named, .parameterized, .inline, .log:
                let args = ActionArgs(context: context, event: event)
                executeAction(action, context: &context, args: args, implementations: machine.implementations)
            case let .emit(emitAction):
                let args = ActionArgs(context: context, event: event)
                host.emit(resolveEmitEvent(emitAction, args: args))
            case let .spawn(spawn):
                let args = ActionArgs(context: context, event: event)
                await spawnChild(spawn, args: args, host: host)
                children = syncedChildren(previous: children, host: host)
            case let .stopChild(target):
                let args = ActionArgs(context: context, event: event)
                await stopChild(id: resolveChildTarget(target, args: args), host: host)
                children = syncedChildren(previous: children, host: host)
            case let .forwardTo(target):
                let args = ActionArgs(context: context, event: event)
                await host.deliverToChild(id: resolveChildTarget(target, args: args), event: event)
            case let .sendTo(sendToAction):
                let args = ActionArgs(context: context, event: event)
                // Typed cross-actor event: deliver verbatim so the payload survives (the string
                // `Event` resolution path would flatten it). Delay isn't supported for this channel.
                if case let .eventable(typedEvent) = sendToAction.event {
                    await host.deliverToChild(id: resolveChildTarget(sendToAction.target, args: args), event: typedEvent)
                    continue
                }
                let resolved = resolveSendTo(sendToAction, args: args, delays: machine.implementations.delays)
                if let delayMs = resolved.delayMs {
                    host.scheduleChildEvent(
                        timerId: resolved.id ?? "sendTo.\(resolved.childId).\(resolved.event.type)",
                        delay: delayMs,
                        childId: resolved.childId,
                        event: resolved.event
                    )
                } else {
                    await host.deliverToChild(id: resolved.childId, event: resolved.event)
                }
            case let .sendToParent(parentEvent):
                await host.enqueueToParent(parentEvent)
            case .raise:
                if let delayedEvent = action.delayedEvent,
                   let delayMs = action.delayMs,
                   let timerId = action.timerId {
                    host.scheduleSelfEvent(timerId: timerId, delay: delayMs, event: Event(delayedEvent.type))
                }
            case let .cancel(cancelId):
                let args = ActionArgs(context: context, event: event)
                host.cancelTimer(resolveCancelId(cancelId, args: args))
            case .enqueueActions:
                break
            }
        }

        return MachineSnapshot(
            machine: snapshot.machine,
            value: snapshot.value,
            context: context,
            nodes: snapshot._nodes,
            tags: snapshot.tags,
            status: snapshot.status,
            historyValue: snapshot.historyValue,
            output: snapshot.output,
            error: snapshot.error,
            children: children
        )
    }

    // MARK: after / invoke (mirror StateActor.updateDelayedTransitions / updateChildActors)

    private func applyAfter<H: MachineHosting>(
        entered: StateNodeSet<Context>,
        exited: StateNodeSet<Context>,
        snapshot: MachineSnapshot<Context>,
        event: any Eventable,
        host: isolated H
    ) {
        for node in exited {
            for schedule in node.afterSchedules {
                host.cancelTimer(schedule.eventType)
            }
        }
        let args = ActionArgs(context: snapshot.context, event: event)
        for node in entered {
            for schedule in node.afterSchedules {
                let delay = resolveAfterDelay(
                    delayKey: schedule.delayKey,
                    args: args,
                    delays: machine.implementations.delays
                )
                host.scheduleSelfEvent(timerId: schedule.eventType, delay: delay, event: Event(schedule.eventType))
            }
        }
    }

    private func applyInvokes<H: MachineHosting>(
        entered: StateNodeSet<Context>,
        exited: StateNodeSet<Context>,
        snapshot: MachineSnapshot<Context>,
        event: any Eventable,
        host: isolated H
    ) async -> MachineSnapshot<Context> {
        for node in exited {
            for invoke in node.invokeConfigs {
                await stopChild(id: invoke.id, host: host)
            }
        }
        let args = ActionArgs(context: snapshot.context, event: event)
        for node in entered {
            for invoke in node.invokeConfigs {
                let input = invoke.input?(args)
                if let child = makeChildActor(
                    from: invoke.src,
                    id: invoke.id,
                    systemId: invoke.systemId,
                    input: input,
                    syncSnapshot: invoke.syncSnapshot,
                    inspectable: invoke.inspectable,
                    parent: host,
                    implementations: machine.implementations,
                    options: ActorOptions(clock: host.hostClock),
                    persistedChild: host.pendingChildSnapshot(invoke.id),
                    opaqueRestorePolicy: invoke.opaqueRestorePolicy
                ) {
                    host.childRegistry.add(invoke.id, child)
                    host.registerChild(child)
                    if child.inspectable { await host.inspectSpawnedChild(child, machineId: child.machineId) }
                    await child.start()
                }
            }
        }
        let children = syncedChildren(previous: snapshot.children, host: host)
        return MachineSnapshot(
            machine: snapshot.machine,
            value: snapshot.value,
            context: snapshot.context,
            nodes: snapshot._nodes,
            tags: snapshot.tags,
            status: snapshot.status,
            historyValue: snapshot.historyValue,
            output: snapshot.output,
            error: snapshot.error,
            children: children
        )
    }

    // MARK: restore (re-spawn children for a hydrated snapshot)

    public func restoreChildren<H: MachineHosting>(
        _ snapshot: MachineSnapshot<Context>,
        host: isolated H
    ) async -> MachineSnapshot<Context> {
        let entered = StateNodeSet(snapshot._nodes)
        let exited = StateNodeSet<Context>()
        applyAfter(entered: entered, exited: exited, snapshot: snapshot, event: SystemEvent.`init`, host: host)
        var result = await applyInvokes(entered: entered, exited: exited, snapshot: snapshot, event: SystemEvent.`init`, host: host)
        result = await restoreSpawnChildren(result, host: host)
        return result
    }

    /// Re-spawns children created by `spawnChild` entry actions when hydrating (mirrors
    /// `Actor.restoreSpawnChildren`).
    private func restoreSpawnChildren<H: MachineHosting>(
        _ snapshot: MachineSnapshot<Context>,
        host: isolated H
    ) async -> MachineSnapshot<Context> {
        let args = ActionArgs(context: snapshot.context, event: SystemEvent.`init`)
        for node in snapshot._nodes {
            for action in node.entry {
                guard case let .spawn(spawn) = action else { continue }
                await spawnChild(spawn, args: args, host: host)
            }
        }
        let children = syncedChildren(previous: snapshot.children, host: host)
        return MachineSnapshot(
            machine: snapshot.machine,
            value: snapshot.value,
            context: snapshot.context,
            nodes: snapshot._nodes,
            tags: snapshot.tags,
            status: snapshot.status,
            historyValue: snapshot.historyValue,
            output: snapshot.output,
            error: snapshot.error,
            children: children
        )
    }

    // MARK: child primitives

    private func spawnChild<H: MachineHosting>(
        _ spawn: SpawnRef<Context>,
        args: ActionArgs<Context>,
        host: isolated H
    ) async {
        let childId = spawn.id ?? UUID().uuidString
        guard !host.childRegistry.contains(childId) else { return }
        let input = spawn.input?(args)
        if let child = makeChildActor(
            from: spawn.src,
            id: childId,
            systemId: spawn.systemId,
            input: input,
            syncSnapshot: spawn.syncSnapshot,
            inspectable: spawn.inspectable,
            parent: host,
            implementations: machine.implementations,
            options: ActorOptions(clock: host.hostClock),
            persistedChild: host.pendingChildSnapshot(childId),
            opaqueRestorePolicy: spawn.opaqueRestorePolicy
        ) {
            host.childRegistry.add(childId, child)
            host.registerChild(child)
            if child.inspectable { await host.inspectSpawnedChild(child, machineId: child.machineId) }
            await child.start()
        }
    }

    private func stopChild<H: MachineHosting>(id: String, host: isolated H) async {
        guard let child = host.childRegistry.remove(id) else { return }
        host.childRegistry.markStopped(id)
        host.unregisterChild(child)
        await child.stop()
    }

    private func syncedChildren<H: MachineHosting>(
        previous: [String: ChildActorSnapshot],
        host: isolated H
    ) -> [String: ChildActorSnapshot] {
        host.childRegistry.reconcileStopped()
        var childSnapshots = host.childRegistry.snapshots()
        for (id, existing) in previous where childSnapshots[id] == nil && !host.childRegistry.wasStopped(id) {
            childSnapshots[id] = existing
        }
        return childSnapshots
    }
}
