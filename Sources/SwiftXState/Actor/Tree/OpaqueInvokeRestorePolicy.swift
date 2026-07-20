/// How opaque invoke children (task, callback, taskGroup) behave when hydrating from a persisted snapshot.
public enum OpaqueInvokeRestorePolicy: String, Sendable, Equatable {
    /// Always spawn a fresh child (default). Pair with `onCancel` to clean up partial external work.
    case restart
    /// Skip auto-spawn on restore when the persisted opaque child was `.active` (in-flight).
    /// Use entry actions to reconcile external stores, then manually re-invoke or transition.
    case skipIfActive
    /// Skip auto-spawn whenever any opaque persisted child snapshot exists (active, done, or error).
    case skipIfPresent
}
