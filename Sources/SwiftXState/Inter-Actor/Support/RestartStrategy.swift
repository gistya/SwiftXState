/// What an Interactor should do when a hosted reactor reaches a designated failure state.
public enum RestartStrategy: Sendable, Equatable {
    /// Leave the reactor where it is (default — supervision is opt-in).
    case stop
    /// Tear down and recreate the reactor when its state matches `state`, restarting from initial.
    case restartOnState(String)
}
