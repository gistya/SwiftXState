#if SWIFTXSTATE_INSPECTOR_UI
import Testing
import Foundation
@testable import SwiftXState
@testable import SwiftXStateInspectorUI

@Suite("Events timeline — nanosecond timestamps")
struct NanosecondTimestampTests {
    @Test("InspectionEvent captures integer nanoseconds; timestamp is derived consistently")
    func eventCapturesNanos() {
        let before = wallClockNanosecondsSince1970()
        let event = InspectionEvent(kind: .event, rootId: "r", actor: InspectionActorRef(sessionId: "s", machineId: "m"))
        let after = wallClockNanosecondsSince1970()

        #expect(event.timestampNanos >= before && event.timestampNanos <= after)
        // The Double `timestamp` is derived from the integer nanos (same instant).
        #expect(abs(event.timestamp - Double(event.timestampNanos) / 1_000_000_000) < 1e-9)
    }

    @Test("nanoString renders exactly 9 fractional digits")
    func nanoStringFormatting() {
        // 12:00:00 UTC-ish whole seconds + 42 nanoseconds -> "...00000042" (9 digits, zero-padded).
        let nanos: UInt64 = 1_000_000_000 * 1_700_000_000 + 42
        let s = InspectorTime.nanoString(nanos)
        #expect(s.hasSuffix(".000000042"))

        // Sub-second precision below a microsecond survives (Double would round it away).
        let a = InspectorTime.nanoString(1_700_000_000 * 1_000_000_000 + 123_456_789)
        let b = InspectorTime.nanoString(1_700_000_000 * 1_000_000_000 + 123_456_790)
        #expect(a != b)                     // 1ns apart, distinguishable
        #expect(a.hasSuffix(".123456789"))
    }
}
#endif
