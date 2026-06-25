/// Callback logic for long-running listeners, mirroring XState's `fromCallback`.
public struct CallbackActorLogic: Sendable {
    public let run: @Sendable (CallbackActorScope) -> (@Sendable () -> Void)?

    public init(run: @escaping @Sendable (CallbackActorScope) -> (@Sendable () -> Void)?) {
        self.run = run
    }
}

/// Type-erased callback actor logic.
public struct CallbackActorLogicBox: Sendable {
    private let _spawn: @Sendable (
        String,
        SendableValue?,
        any ActorParentRef,
        ActorSystem,
        String?
    ) -> any ChildActor

    public init(_ logic: CallbackActorLogic) {
        _spawn = { id, input, parent, system, systemId in
            let actor = LogicActor(
                CallbackLogic(callback: logic, system: system),
                id: id,
                options: ActorOptions(systemId: systemId),
                parent: parent,
                system: system
            )
            return LogicChildActor(actor: actor, id: id, systemId: systemId, input: input, inspectable: true)
        }
    }

    func spawn(
        id: String,
        input: SendableValue?,
        parent: any ActorParentRef,
        system: ActorSystem,
        systemId: String?
    ) -> any ChildActor {
        _spawn(id, input, parent, system, systemId)
    }
}

/// Scope passed to callback-based actor logic (`fromCallback`).
public struct CallbackActorScope: Sendable {
    public let input: SendableValue?
    public let sendToParent: @Sendable (any Eventable) -> Void
    public let receive: @Sendable (@escaping @Sendable (any Eventable) -> Void) -> Void
    public let emit: @Sendable (EmittedEvent) -> Void
    public let system: ActorSystem

    public init(
        input: SendableValue?,
        sendToParent: @escaping @Sendable (any Eventable) -> Void,
        receive: @escaping @Sendable (@escaping @Sendable (any Eventable) -> Void) -> Void,
        emit: @escaping @Sendable (EmittedEvent) -> Void,
        system: ActorSystem
    ) {
        self.input = input
        self.sendToParent = sendToParent
        self.receive = receive
        self.emit = emit
        self.system = system
    }

    /// Sends an event to the parent actor. Matches XState's `sendBack(event)`.
    ///
    /// Accepts any `Eventable`, including `Event("TYPE")` and string literals (`"TYPE"`).
    public var sendBack: @Sendable (any Eventable) -> Void {
        sendToParent
    }
}
