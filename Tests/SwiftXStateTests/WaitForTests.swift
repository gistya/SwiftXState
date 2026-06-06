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
        let actor = createActor(taggedMachine).start()

        let snapshot = try await waitFor(actor) { $0.hasTag("loading") }

        #expect(snapshot.hasTag("loading"))
        #expect(snapshot.matches("loading"))
    }

    @Test("resolves when a later snapshot matches")
    func resolvesOnTransition() async throws {
        let actor = createActor(taggedMachine).start()

        async let snapshot = waitFor(actor) { $0.hasTag("loaded") }

        actor.send(Event("LOADED"))

        let result = try await snapshot
        #expect(result.hasTag("loaded"))
        #expect(result.matches("ready"))
    }

    @Test("times out when predicate is never satisfied")
    func timesOut() async {
        let actor = createActor(taggedMachine).start()

        await #expect(throws: WaitForError.timeout(milliseconds: 50)) {
            try await waitFor(
                actor,
                predicate: { $0.hasTag("loaded") },
                options: WaitForOptions(timeout: 50)
            )
        }
    }

    @Test("throws when actor stops before predicate matches")
    func actorTerminated() async {
        let actor = createActor(taggedMachine).start()

        let task = Task {
            try await waitFor(actor) { $0.hasTag("loaded") }
        }

        actor.stop()

        await #expect(throws: WaitForError.actorTerminated) {
            try await task.value
        }
    }

    @Test("rejects immediately for negative timeout")
    func negativeTimeout() async {
        let actor = createActor(taggedMachine).start()

        await #expect(throws: WaitForError.timeout(milliseconds: -1)) {
            try await waitFor(
                actor,
                predicate: { $0.hasTag("loaded") },
                options: WaitForOptions(timeout: -1)
            )
        }
    }

    @Test("supports task cancellation")
    func taskCancellation() async {
        let actor = createActor(taggedMachine).start()

        let task = Task {
            try await waitFor(actor) { $0.hasTag("loaded") }
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
        let actor = createActor(taggedMachine).start()

        async let snapshot = waitFor(actor) { $0.matches("ready") }

        actor.send(Event("LOADED"))

        #expect(try await snapshot.matches("ready"))
    }
}