import Testing
@testable import SwiftXState

@Suite("waitFor")
struct WaitForTests {
    private var taggedMachine: StateMachine<EmptyContext> {
        createMachine(MachineConfig(
            initial: "loading",
            context: EmptyContext(),
            states: [
                "loading": StateNodeConfig(
                    on: ["LOADED": .to("ready")],
                    tags: ["loading"]
                ),
                "ready": StateNodeConfig(tags: ["loaded"]),
            ]
        ))
    }

    @Test("resolves immediately when current snapshot matches")
    func resolvesImmediately() async throws {
        let reactor = createReactor(taggedMachine).start()

        let snapshot = try await waitFor(reactor) { $0.hasTag("loading") }

        #expect(snapshot.hasTag("loading"))
        #expect(snapshot.matches("loading"))
    }

    @Test("resolves when a later snapshot matches")
    func resolvesOnTransition() async throws {
        let reactor = createReactor(taggedMachine).start()

        async let snapshot = waitFor(reactor) { $0.hasTag("loaded") }

        reactor.send(Event("LOADED"))

        let result = try await snapshot
        #expect(result.hasTag("loaded"))
        #expect(result.matches("ready"))
    }

    @Test("times out when predicate is never satisfied")
    func timesOut() async {
        let reactor = createReactor(taggedMachine).start()

        await #expect(throws: WaitForError.timeout(milliseconds: 50)) {
            try await waitFor(
                reactor,
                predicate: { $0.hasTag("loaded") },
                options: WaitForOptions(timeout: 50)
            )
        }
    }

    @Test("throws when reactor stops before predicate matches")
    func reactorTerminated() async {
        let reactor = createReactor(taggedMachine).start()

        let task = Task {
            try await waitFor(reactor) { $0.hasTag("loaded") }
        }

        reactor.stop()

        await #expect(throws: WaitForError.reactorTerminated) {
            try await task.value
        }
    }

    @Test("rejects immediately for negative timeout")
    func negativeTimeout() async {
        let reactor = createReactor(taggedMachine).start()

        await #expect(throws: WaitForError.timeout(milliseconds: -1)) {
            try await waitFor(
                reactor,
                predicate: { $0.hasTag("loaded") },
                options: WaitForOptions(timeout: -1)
            )
        }
    }

    @Test("supports task cancellation")
    func taskCancellation() async {
        let reactor = createReactor(taggedMachine).start()

        let task = Task {
            try await waitFor(reactor) { $0.hasTag("loaded") }
        }

        try? await Task.sleep(for: .milliseconds(20))
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected task cancellation")
        } catch is CancellationError {
            // expected
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("matches string state paths")
    func matchesStatePath() async throws {
        let reactor = createReactor(taggedMachine).start()

        async let snapshot = waitFor(reactor) { $0.matches("ready") }

        reactor.send(Event("LOADED"))

        #expect(try await snapshot.matches("ready"))
    }
}
