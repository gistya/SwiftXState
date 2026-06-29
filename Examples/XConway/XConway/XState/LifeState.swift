import CompositionalInit

/// The machine has a single behavioural state — Life is a long-running interpreter of events. (Play
/// vs. pause is *context* (`isPlaying`), driven by the UI timer, not a separate state.)
public enum LifeState: String, StateIdentifying {
    case running
    public static var _blank: LifeState { .running }
}
