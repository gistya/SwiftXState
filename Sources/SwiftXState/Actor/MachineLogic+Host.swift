import Foundation

/// The effectful side of `MachineLogic`'s `ActorLogic` conformance: the machine orchestration
/// (side-effect dispatch, `after`, `invoke`) run against a `MachineHost`. This is the same logic
/// `StateActor` performs inline, lifted to run on the generic `LogicActor` via the `isolated` host
/// seam — the Context-specific work (the action switch, `makeChildActorRef`) lives here in the logic,
/// while the host supplies only Context-agnostic primitives (timers, child registry, emit, parent).
extension MachineLogic {
    func started<H: MachineHost>(input: SendableValue?, host: isolated H) async -> MachineSnapshot<Context> {
        let (snapshot, actions) = initialSnapshot(input: input, context: nil)
        var result = await runEffects(snapshot, actions: actions, event: SystemEvent.`init`, host: host)
        let entered = StateNodeSet(result._nodes)
        let exited = StateNodeSet<Context>()
        applyAfter(entered: entered, exited: exited, snapshot: result, event: SystemEvent.`init`, host: host)
        result = await applyInvokes(entered: entered, exited: exited, snapshot: result, event: SystemEvent.`init`, host: host)
        return result
    }

    func handle<H: MachineHost>(
        _ event: any Eventable,
        _ snapshot: MachineSnapshot<Context>,
        host: isolated H
    ) async -> MachineSnapshot<Context> {
        let previousNodes = snapshot._nodes
        let (next, actions, _) = macrostep(
            snapshot: snapshot,
            event: event,
            isInitial: false,
            recordMicrosteps: false
        )
        var result = await runEffects(next, actions: actions, event: event, host: host)

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

    // MARK: side-effect dispatch (mirrors ActionEffectRunner, against Context-agnostic primitives)

    private func runEffects<H: MachineHost>(
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
            case let .sendParent(parentEvent):
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

    private func applyAfter<H: MachineHost>(
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

    private func applyInvokes<H: MachineHost>(
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
                if let child = makeChildActorRef(
                    from: invoke.src,
                    id: invoke.id,
                    systemId: invoke.systemId,
                    input: input,
                    syncSnapshot: invoke.syncSnapshot,
                    inspectable: invoke.inspectable,
                    parent: host,
                    implementations: machine.implementations,
                    options: ActorOptions(clock: host.hostClock),
                    persistedChild: nil,
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

    // MARK: child primitives

    private func spawnChild<H: MachineHost>(
        _ spawn: SpawnRef<Context>,
        args: ActionArgs<Context>,
        host: isolated H
    ) async {
        let childId = spawn.id ?? UUID().uuidString
        guard !host.childRegistry.contains(childId) else { return }
        let input = spawn.input?(args)
        if let child = makeChildActorRef(
            from: spawn.src,
            id: childId,
            systemId: spawn.systemId,
            input: input,
            syncSnapshot: spawn.syncSnapshot,
            inspectable: spawn.inspectable,
            parent: host,
            implementations: machine.implementations,
            options: ActorOptions(clock: host.hostClock),
            persistedChild: nil,
            opaqueRestorePolicy: spawn.opaqueRestorePolicy
        ) {
            host.childRegistry.add(childId, child)
            host.registerChild(child)
            if child.inspectable { await host.inspectSpawnedChild(child, machineId: child.machineId) }
            await child.start()
        }
    }

    private func stopChild<H: MachineHost>(id: String, host: isolated H) async {
        guard let child = host.childRegistry.remove(id) else { return }
        host.childRegistry.markStopped(id)
        host.unregisterChild(child)
        await child.stop()
    }

    private func syncedChildren<H: MachineHost>(
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
