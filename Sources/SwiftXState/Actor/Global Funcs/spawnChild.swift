/// An action that spawns a child actor from an `ActorSource` (`fromTask`, `fromCallback`, a child
/// machine, or a `.named` registered actor). `input` seeds the child's context; `syncSnapshot`
/// streams the child's snapshots back to the parent. XState's `spawnChild`.
public func spawnChild<Context: Sendable>(
    _ src: ActorSource,
    id: String? = nil,
    systemId: String? = nil,
    input: (@Sendable (ActionArgs<Context>) -> SendableValue?)? = nil,
    syncSnapshot: Bool = false,
    inspectable: Bool = true
) -> ActionRef<Context> {
    .spawn(
        SpawnRef(
            src: src,
            id: id,
            systemId: systemId,
            input: input,
            syncSnapshot: syncSnapshot,
            inspectable: inspectable
        )
    )
}
