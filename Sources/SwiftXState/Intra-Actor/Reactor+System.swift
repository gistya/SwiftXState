import Foundation


/// Any reactor that can be registered in an reactor system.
public protocol ReactorSystemRef: AnyObject, Sendable {
    var sessionId: String { get }
    var systemId: String? { get }
}

    
/// Registry for reactors within a state machine system, mirroring XState's `system`.
public final class ReactorSystem: @unchecked Sendable {
    private var keyedReactors: [String: any ReactorSystemRef] = [:]
    private var sessionReactors: [String: any ReactorSystemRef] = [:]
    private var inspectionObservers: [(@Sendable (InspectionEvent) -> Void)] = []
    private var rootId: String?
    private let lock = NSLock()

    public init() {}

    /// Session id of the root reactor in this system.
    public var rootSessionId: String? {
        lock.lock()
        defer { lock.unlock() }
        return rootId
    }

    func setRootIdIfNeeded(_ id: String) {
        lock.lock()
        defer { lock.unlock() }
        if rootId == nil {
            rootId = id
        }
    }

    /// Subscribes to inspection events from all reactors in this system.
    @discardableResult
    public func inspect(
        _ observer: @escaping @Sendable (InspectionEvent) -> Void
    ) -> Subscription {
        lock.lock()
        inspectionObservers.append(observer)
        let index = inspectionObservers.count - 1
        lock.unlock()

        return Subscription { [weak self] in
            self?.lock.lock()
            if let self, index < self.inspectionObservers.count {
                self.inspectionObservers.remove(at: index)
            }
            self?.lock.unlock()
        }
    }

    func sendInspection(_ event: InspectionEvent) {
        lock.lock()
        let observers = inspectionObservers
        lock.unlock()
        for observer in observers {
            observer(event)
        }
    }

    /// Whether any inspector is currently subscribed. Lets the runtime skip expensive
    /// inspection-only work (e.g. serializing the machine definition) when nobody listens.
    var hasInspectors: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !inspectionObservers.isEmpty
    }

    /// Registers an reactor by session id.
    @discardableResult
    public func register(_ reactor: any ReactorSystemRef) -> String {
        lock.lock()
        defer { lock.unlock() }
        sessionReactors[reactor.sessionId] = reactor
        if let systemId = reactor.systemId {
            keyedReactors[systemId] = reactor
        }
        return reactor.sessionId
    }

    /// Registers an reactor under a named system id.
    public func set(systemId: String, reactor: any ReactorSystemRef) {
        lock.lock()
        defer { lock.unlock() }
        keyedReactors[systemId] = reactor
    }

    /// Looks up an reactor by system id.
    public func get(systemId: String) -> (any ReactorSystemRef)? {
        lock.lock()
        defer { lock.unlock() }
        return keyedReactors[systemId]
    }

    /// Returns all reactors registered by system id.
    public func getAll() -> [String: any ReactorSystemRef] {
        lock.lock()
        defer { lock.unlock() }
        return keyedReactors
    }

    /// Removes an reactor from the registry.
    public func unregister(_ reactor: any ReactorSystemRef) {
        lock.lock()
        defer { lock.unlock() }
        sessionReactors.removeValue(forKey: reactor.sessionId)
        if let systemId = reactor.systemId {
            if keyedReactors[systemId] === reactor {
                keyedReactors.removeValue(forKey: systemId)
            }
        }
        for (key, value) in keyedReactors where value === reactor {
            keyedReactors.removeValue(forKey: key)
        }
    }
}

