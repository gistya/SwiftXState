import JavaScriptKit
import JavaScriptEventLoop

// A "lite" swarm: one full-stdlib wasm instance (no Web Workers), N SwiftXState node actors
// that communicate through a router actor via the framework's real spawn + send. The async
// Actor runs on the JS event loop's cooperative executor — single-threaded, no shared memory.
JavaScriptEventLoop.installGlobalExecutor()
MainActor.assumeIsolated { runMesh() }
