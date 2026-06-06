import Foundation
import SwiftXState

/// Records `(fromState, move, toState)` from XState-compatible inspection events.
public final class OpeningTransitionTrace: @unchecked Sendable {
    private var lastNodeId: String?
    private var steps: [OpeningTraceStep] = []
    private let machineId: String
    private let rootId: String
    private let lock = NSLock()

    public init(machineId: String = OpeningMoveTreeMachine.id, rootId: String = OpeningDataset.bundled.rootId) {
        self.machineId = machineId
        self.rootId = rootId
        self.lastNodeId = rootId
    }

    public func observe() -> @Sendable (InspectionEvent) -> Void {
        { [weak self] event in
            self?.handle(event)
        }
    }

    public func recordedSteps() -> [OpeningTraceStep] {
        lock.lock()
        defer { lock.unlock() }
        return steps
    }

    public func reset() {
        lock.lock()
        steps.removeAll()
        lastNodeId = rootId
        lock.unlock()
    }

    private func handle(_ event: InspectionEvent) {
        guard event.actor.machineId == machineId else { return }
        lock.lock()
        defer { lock.unlock() }

        switch event.kind {
        case .actor:
            if let snapshot = event.snapshot {
                lastNodeId = nodeId(from: snapshot)
            }
        case .transition:
            guard let snapshot = event.snapshot,
                  let description = event.event,
                  description.type.hasPrefix("SAN.") else {
                if let snapshot = event.snapshot {
                    lastNodeId = nodeId(from: snapshot)
                }
                return
            }
            let san = String(description.type.dropFirst(4))
            let toNodeId = nodeId(from: snapshot)
            let fromNodeId = lastNodeId ?? rootId
            let ply = ply(from: snapshot)
            steps.append(
                OpeningTraceStep(
                    fromNodeId: fromNodeId,
                    moveSAN: san,
                    toNodeId: toNodeId,
                    ply: ply
                )
            )
            lastNodeId = toNodeId
        case .microstep, .snapshot:
            if let snapshot = event.snapshot {
                lastNodeId = nodeId(from: snapshot)
            }
        case .event, .action:
            break
        }
    }

    private func nodeId(from snapshot: InspectionSnapshot) -> String {
        if case let .atomic(value) = snapshot.stateValue {
            return value
        }
        return snapshot.value
    }

    private func ply(from snapshot: InspectionSnapshot) -> Int {
        guard case let .object(context) = snapshot.context,
              case let .number(value) = context["ply"] else {
            return 0
        }
        return Int(value)
    }
}