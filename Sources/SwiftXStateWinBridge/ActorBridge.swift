//
//  ActorBridge.swift
//  SwiftXState — Windows / C# bridge
//
//  Handle-based actor exports. Because `Actor<Context>` is generic, it can't cross the C ABI directly,
//  so each actor is erased behind closures (like the demo's DemoSession), stored in a registry, and
//  referenced from C# by an opaque `Int64` handle. Events are passed by name (C string); state and
//  context come back as JSON / strings the caller frees.
//
//  Convention recap: `@WinC` exports each function as `Capitalized` C symbol when SWIFTXWIN is set.
//  Strings out are heap-allocated; C# frees them (see Interop/csharp/SwiftXStateWinBridge.cs).
//

import Foundation
import SwiftXState

// MARK: - Inspection callback plumbing

/// A C callback `void (*)(const char *json)` that C# can register to receive live inspection events.
public typealias InspectCCallback = @convention(c) (UnsafePointer<CChar>?) -> Void

/// Holds the (settable) C callback for one actor and forwards inspection events to it as JSON. The C
/// string is valid only for the duration of the call — C# must copy it (PtrToStringUTF8) immediately.
final class CallbackSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: InspectCCallback?
    func set(_ cb: InspectCCallback?) { lock.lock(); callback = cb; lock.unlock() }
    func fire(_ json: String) {
        lock.lock(); let cb = callback; lock.unlock()
        guard let cb else { return }
        json.withCString { cb($0) }
    }
}

private let inspectionEncoder = JSONEncoder()
private func encodeEvent(_ event: InspectionEvent) -> String {
    guard let data = try? inspectionEncoder.encode(event),
          let s = String(data: data, encoding: .utf8) else { return "{}" }
    return s
}

// MARK: - Type-erased actor handle + registry

/// A running actor with its context erased behind closures — all the C bridge needs.
private struct ActorHandleBox {
    let events: [String]
    let send: (String) -> Bool          // true if the event caused a transition
    let state: () -> String
    let contextJSON: () -> String
    let inspect: CallbackSlot           // live inspection events go here (set via actorSetSnapshotCallback)
}

private func makeBox<C: Sendable & Equatable>(_ machine: StateMachine<C>) -> ActorHandleBox {
    let slot = CallbackSlot()
    let actor = createActor(machine, inspect: { event in slot.fire(encodeEvent(event)) }).start()
    return ActorHandleBox(
        events: machine.events,
        send: { name in
            let event = Event(name)
            guard actor.snapshot.can(event) else { return false }
            actor.send(event)
            return true
        },
        state: { actor.snapshot.value.description },
        contextJSON: {
            var fields: [String: String] = [:]
            for child in Mirror(reflecting: actor.snapshot.context).children {
                if let label = child.label { fields[label] = "\(child.value)" }
            }
            return jsonString(fields)
        },
        inspect: slot
    )
}

/// Thread-safe handle table. C# may call from any thread, so the registry is locked; the actors
/// themselves are `@unchecked Sendable` with their own internal queue.
private final class BridgeRegistry: @unchecked Sendable {
    static let shared = BridgeRegistry()
    private let lock = NSLock()
    private var actors: [Int64: ActorHandleBox] = [:]
    private var nextHandle: Int64 = 1

    func add(_ box: ActorHandleBox) -> Int64 {
        lock.lock(); defer { lock.unlock() }
        let id = nextHandle; nextHandle += 1
        actors[id] = box
        return id
    }
    func get(_ id: Int64) -> ActorHandleBox? {
        lock.lock(); defer { lock.unlock() }
        return actors[id]
    }
    func remove(_ id: Int64) {
        lock.lock(); defer { lock.unlock() }
        actors[id] = nil
    }
}

// MARK: - Built-in machines (the C# caller picks one by name)

private struct EmptyCtx: Sendable, Equatable {}

/// Machines the bridge can instantiate by name. (Arbitrary machines defined in Swift would be
/// registered the same way; loading behavior from JSON is a separate, larger feature.)
let availableMachines = ["toggle", "counter", "vending"]

