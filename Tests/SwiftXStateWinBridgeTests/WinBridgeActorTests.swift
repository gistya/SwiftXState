import XCTest
import Foundation
import SwiftXStateWinBridge

/// Drives the C bridge through its public Swift facade functions (the same code the `@_cdecl` exports
/// forward to). Returned C strings are freed, exactly as the C# side does.
final class WinBridgeReactorTests: XCTestCase {

    private func take(_ p: UnsafeMutablePointer<CChar>?) -> String {
        guard let p else { return "" }
        defer { free(p) }
        return String(cString: p)
    }

    func testCounterContextUpdates() {
        let handle = reactorCreate("counter")
        XCTAssertGreaterThan(handle, 0)
        XCTAssertEqual(take(reactorState(handle)), "running")
        XCTAssertEqual(reactorSend(handle, "INC"), 1)
        XCTAssertEqual(reactorSend(handle, "INC"), 1)
        XCTAssertEqual(reactorSend(handle, "NOPE"), 0)        // unhandled event → no transition
        XCTAssertTrue(take(reactorContextJSON(handle)).contains("\"count\":\"2\""))
        reactorRelease(handle)
        XCTAssertEqual(take(reactorState(handle)), "")        // released handle → nil → ""
    }

    func testToggleAndUnknownMachine() {
        XCTAssertEqual(reactorCreate("does-not-exist"), 0)
        let handle = reactorCreate("toggle")
        XCTAssertEqual(take(reactorState(handle)), "inactive")
        XCTAssertEqual(reactorSend(handle, "TOGGLE"), 1)
        XCTAssertEqual(take(reactorState(handle)), "active")
        reactorRelease(handle)
    }

    func testVendingGuardBlocksThenAllows() {
        let handle = reactorCreate("vending")
        XCTAssertEqual(reactorSend(handle, "DISPENSE"), 0)    // 0 credits → guard blocks
        XCTAssertEqual(reactorSend(handle, "COIN"), 1)
        XCTAssertEqual(reactorSend(handle, "COIN"), 1)
        XCTAssertEqual(reactorSend(handle, "COIN"), 1)
        XCTAssertEqual(reactorSend(handle, "DISPENSE"), 1)    // 3 credits → dispenses
        XCTAssertEqual(take(reactorState(handle)), "dispensing")
        reactorRelease(handle)
    }

    func testMachineListAndEvents() {
        XCTAssertTrue(take(machineList()).contains("counter"))
        let handle = reactorCreate("toggle")
        XCTAssertTrue(take(reactorEvents(handle)).contains("TOGGLE"))
        reactorRelease(handle)
    }
}
