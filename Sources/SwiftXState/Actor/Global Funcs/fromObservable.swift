
/// Returns observable actor logic from a subscribable creator.
public func fromObservable<Context: Sendable & Equatable>(
    _ observableCreator: @escaping @Sendable (ObservableActorScope) -> any Subscribable<Context>
) -> ActorSource {
    .observable(ObservableActorLogicBox(ObservableActorLogic { scope in
        AnySubscribable(observableCreator(scope))
    }))
}

/// Returns observable actor logic from a type-erased subscribable creator.
public func fromObservable<Context: Sendable & Equatable>(
    _ observableCreator: @escaping @Sendable (ObservableActorScope) -> AnySubscribable<Context>
) -> ActorSource {
    .observable(ObservableActorLogicBox(ObservableActorLogic(create: observableCreator)))
}
