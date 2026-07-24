//


func shouldSpawnOpaqueChild(
    persistedChild: PersistedChildSnapshot?,
    policy: OpaqueInvokeRestorePolicy
) -> Bool {
    guard let persistedChild, case let .opaque(snapshot) = persistedChild else {
        return true
    }

    switch policy {
    case .restart:
        return true
    case .skipIfActive:
        return snapshot.status != .active
    case .skipIfPresent:
        return false
    }
}
