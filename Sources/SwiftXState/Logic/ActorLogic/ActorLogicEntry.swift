/// Machine implementations provided at interpretation time (actions, guards).
/// Registered actor logic for named `invoke` / `spawnChild` sources.
public struct ActorLogicEntry: Sendable {
    public var machine: MachineActorLogicBox?
    public var task: TaskActorLogicBox?
    public var callback: CallbackActorLogicBox?
    public var taskGroup: TaskGroupActorLogicBox?
    public var transition: TransitionActorLogicBox?
    public var observable: ObservableActorLogicBox?
    public var store: StoreActorLogicBox?

    public init(machine: MachineActorLogicBox) {
        self.machine = machine
        self.task = nil
        self.callback = nil
        self.taskGroup = nil
        self.transition = nil
        self.observable = nil
        self.store = nil
    }

    public init(task: TaskActorLogicBox) {
        self.machine = nil
        self.task = task
        self.callback = nil
        self.taskGroup = nil
        self.transition = nil
        self.observable = nil
        self.store = nil
    }

    public init(callback: CallbackActorLogicBox) {
        self.machine = nil
        self.task = nil
        self.callback = callback
        self.taskGroup = nil
        self.transition = nil
        self.observable = nil
        self.store = nil
    }

    public init(taskGroup: TaskGroupActorLogicBox) {
        self.machine = nil
        self.task = nil
        self.callback = nil
        self.taskGroup = taskGroup
        self.transition = nil
        self.observable = nil
        self.store = nil
    }

    public init(transition: TransitionActorLogicBox) {
        self.machine = nil
        self.task = nil
        self.callback = nil
        self.taskGroup = nil
        self.transition = transition
        self.observable = nil
        self.store = nil
    }

    public init(observable: ObservableActorLogicBox) {
        self.machine = nil
        self.task = nil
        self.callback = nil
        self.taskGroup = nil
        self.transition = nil
        self.observable = observable
        self.store = nil
    }

    public init(store: StoreActorLogicBox) {
        self.machine = nil
        self.task = nil
        self.callback = nil
        self.taskGroup = nil
        self.transition = nil
        self.observable = nil
        self.store = store
    }

    public init(_ source: ActorSource) {
        switch source {
        case let .machine(machine):
            self.machine = machine
            self.task = nil
            self.callback = nil
            self.taskGroup = nil
            self.transition = nil
            self.observable = nil
            self.store = nil
        case let .task(task):
            self.machine = nil
            self.task = task
            self.callback = nil
            self.taskGroup = nil
            self.transition = nil
            self.observable = nil
            self.store = nil
        case let .callback(callback):
            self.machine = nil
            self.task = nil
            self.callback = callback
            self.taskGroup = nil
            self.transition = nil
            self.observable = nil
            self.store = nil
        case let .taskGroup(taskGroup):
            self.machine = nil
            self.task = nil
            self.callback = nil
            self.taskGroup = taskGroup
            self.transition = nil
            self.observable = nil
            self.store = nil
        case let .transition(transition):
            self.machine = nil
            self.task = nil
            self.callback = nil
            self.taskGroup = nil
            self.transition = transition
            self.observable = nil
            self.store = nil
        case let .observable(observable):
            self.machine = nil
            self.task = nil
            self.callback = nil
            self.taskGroup = nil
            self.transition = nil
            self.observable = observable
            self.store = nil
        case let .store(store):
            self.machine = nil
            self.task = nil
            self.callback = nil
            self.taskGroup = nil
            self.transition = nil
            self.observable = nil
            self.store = store
        case .named:
            fatalError("Cannot create ActorLogicEntry from .named source")
        }
    }
}
