import SwiftXState

/// The typed event union — XState v6's `{ type, …payload }` as a Swift enum. `EventIdentifying` gives
/// each case a discriminant `name` (via reflection) for free, so the old hand-written `type` switch
/// and `==` are gone; handlers read the payload off the typed `args.event` (no `as? LifeEvent`).
///
/// `Hashable` is synthesized — which is why `LifeContext` (carried by `.restore`) is now `Hashable`.
public nonisolated enum LifeEvent: EventIdentifying {
    case toggleCell(x: Int, y: Int)
    case step
    case play
    case pause
    case clear
    case randomize(density: Double)
    case loadTemplate(name: String, atX: Int?, atY: Int?)
    case setRulesJSON(String)   // the text area sends rules/guards config here -> "sent out to the nodes"
    case setSpeed(Double)
    case restore(LifeContext)   // used by replay bar to jump the live state to a prior snapshot

    public static var _blank: LifeEvent { .step }
}
