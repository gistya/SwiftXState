/// Source logic for spawning a child actor.
public enum ActorSource: Sendable {
    case named(String)
    case machine(MachineActorLogicBox)
    case task(TaskActorLogicBox)
    case callback(CallbackActorLogicBox)
    case taskGroup(TaskGroupActorLogicBox)
    case transition(TransitionActorLogicBox)
    case observable(ObservableActorLogicBox)
    case store(StoreActorLogicBox)
}
