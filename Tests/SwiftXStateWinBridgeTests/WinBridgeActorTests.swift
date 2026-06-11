import XCTest
import Foundation
import SwiftXStateWinBridge

/// Drives the C bridge through its public Swift facade functions (the same code the `@_cdecl` exports
/// forward to). Returned C strings are freed, exactly as the C# side does.
final class WinBridgeActorTests: XCTestCase {

    private func take(_ p: UnsafeMutablePointer<CChar>?) -> String {
        guard let p else { return "" }
        defer { free(p) }
        return String(cString: p)
    }

    func testCounterContextUpdates() {
        let handle = actorCreate("counter")
        XCTAssertGreaterThan(handle, 0)
        XCTAssertEqual(take(actorState(handle)), "running")
        XCTAssertEqual(actorSend(handle, "INC"), 1)
        XCTAssertEqual(actorSend(handle, "INC"), 1)
        XCTAssertEqual(actorSend(handle, "NOPE"), 0)        // unhandled event → no transition
        XCTAssertTrue(take(actorContextJSON(handle)).contains("\"count\":\"2\""))
        actorRelease(handle)
        XCTAssertEqual(take(actorState(handle)), "")        // released handle → nil → ""
    }

    func testToggleAndUnknownMachine() {
        XCTAssertEqual(actorCreate("does-not-exist"), 0)
        let handle = actorCreate("toggle")
        XCTAssertEqual(take(actorState(handle)), "inactive")
        XCTAssertEqual(actorSend(handle, "TOGGLE"), 1)
        XCTAssertEqual(take(actorState(handle)), "active")
        actorRelease(handle)
    }

    func testVendingGuardBlocksThenAllows() {
        let handle = actorCreate("vending")
        XCTAssertEqual(actorSend(handle, "DISPENSE"), 0)    // 0 credits → guard blocks
        XCTAssertEqual(actorSend(handle, "COIN"), 1)
        XCTAssertEqual(actorSend(handle, "COIN"), 1)
        XCTAssertEqual(actorSend(handle, "COIN"), 1)
        XCTAssertEqual(actorSend(handle, "DISPENSE"), 1)    // 3 credits → dispenses
        XCTAssertEqual(take(actorState(handle)), "dispensing")
        actorRelease(handle)
    }

    func testMachineListAndEvents() {
        XCTAssertTrue(take(machineList()).contains("counter"))
        let handle = actorCreate("toggle")
        XCTAssertTrue(take(actorEvents(handle)).contains("TOGGLE"))
        actorRelease(handle)
    }
}
