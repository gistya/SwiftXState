import XCTest
import Foundation
import SwiftXStateWinBridge

/// Drives a C#-style "bring your own machine": a UI-flow machine defined as XState JSON, run through
/// the bridge's machine* API. Mirrors how the WPF app would model its mode-of-truth.
final class WinBridgeFlowTests: XCTestCase {

    private func take(_ p: UnsafeMutablePointer<CChar>?) -> String {
        guard let p else { return "" }
        defer { free(p) }
        return String(cString: p)
    }

    private let appFlow = """
    {
      "id": "app",
      "initial": "idle",
      "states": {
        "idle": { "on": { "OPEN": "loadingProject" } },
        "loadingProject": { "on": { "LOAD_OK": "projectOpen", "LOAD_FAIL": "error" } },
        "projectOpen": { "on": { "CLOSE": "closing", "COPY": "copyingFiles" } },
        "copyingFiles": { "on": { "COPY_DONE": "projectOpen" } },
        "closing": { "on": { "CLOSED": "idle" } },
        "error": { "on": { "RETRY": "loadingProject" } }
      }
    }
    """

    func testFlowTransitions() {
        let h = machineCreate(appFlow)
        XCTAssertGreaterThan(h, 0)
        XCTAssertEqual(take(machineState(h)), "idle")

        XCTAssertEqual(machineSend(h, "OPEN"), 1)
        XCTAssertEqual(take(machineState(h)), "loadingProject")
        XCTAssertEqual(machineSend(h, "NOPE"), 0)              // not accepted in this state

        XCTAssertEqual(machineSend(h, "LOAD_OK"), 1)
        XCTAssertEqual(take(machineState(h)), "projectOpen")
        XCTAssertEqual(machineMatches(h, "projectOpen"), 1)
        XCTAssertEqual(machineMatches(h, "idle"), 0)
        XCTAssertTrue(take(machineEvents(h)).contains("COPY"))

        XCTAssertEqual(machineSend(h, "COPY"), 1)
        XCTAssertEqual(take(machineState(h)), "copyingFiles")

        machineReset(h)
        XCTAssertEqual(take(machineState(h)), "idle")

        machineRelease(h)
        XCTAssertEqual(take(machineState(h)), "")             // released handle → nil → ""
    }

    func testInvalidDefinitionReturnsZero() {
        XCTAssertEqual(machineCreate("not a machine"), 0)
    }

    // The user's grid-guard machine: 3 modes, 6 events (3 change mode, 3 are in-state self-transitions
    // the machine still validates as legal-only-here).
    private let gridGuard = """
    {
      "id": "gridGuard",
      "initial": "ready",
      "states": {
        "ready": { "on": {
          "changeRequestReceived": "ready",
          "changeRequestDenialSent": "ready",
          "changeRequestApprovalSent": "makingChangesToFiles"
        }},
        "makingChangesToFiles": { "on": {
          "changeRequestCarriedOut": "makingChangesToFiles",
          "requestedChangesConfirmedMade": "awaitingRedrawsOfGrids"
        }},
        "awaitingRedrawsOfGrids": { "on": {
          "gridUpdateConfirmedCompleted": "ready"
        }}
      }
    }
    """

    func testGridGuardFlow() {
        let h = machineCreate(gridGuard)
        XCTAssertGreaterThan(h, 0)
        XCTAssertEqual(take(machineState(h)), "ready")

        // In-state events are accepted (return 1) but stay in ready.
        XCTAssertEqual(machineSend(h, "changeRequestReceived"), 1)
        XCTAssertEqual(take(machineState(h)), "ready")
        XCTAssertEqual(machineSend(h, "changeRequestDenialSent"), 1)
        XCTAssertEqual(take(machineState(h)), "ready")

        // A mode-changing event the machine forbids here returns 0.
        XCTAssertEqual(machineSend(h, "gridUpdateConfirmedCompleted"), 0)
        XCTAssertEqual(take(machineState(h)), "ready")

        // Full happy path.
        XCTAssertEqual(machineSend(h, "changeRequestApprovalSent"), 1)
        XCTAssertEqual(take(machineState(h)), "makingChangesToFiles")
        XCTAssertEqual(machineSend(h, "changeRequestCarriedOut"), 1)          // self, still here
        XCTAssertEqual(take(machineState(h)), "makingChangesToFiles")
        XCTAssertEqual(machineSend(h, "requestedChangesConfirmedMade"), 1)
        XCTAssertEqual(take(machineState(h)), "awaitingRedrawsOfGrids")
        XCTAssertEqual(machineMatches(h, "awaitingRedrawsOfGrids"), 1)
        XCTAssertEqual(machineSend(h, "gridUpdateConfirmedCompleted"), 1)
        XCTAssertEqual(take(machineState(h)), "ready")

        machineRelease(h)
    }
}
