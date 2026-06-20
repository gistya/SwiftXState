import SwiftUI
import SwiftXStateInspectorUI

@MainActor
@Observable
final class SessionModel {
    var session: DistributedChessSession?
    var store: InspectorStore
    
    static func bootstrap() async throws -> SessionModel {
        let store = InspectorStore()
        let session = try await DistributedChessSession(extraInspect: store.observe())
        return SessionModel(session: session, store: store)
    }
    
    init(session: DistributedChessSession?, store: InspectorStore) {
        self.session = session
        self.store = store
    }
}