private func buildMachine(_ name: String) -> ActorHandleBox? {
    switch name {
    case "toggle":
        return makeBox(createMachine(MachineConfig(
            id: "toggle", initial: "inactive", context: EmptyCtx(),
            states: [
                "inactive": StateNodeConfig(on: ["TOGGLE": .to("active")]),
                "active": StateNodeConfig(on: ["TOGGLE": .to("inactive")]),
            ])))
    case "counter":
        struct Ctx: Sendable, Equatable { var count = 0 }
        return makeBox(createMachine(MachineConfig(
            id: "counter", initial: "running", context: Ctx(),
            states: [
                "running": StateNodeConfig(on: [
                    "INC": .single(TransitionConfig(actions: [assign { (c: inout Ctx, _) in c.count += 1 }])),
                    "DEC": .single(TransitionConfig(actions: [assign { (c: inout Ctx, _) in c.count -= 1 }])),
                ]),
            ])))
    case "vending":
        struct Ctx: Sendable, Equatable { var credits = 0 }
        return makeBox(createMachine(MachineConfig(
            id: "vending", initial: "idle", context: Ctx(),
            states: [
                "idle": StateNodeConfig(on: [
                    "COIN": .single(TransitionConfig(actions: [assign { (c: inout Ctx, _) in c.credits += 1 }])),
                    "DISPENSE": .single(TransitionConfig(
                        target: "dispensing",
                        guard: .inline { $0.context.credits >= 3 },
                        actions: [assign { (c: inout Ctx, _) in c.credits -= 3 }])),
                ]),
                "dispensing": StateNodeConfig(on: ["TAKE": .to("idle")]),
            ])))
    default:
        return nil
    }
}

// MARK: - C exports

/// Create an actor for a built-in machine by name. Returns an opaque handle, or 0 if the name is
/// unknown. Release it with `actorRelease`.
@WinC
public func actorCreate(_ name: UnsafePointer<CChar>?) -> Int64 {
    guard let name, let box = buildMachine(String(cString: name)) else { return 0 }
    return BridgeRegistry.shared.add(box)
}

/// Send an event (by name) to an actor. Returns 1 if it caused a transition, 0 otherwise (unknown
/// handle, or the event isn't accepted in the current state).
@WinC
public func actorSend(_ handle: Int64, _ event: UnsafePointer<CChar>?) -> Int32 {
    guard let event, let box = BridgeRegistry.shared.get(handle) else { return 0 }
    return box.send(String(cString: event)) ? 1 : 0
}

/// Current state value as a string (e.g. "active", "a.b"). Caller frees. Empty handle → nil.
@WinC
public func actorState(_ handle: Int64) -> UnsafeMutablePointer<CChar>? {
    guard let box = BridgeRegistry.shared.get(handle) else { return nil }
    return dupCString(box.state())
}

/// Current context as a JSON object of `{ field: stringifiedValue }`. Caller frees.
@WinC
public func actorContextJSON(_ handle: Int64) -> UnsafeMutablePointer<CChar>? {
    guard let box = BridgeRegistry.shared.get(handle) else { return nil }
    return dupCString(box.contextJSON())
}

/// The events this actor's machine declares, as a JSON array of strings. Caller frees.
@WinC
public func actorEvents(_ handle: Int64) -> UnsafeMutablePointer<CChar>? {
    guard let box = BridgeRegistry.shared.get(handle) else { return nil }
    return dupCString(jsonString(box.events))
}

/// Register a C callback to receive this actor's live inspection events (one JSON document per event:
/// `@xstate.snapshot`, `@xstate.event`, transitions, …). Pass null to clear. The JSON pointer is only
/// valid during the call — copy it immediately. Callbacks fire on the actor's thread.
@WinC
public func actorSetSnapshotCallback(_ handle: Int64, _ callback: InspectCCallback?) {
    BridgeRegistry.shared.get(handle)?.inspect.set(callback)
}

/// Release an actor handle (drops the actor). Safe to call with an unknown handle.
@WinC
public func actorRelease(_ handle: Int64) {
    BridgeRegistry.shared.remove(handle)
}

/// The machine names `actorCreate` accepts, as a JSON array of strings. Caller frees.
@WinC
public func machineList() -> UnsafeMutablePointer<CChar>? {
    dupCString(jsonString(availableMachines))
}

// MARK: - Small helpers (single place to adjust for the Windows CRT)

/// Heap-copy a Swift string into a C string the caller must free. (`strdup` is POSIX/ucrt; on MSVC
/// this is the one spot to swap in `_strdup` if needed.)
@inline(__always)
func dupCString(_ s: String) -> UnsafeMutablePointer<CChar>? { strdup(s) }

/// Encode a JSON-serializable value to a compact string, or a safe empty default.
func jsonString(_ value: Any) -> String {
    guard JSONSerialization.isValidJSONObject(value),
          let data = try? JSONSerialization.data(withJSONObject: value),
          let s = String(data: data, encoding: .utf8) else {
        return (value is [Any]) ? "[]" : "{}"
    }
    return s
}
