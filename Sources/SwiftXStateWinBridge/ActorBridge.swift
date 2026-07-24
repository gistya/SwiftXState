//
//  ActorBridge.swift
//  SwiftXState — Windows / C# bridge
//
//  Handle-based actor exports. Because `Actor<MachineLogic<Context>>` is generic, it can't cross the C ABI directly,
//  so each actor is erased behind closures (like the demo's DemoSession), stored in a registry, and
//  referenced from C# by an opaque `Int64` handle. Events are passed by name (C string); state and
//  context come back as JSON / strings the caller frees.
//
//  Convention recap: `@WinC` exports each function as `Capitalized` C symbol when SWIFTXWIN is set.
//  Strings out are heap-allocated; C# frees them (see Interop/csharp/SwiftXStateWinBridge.cs).
//
import Foundation
import Synchronization
import SwiftXState
// MARK: - Inspection callback plumbing
/// A C callback `void (*)(const char *json)` that C# can register to receive live inspection events.
public typealias InspectCCallback = @convention(c) (UnsafePointer<CChar>?) -> Void
/// Holds the (settable) C callback for one actor and forwards inspection events to it as JSON. The C
/// string is valid only for the duration of the call — C# must copy it (PtrToStringUTF8) immediately.
final class CallbackSlot: @unchecked Sendable {
    private let lock = Mutex(false)
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
private final class SnapshotCache<C: Sendable>: @unchecked Sendable {
    private let lock = Mutex(false)
    private var snapshot: MachineSnapshot<C>
    init(_ snapshot: MachineSnapshot<C>) {
        self.snapshot = snapshot
    }
    func get() -> MachineSnapshot<C> {
        lock.lock(); defer { lock.unlock() }
        return snapshot
    }
    func set(_ snapshot: MachineSnapshot<C>) {
        lock.lock(); defer { lock.unlock() }
        self.snapshot = snapshot
    }
}
private func makeBox<C: Sendable & Equatable>(_ machine: ResolvedMachine<C>) -> ActorHandleBox {
    let slot = CallbackSlot()
    let initialSnapshot = initialTransition(machine).snapshot
    let cache = SnapshotCache(initialSnapshot)
    let actor = createActor(machine, inspect: { event in slot.fire(encodeEvent(event)) })
    // `actor.start()` is async, but `actorCreate` is a synchronous C entry point. Block until the
    // actor has started and subscribed before returning the handle, so a C# `actorSend`/`actorState`
    // issued right after `actorCreate` can never reach an unstarted actor (which would trap in
    // `processEvent`). `actorCreate` runs on an external (C#) thread, not the actor's executor, so
    // the wait can't deadlock; the subscribe seeds the cache with the started snapshot.
    let ready = DispatchSemaphore(value: 0)
    Task {
        await actor.start()
        _ = await actor.subscribe { snapshot in
            cache.set(snapshot)
        }
        ready.signal()
    }
    ready.wait()
    return ActorHandleBox(
        events: machine.events,
        send: { name in
            let event = Event(name)
            guard cache.get().can(event) else { return false }
            let semaphore = DispatchSemaphore(value: 0)
            Task {
                await actor.send(event)
                semaphore.signal()
            }
            semaphore.wait()
            return true
        },
        state: { cache.get().value.description },
        contextJSON: {
            var fields: [String: String] = [:]
            for child in Mirror(reflecting: cache.get().context).children {
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
    private let lock = Mutex(false)
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
public func actorCreate(_ name: UnsafePointer<CChar>?) -> Int64 {
    guard let name, let box = buildMachine(String(cString: name)) else { return 0 }
    return BridgeRegistry.shared.add(box)
}
/// Send an event (by name) to an actor. Returns 1 if it caused a transition, 0 otherwise (unknown
/// handle, or the event isn't accepted in the current state).
public func actorSend(_ handle: Int64, _ event: UnsafePointer<CChar>?) -> Int32 {
    guard let event, let box = BridgeRegistry.shared.get(handle) else { return 0 }
    return box.send(String(cString: event)) ? 1 : 0
}
/// Current state value as a string (e.g. "active", "a.b"). Caller frees. Empty handle → nil.
public func actorState(_ handle: Int64) -> UnsafeMutablePointer<CChar>? {
    guard let box = BridgeRegistry.shared.get(handle) else { return nil }
    return dupCString(box.state())
}
/// Current context as a JSON object of `{ field: stringifiedValue }`. Caller frees.
public func actorContextJSON(_ handle: Int64) -> UnsafeMutablePointer<CChar>? {
    guard let box = BridgeRegistry.shared.get(handle) else { return nil }
    return dupCString(box.contextJSON())
}
/// The events this actor's machine declares, as a JSON array of strings. Caller frees.
public func actorEvents(_ handle: Int64) -> UnsafeMutablePointer<CChar>? {
    guard let box = BridgeRegistry.shared.get(handle) else { return nil }
    return dupCString(jsonString(box.events))
}
/// Register a C callback to receive this actor's live inspection events (one JSON document per event:
/// `@xstate.snapshot`, `@xstate.event`, transitions, …). Pass null to clear. The JSON pointer is only
/// valid during the call — copy it immediately. Callbacks fire on the actor's thread.
///
/// Cross-ABI contract (the bridge cannot enforce these across the C boundary, so the host must):
/// - Keep the delegate/function pointer alive until after `actorRelease` returns. The slot stores a
///   raw `@convention(c)` pointer; if the host frees the delegate while an event is in flight, the
///   callback fires into freed memory. `actorRelease` clears this slot first to narrow that window,
///   but an event already mid-dispatch on the actor's thread can still be running.
/// - Do not swap the callback (call this) concurrently with `actorRelease` on the same handle, and do
///   not set a new callback from inside the callback. The slot lock is not reentrant.
public func actorSetSnapshotCallback(_ handle: Int64, _ callback: InspectCCallback?) {
    BridgeRegistry.shared.get(handle)?.inspect.set(callback)
}
/// Release an actor handle (drops the actor). Safe to call with an unknown handle.
///
/// Clears the inspection callback before dropping the actor so a late event during teardown (e.g. a
/// delayed transition firing as the actor deallocates) can't call into a callback the host is about
/// to free. This narrows — but cannot fully close — the window: an event already past the slot's
/// lock and mid-dispatch on the actor's thread may still be invoking the old callback when this
/// returns. The host must keep the delegate alive until after this call (see `actorSetSnapshotCallback`).
public func actorRelease(_ handle: Int64) {
    // Proactively detach the host callback first, then drop the actor.
    BridgeRegistry.shared.get(handle)?.inspect.set(nil)
    BridgeRegistry.shared.remove(handle)
}
/// The machine names `actorCreate` accepts, as a JSON array of strings. Caller frees.
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

// MARK: - C exports (Windows bridge)
//
// `@_cdecl` peers, gated on `SWIFTXWIN`, expose the actor handle API to C / C#.
#if SWIFTXWIN
@_cdecl("ActorCreate")
public func actorCreate_WinC(_ name: UnsafePointer<CChar>?) -> Int64 { actorCreate(name) }

@_cdecl("ActorSend")
public func actorSend_WinC(_ handle: Int64, _ event: UnsafePointer<CChar>?) -> Int32 { actorSend(handle, event) }

@_cdecl("ActorState")
public func actorState_WinC(_ handle: Int64) -> UnsafeMutablePointer<CChar>? { actorState(handle) }

@_cdecl("ActorContextJSON")
public func actorContextJSON_WinC(_ handle: Int64) -> UnsafeMutablePointer<CChar>? { actorContextJSON(handle) }

@_cdecl("ActorEvents")
public func actorEvents_WinC(_ handle: Int64) -> UnsafeMutablePointer<CChar>? { actorEvents(handle) }

@_cdecl("ActorSetSnapshotCallback")
public func actorSetSnapshotCallback_WinC(_ handle: Int64, _ callback: InspectCCallback?) { actorSetSnapshotCallback(handle, callback) }

@_cdecl("ActorRelease")
public func actorRelease_WinC(_ handle: Int64) { actorRelease(handle) }

@_cdecl("MachineList")
public func machineList_WinC() -> UnsafeMutablePointer<CChar>? { machineList() }
#endif
