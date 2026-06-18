/// What an Interactor should do when a hosted actor reaches a designated failure state.
public enum RestartStrategy: Sendable, Equatable {
    /// Leave the actor where it is (default — supervision is opt-in).
    case stop
    /// Tear down and recreate the actor when its state matches `state`, restarting from initial.
    case restartOnState(String)
}
