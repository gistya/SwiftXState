/// The concrete logic kinds an `ActorSource` resolves to. Exactly one box is non-nil (or `named`,
/// for an unresolved lookup). Was nested in `Actor`; lifted alongside the factory functions below.
struct ResolvedActorSource {
    var machine: MachineActorLogicBox?
    var task: TaskActorLogicBox?
    var callback: CallbackActorLogicBox?
    var taskGroup: TaskGroupActorLogicBox?
    var transition: TransitionActorLogicBox?
    var observable: ObservableActorLogicBox?
    var store: StoreActorLogicBox?
    var named: String?
}
