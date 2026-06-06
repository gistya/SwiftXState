import Foundation
import SwiftXState

enum ChessMachineFactory: Sendable {
    static let id = "chess"
    static let machine: StateMachine<ChessContext> = build()

    static func make() -> StateMachine<ChessContext> {
        machine
    }

    private static func build() -> StateMachine<ChessContext> {
        let machineSetup = ChessCastlingMachine.registerGuards(
            into: setup(guards: [
                "hasOutcome": { args in args.context.outcome != nil },
                "isReplaying": { args in args.context.replaySession != nil },
            ])
        )
        return machineSetup.createMachine(
            MachineConfig(
                id: id,
                context: ChessContext.initial(),
                states: [
                    "game": StateNodeConfig(
                        initial: "playing",
                        states: [
                            "playing": StateNodeConfig(
                                on: [
                                    "TAP.*": .single(TransitionConfig(actions: [assign { ctx, args in
                                        handleTap(&ctx, args: args)
                                    }])),
                                    "PROMOTE.*": .single(TransitionConfig(actions: [assign { ctx, args in
                                        handlePromotion(&ctx, args: args)
                                    }])),
                                    ChessEvent.newGame.type: .single(
                                        TransitionConfig(target: "playing", actions: [assign { ctx, args in
                                            resetGame(&ctx, args)
                                        }])
                                    ),
                                    ChessEvent.enterReplay.type: .single(
                                        TransitionConfig(target: "replaying", actions: [assign { ctx, args in
                                            enterReplay(&ctx, args)
                                        }])
                                    ),
                                ],
                                always: [
                                    TransitionConfig(
                                        target: "gameOver",
                                        guard: .named("hasOutcome")
                                    ),
                                ]
                            ),
                            "gameOver": StateNodeConfig(
                                on: [
                                    ChessEvent.newGame.type: .single(
                                        TransitionConfig(target: "playing", actions: [assign { ctx, args in
                                            resetGame(&ctx, args)
                                        }])
                                    ),
                                    ChessEvent.enterReplay.type: .single(
                                        TransitionConfig(target: "replaying", actions: [assign { ctx, args in
                                            enterReplay(&ctx, args)
                                        }])
                                    ),
                                ]
                            ),
                            "replaying": StateNodeConfig(
                                on: [
                                    ChessEvent.exitReplay.type: .single(
                                        TransitionConfig(target: "playing", actions: [assign { ctx, args in
                                            exitReplay(&ctx, args)
                                        }])
                                    ),
                                    ChessEvent.newGame.type: .single(
                                        TransitionConfig(target: "playing", actions: [assign { ctx, args in
                                            resetGame(&ctx, args)
                                        }])
                                    ),
                                    "REPLAY_SCRUB.*": .single(TransitionConfig(actions: [assign { ctx, args in
                                        scrubReplay(&ctx, args: args)
                                    }])),
                                ]
                            ),
                        ]
                    ),
                    "castling": ChessCastlingMachine.region(),
                ],
                type: .parallel
            )
        )
    }

    private nonisolated static func handleTap(_ context: inout ChessContext, args: ActionArgs<ChessContext>) {
        guard context.replaySession == nil,
              let event = ChessEvent.parse(args.event),
              case let .tap(square) = event else {
            return
        }
        ChessRules.handleTap(&context, at: square)
    }

    private nonisolated static func handlePromotion(_ context: inout ChessContext, args: ActionArgs<ChessContext>) {
        guard context.replaySession == nil,
              let event = ChessEvent.parse(args.event),
              case let .promote(kind) = event else {
            return
        }
        ChessRules.handlePromotion(&context, piece: kind)
    }

    private nonisolated static func resetGame(_ context: inout ChessContext, _: ActionArgs<ChessContext>) {
        context = ChessContext.initial()
        ChessReplayBridge.clearPendingSession()
    }

    private nonisolated static func enterReplay(_ context: inout ChessContext, _: ActionArgs<ChessContext>) {
        guard let session = ChessReplayBridge.takePendingSession() else { return }
        context.captureLiveSnapshot()
        context.replaySession = session
        let lastStep = max(session.steps.count - 1, 0)
        syncReplaySnapshot(&context, step: lastStep)
    }

    private nonisolated static func exitReplay(_ context: inout ChessContext, _: ActionArgs<ChessContext>) {
        context.replaySession = nil
        context.replayStep = 0
        context.restoreLiveSnapshot()
    }

    private nonisolated static func scrubReplay(_ context: inout ChessContext, args: ActionArgs<ChessContext>) {
        guard let event = ChessEvent.parse(args.event),
              case let .replayScrub(step) = event else {
            return
        }
        syncReplaySnapshot(&context, step: step)
    }

    nonisolated static func syncReplaySnapshot(_ context: inout ChessContext, step: Int) {
        guard let session = context.replaySession else { return }
        let clamped = min(max(step, 0), max(session.steps.count - 1, 0))
        ChessReplayRestore.apply(
            stepIndex: clamped,
            recorded: session.steps[clamped],
            session: session,
            to: &context
        )
    }
}

/// Bridges UI-recorded sessions into machine actions.
enum ChessReplayBridge {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var pendingSession: ReplaySession?

    static func setPendingSession(_ session: ReplaySession?) {
        lock.lock()
        pendingSession = session
        lock.unlock()
    }

    static func takePendingSession() -> ReplaySession? {
        lock.lock()
        defer { lock.unlock() }
        let session = pendingSession
        pendingSession = nil
        return session
    }

    static func clearPendingSession() {
        lock.lock()
        pendingSession = nil
        lock.unlock()
    }
}