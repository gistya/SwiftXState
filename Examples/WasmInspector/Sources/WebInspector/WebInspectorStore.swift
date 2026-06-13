import JavaScriptKit
import JavaScriptEventLoop
import SwiftXState
import SwiftXStateInspectorCore

/// Browser-side inspector store: a thin wrapper around the platform-neutral `InspectorState`
/// reducer (the same one the native SwiftUI inspector uses) that fires `onChange` after every
/// mutation so the DOM view can re-render. Single-threaded on the JS event loop, so no locking.
@MainActor
public final class WebInspectorStore {
    public private(set) var state = InspectorState()

    /// Called after any state change so the view can re-render. Set by `WebInspector.mount`.
    var onChange: (() -> Void)?

    public init() {}

    /// An inspect sink for `ActorOptions(inspect:)`. Hops to the main actor and ingests.
    public func observe() -> @Sendable (InspectionEvent) -> Void {
        { [weak self] event in
            Task { @MainActor in self?.ingest(event) }
        }
    }

    public func ingest(_ event: InspectionEvent) {
        state.ingest(event)
        onChange?()
    }

    public func select(_ sessionID: String) {
        state.selectedSessionID = sessionID
        onChange?()
    }

    public func send(_ event: String, to sessionID: String) {
        state.send(event, to: sessionID)
        onChange?()
    }

    @discardableResult
    public func loadDefinition(json: String, fallbackID: String = "pasted-machine") throws -> String {
        let id = try state.loadDefinition(json: json, fallbackID: fallbackID)
        onChange?()
        return id
    }
}
