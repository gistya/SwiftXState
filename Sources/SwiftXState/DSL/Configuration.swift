/// The active position of a running machine — *where you are* — generalized from a single state to a
/// tree. For a flat machine this is just `.atomic(id)`; a compound (OR) state nests its one active
/// substate; parallel (AND) regions branch into several simultaneously-active children.
///
/// It is the typed analog of the engine's string `StateValue` (`atomic` / `compound`), so it lowers
/// to `StateValue` by mapping each id to its `name` — and `Configuration<String>` behaves like the
/// engine's value directly. Identity (`StateID`, what a transition targets) stays flat; this tree is
/// what makes the active position *more than one id* once hierarchy and parallelism appear.
public enum Configuration<StateID: StateIdentifying>: Hashable, Sendable {
    /// A single active leaf state.
    case atomic(StateID)

    /// Active child configurations keyed by state id. **One** entry is a compound state's active
    /// substate; **several** entries are a parallel state's simultaneously-active regions.
    case nested([StateID: Configuration<StateID>])
}

public extension Configuration {
    /// Whether `self` is *in* the partial configuration `target`: every branch named by `target` is
    /// present in `self` and recursively satisfied. A subset/refinement test — the typed counterpart
    /// of `StateValue.matches(_:)`.
    func matches(_ target: Configuration<StateID>) -> Bool {
        switch (self, target) {
        case let (.atomic(current), .atomic(want)):
            return current == want
        case let (.nested(children), .atomic(want)):
            return children.keys.contains(want)
        case let (.atomic(current), .nested(want)):
            return want.keys.contains(current)
        case let (.nested(children), .nested(want)):
            for (key, sub) in want {
                guard let mine = children[key], mine.matches(sub) else { return false }
            }
            return true
        }
    }

    /// Whether the atomic state `id` is active at this level (a compound's key, or the leaf itself).
    func matches(_ id: StateID) -> Bool { matches(.atomic(id)) }

    /// Match a dotted path of state `name`s, e.g. `"crossing.pedestrian.walk"`, walking the tree.
    func matches(path: String) -> Bool {
        let parts = path.split(separator: ".").map(String.init)
        return matches(parts: parts)
    }

    private func matches(parts: [String]) -> Bool {
        guard let first = parts.first else { return true }
        switch self {
        case let .atomic(current):
            return parts.count == 1 && current.name == first
        case let .nested(children):
            guard let entry = children.first(where: { $0.key.name == first }) else { return false }
            return parts.count == 1 ? true : entry.value.matches(parts: Array(parts.dropFirst()))
        }
    }

    /// Every currently-active leaf state, flattened.
    var activeLeaves: Set<StateID> {
        switch self {
        case let .atomic(id):
            return [id]
        case let .nested(children):
            return children.values.reduce(into: []) { $0.formUnion($1.activeLeaves) }
        }
    }

    /// Dotted-path rendering using each id's `name` (compound chains join with `.`, parallel regions
    /// with `&`), matching the engine's `StateValue.description` intent.
    var description: String {
        switch self {
        case let .atomic(id):
            return id.name
        case let .nested(children):
            let parts = children
                .sorted { $0.key.name < $1.key.name }
                .map { "\($0.key.name).\($0.value.description)" }
            return parts.count == 1 ? parts[0] : "(" + parts.joined(separator: " & ") + ")"
        }
    }
}
