import Foundation
import SwiftXState

// MARK: - Templates (preloaded patterns you can "drop in")

public enum LifeTemplate: String, CaseIterable, Identifiable {
    case glider = "Glider"
    case blinker = "Blinker"
    case toad = "Toad"
    case beacon = "Beacon"
    case pulsar = "Pulsar"
    case block = "Block"
    case beehive = "Beehive"
    case loaf = "Loaf"
    case boat = "Boat"
    case lwss = "LWSS"
    case gosperGliderGun = "Gosper Glider Gun"

    public var id: String { rawValue }

    /// Relative cells (offsets from top-left anchor). Drop places the anchor near center.
    public nonisolated var cells: [(Int, Int)] {
        switch self {
        case .glider: return [(1,0),(2,1),(0,2),(1,2),(2,2)]
        case .blinker: return [(0,1),(1,1),(2,1)]
        case .toad: return [(1,0),(2,0),(0,1),(1,1),(2,1),(3,1)]
        case .beacon: return [(0,0),(1,0),(0,1),(3,2),(2,3),(3,3)]
        case .pulsar:
            return [
                (2,0),(3,0),(4,0),(0,2),(5,2),(0,3),(5,3),(0,4),(5,4),(2,5),(3,5),(4,5),
                (2,7),(3,7),(4,7),(0,8),(5,8),(0,9),(5,9),(0,10),(5,10),(2,12),(3,12),(4,12)
            ]
        case .block: return [(0,0),(1,0),(0,1),(1,1)]
        case .beehive: return [(1,0),(2,0),(0,1),(3,1),(1,2),(2,2)]
        case .loaf: return [(1,0),(2,0),(0,1),(3,1),(1,2),(2,3)]
        case .boat: return [(0,0),(1,0),(0,1),(2,1),(1,2)]
        case .lwss: return [(1,0),(2,0),(3,0),(0,1),(3,1),(3,2),(0,2),(1,3),(2,3)]
        case .gosperGliderGun:
            return [
                (0,4),(0,5),(1,4),(1,5),(10,4),(10,5),(10,6),(11,3),(11,7),(12,2),(12,8),
                (13,2),(13,8),(14,5),(15,3),(15,7),(16,4),(16,5),(16,6),(17,5),(20,2),
                (20,3),(20,4),(21,2),(21,4),(21,5),(22,3),(24,1),(24,2),(24,4),(24,5),
                (34,3),(34,4),(35,3),(35,4)
            ]
        }
    }
}

// MARK: - The machine (Plan D typed DSL)

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
        XState(.running) {
            // Payload events — referenced by case path, payload read off args.event.
            XTransition(on: LifeEvent.toggleCell, to: .running).action { args, _ in
                var ctx = args.context
                if case let .toggleCell(x, y)? = args.event { ctx[x, y].toggle() }
                return ctx
            }
            XTransition(on: LifeEvent.randomize, to: .running).action { args, _ in
                var ctx = args.context
                var density = 0.28
                if case let .randomize(d)? = args.event { density = d }
                let count = ctx.width * ctx.height
                ctx.cells = (0 ..< count).map { _ in Double.random(in: 0 ... 1) < density }
                ctx.generation = 0
                return ctx
            }
            XTransition(on: LifeEvent.loadTemplate, to: .running).action { args, _ in
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
            XTransition(on: LifeEvent.setRulesJSON, to: .running).action { args, _ in
                var ctx = args.context
                if case let .setRulesJSON(json)? = args.event, let parsed = LifeRules.from(json: json) {
                    ctx.rules = parsed
                }
                return ctx
            }
            XTransition(on: LifeEvent.setSpeed, to: .running).action { args, _ in
                var ctx = args.context
                if case let .setSpeed(s)? = args.event { ctx.speed = max(0.5, min(60.0, s)) }
                return ctx
            }
            XTransition(on: LifeEvent.restore, to: .running).action { args, _ in
                if case let .restore(saved)? = args.event { return saved }
                return args.context
            }

            // Payloadless events — plain case, pure context transform.
            XTransition(on: .step, to: .running).action { ctx in
                var c = ctx
                c.cells = nextGeneration(cells: c.cells, width: c.width, height: c.height, rules: c.rules)
                c.generation += 1
                return c
            }
            XTransition(on: .clear, to: .running).action { ctx in
                var c = ctx; c.reset(); return c
            }
            XTransition(on: .play, to: .running).action { ctx in
                var c = ctx; c.isPlaying = true; return c
            }
            XTransition(on: .pause, to: .running).action { ctx in
                var c = ctx; c.isPlaying = false; return c
            }
        }
        .initial()
    }
}
