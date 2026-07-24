#if hasFeature(Embedded)
// Embedded Swift does not implicitly import the concurrency module the way full Swift does.
import _Concurrency
#endif

// MARK: - Non-owning back-reference

/// A reference to an object that the holder must not keep alive — a child's pointer to its parent,
/// a subscription's pointer back to its owner, a timer callback's pointer to the actor it fires on.
///
/// On platforms with `weak` this *is* a `weak` reference; the type exists so that Embedded Swift,
/// which prohibits `weak` outright, can substitute a strong reference without every call site
/// growing an `#if`. Reading ``value`` yields an `Optional` on both platforms, so the surrounding
/// `self?.doThing()` code is identical everywhere.
///
/// ## Why a strong reference is acceptable on Embedded
///
/// A strong back-reference forms a retain cycle, and a cycle means `deinit` never runs — so `deinit`
/// cannot be the safety net here. SwiftXState relies on two properties instead:
///
///  1. **Top-level actors are immortal.** An embedded application's machine actors are created at
///     startup and run for the life of the device. A cycle among them costs nothing, because that
///     memory was never going to be reclaimed.
///  2. **Everything else is torn down explicitly.** Invoked and spawned children are stopped on
///     state exit, by `stopChild`, or by their parent's teardown — all of which route through
///     ``Actor/stop()``, which drops the references that would otherwise form the cycle.
///
/// The failure mode this leaves is narrow and singular: a child removed from ``ChildRegistry``
/// without `stop()` having run leaks. `ChildRegistry.remove(_:)` asserts against exactly that.
///
/// - Note: On Apple platforms and Linux this is a plain `weak` reference, so lifetime behaviour is
///   unchanged from before this type existed. Only the Embedded build takes the strong path.
struct BackRef<T: AnyObject & Sendable>: @unchecked Sendable {
    #if hasFeature(Embedded)
    /// Strong — see the type's discussion. Embedded prohibits both `weak` and safe `unowned`.
    private let ref: T?
    #else
    private weak var ref: T?
    #endif

    init(_ value: T?) {
        ref = value
    }

    /// The referent, or `nil` once it has been released (never `nil` on Embedded, where the
    /// reference is strong).
    var value: T? { ref }
}

/// The parent-link counterpart to ``BackRef``, for `any ParentActorRepresentable`.
///
/// A protocol existential cannot satisfy ``BackRef``'s `T: AnyObject` constraint ("requires that
/// 'any P' be a class type"), even for a class-bound protocol — but a `weak` *stored property* of
/// existential type is fine. Hence this concrete twin. Same contract, same rationale.
struct ParentRef: @unchecked Sendable {
    #if hasFeature(Embedded)
    private let ref: (any ParentActorRepresentable)?
    #else
    private weak var ref: (any ParentActorRepresentable)?
    #endif

    init(_ value: (any ParentActorRepresentable)?) {
        ref = value
    }

    var value: (any ParentActorRepresentable)? { ref }
}
