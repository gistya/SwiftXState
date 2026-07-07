import Testing
@testable import SwiftXState

/// Duration-string delays (xstate v6 `parseDurationToMilliseconds` parity): `"10ms"`, `"5s"`, and
/// day-time ISO-8601 like `"PT2M"`, accepted anywhere a numeric delay is (via `resolveAfterDelay`).
@Suite("Duration-string delays")
struct DurationParsingTests {
    @Test("milliseconds + seconds shorthand")
    func shorthand() {
        #expect(parseDurationToMilliseconds("10ms") == 10)
        #expect(parseDurationToMilliseconds("0ms") == 0)
        #expect(parseDurationToMilliseconds("999ms") == 999)
        #expect(parseDurationToMilliseconds("5s") == 5000)
        #expect(parseDurationToMilliseconds("1.5s") == 1500)
        #expect(parseDurationToMilliseconds("0.25s") == 250)
        #expect(parseDurationToMilliseconds("0.001s") == 1)
        #expect(parseDurationToMilliseconds("1.2567s") == 1256)   // truncated to ms precision
        #expect(parseDurationToMilliseconds(".5s") == 500)
        #expect(parseDurationToMilliseconds("s") == 0)
    }

    @Test("ISO-8601 day-time durations")
    func iso8601() {
        #expect(parseDurationToMilliseconds("PT2M") == 120_000)
        #expect(parseDurationToMilliseconds("PT10S") == 10_000)
        #expect(parseDurationToMilliseconds("PT1.5S") == 1_500)
        #expect(parseDurationToMilliseconds("PT1,5S") == 1_500)          // comma decimal
        #expect(parseDurationToMilliseconds("P1D") == 86_400_000)
        #expect(parseDurationToMilliseconds("P1W") == 604_800_000)
        #expect(parseDurationToMilliseconds("P1DT2H30M") == 95_400_000)
        #expect(parseDurationToMilliseconds("P1DT") == 86_400_000)       // T with no time comps, day only
        #expect(parseDurationToMilliseconds("PT0S") == 0)
    }

    @Test("case-insensitive")
    func caseInsensitive() {
        #expect(parseDurationToMilliseconds("10MS") == 10)
        #expect(parseDurationToMilliseconds("5S") == 5000)
        #expect(parseDurationToMilliseconds("pt2m") == 120_000)
        #expect(parseDurationToMilliseconds("  PT2M  ") == 120_000)      // trimmed
    }

    @Test("rejects non-durations and year/month components")
    func rejects() {
        for bad in ["", "abc", "5", "1.5", "10 ms", "P", "PT",
                    "P1Y",      // year — no fixed ms
                    "P1M",      // month (before T) — no fixed ms
                    "PT1D",     // D after T (out of order)
                    "P1H",      // H without T
                    "PT1H1D",   // out of order
                    "1s2"] {    // trailing junk
            #expect(parseDurationToMilliseconds(bad) == nil, "expected nil for \"\(bad)\"")
        }
    }

    @Test("an `after` transition accepts a duration-string delay end-to-end")
    func afterWithDurationString() async {
        let machine = createMachine(MachineConfig(
            id: "d", initial: "idle", context: EmptyContext(),
            states: [
                "idle": StateNodeConfig(after: ["PT1S": .to("done")]),   // == 1000ms
                "done": StateNodeConfig(),
            ]
        ))
        let clock = SimulatedClock()
        let actor = await createActor(machine, options: ActorOptions(clock: clock)).start()

        #expect(await actor.snapshot.matches("idle"))
        clock.increment(999)
        #expect(await actor.snapshot.matches("idle"))
        clock.increment(2)
        await actor.waitForSnapshot { $0.matches("done") }
        #expect(await actor.snapshot.matches("done"))
    }
}
