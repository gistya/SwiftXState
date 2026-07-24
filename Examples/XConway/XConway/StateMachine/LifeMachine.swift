import Foundation
import SwiftXState

/// Conway's Game of Life as a typed `StateMachine`. One `running` state; each event is a self-handled
/// transition whose `.action` mutates context. Payload events are referenced by their **case**
/// (`LifeEvent.toggleCell`) — no placeholder, no `as? LifeEvent` — and the handler reads the payload
/// straight off the typed `args.event`.
public struct LifeMachine: StateMachine {
    public typealias Context = LifeContext
    public typealias StateID = LifeState
    public typealias EventID = LifeEvent

    public init() {}

    /// XState v6's `createMachine({ context })`.
    public var context: LifeContext { .empty() }

    public var machine: some XStateMachine {
        State(.running) {
            // Payload events — referenced by case path, payload read off args.event.
            Transition(on: LifeEvent.toggleCell, to: .running).action { args, _ in
                var ctx = args.context
                if case let .toggleCell(x, y)? = args.event { ctx[x, y].toggle() }
                return ctx
            }
            Transition(on: .randomize, to: .running).action { args, _ in
                var ctx = args.context
                var density = 0.28
                if case let .randomize(d)? = args.event { density = d }
                let count = ctx.width * ctx.height
                ctx.cells = (0 ..< count).map { _ in Double.random(in: 0 ... 1) < density }
                ctx.generation = 0
                return ctx
            }
            Transition(on: LifeEvent.loadTemplate, to: .running).action { args, _ in
                var ctx = args.context
                guard case let .loadTemplate(name, atX, atY)? = args.event,
                      let tmpl = LifeTemplate(rawValue: name) else { return ctx }
                let baseX = atX ?? (ctx.width / 2 - 8)
                let baseY = atY ?? (ctx.height / 2 - 6)
                for (ox, oy) in tmpl.cells {
                    let x = (baseX + ox + ctx.width) % ctx.width
                    let y = (baseY + oy + ctx.height) % ctx.height
                    ctx[x, y] = true
                }
                return ctx
            }
            Transition(on: LifeEvent.setRulesJSON, to: .running).action { args, _ in
                var ctx = args.context
                if case let .setRulesJSON(json)? = args.event, let parsed = LifeRules.from(json: json) {
                    ctx.rules = parsed
                }
                return ctx
            }
            Transition(on: LifeEvent.setSpeed, to: .running).action { args, _ in
                var ctx = args.context
                if case let .setSpeed(s)? = args.event { ctx.speed = max(0.5, min(60.0, s)) }
                return ctx
            }
            Transition(on: LifeEvent.restore, to: .running).action { args, _ in
                if case let .restore(saved)? = args.event { return saved }
                return args.context
            }

            // Payloadless events — plain case, pure context transform.
            Transition(on: .step, to: .running).action { ctx in
                var c = ctx
                c.cells = nextGeneration(cells: c.cells, width: c.width, height: c.height, rules: c.rules)
                c.generation += 1
                return c
            }
            Transition(on: .clear, to: .running).action { ctx in
                var c = ctx; c.reset(); return c
            }
            Transition(on: .play, to: .running).action { ctx in
                var c = ctx; c.isPlaying = true; return c
            }
            Transition(on: .pause, to: .running).action { ctx in
                var c = ctx; c.isPlaying = false; return c
            }
        }
        .initial()
    }
}

// MARK: Workaroud for compiler issue.

// See Swift Evolution pitch:
// https://forums.swift.org/t/pitch-implicit-member-expressions-for-function-typed-parameters/87892/6

extension Map where In == (x: Int, y: Int), Out == LifeEvent {
    static var toggleCell: Map<In, Out> { .init(transform: Out.toggleCell) }
}

extension Map where In == Double, Out == LifeEvent {
    static var randomize: Map<In, Out> { .init(transform: Out.randomize) }
}
