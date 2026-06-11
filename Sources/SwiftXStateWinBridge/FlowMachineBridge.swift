//
//  FlowMachineBridge.swift
//  SwiftXState — Windows / C# bridge
//
//  "Bring your own machine" — the C# side passes an XState-style machine-definition JSON (states,
//  initial, `on` transitions, nested/parallel/final, `#absolute` targets) and drives it: send events
//  by name, read the current state, ask which events are available, subscribe to state changes.
//
//  This runs SwiftXState's structural `MachineSimulator`: it follows the definition's control flow
//  (modes and transitions) but does NOT execute in-machine guards/actions/context — those are code,
//  not data. That's exactly the right tool for a UI "state of truth" (loading / open / copying /
//  closing): the machine decides the mode, your C# app performs the side effects and sends events
//  back. Keep any real data (paths, progress) on the C# side.
//

import Foundation
import SwiftXState

/// One C#-defined machine: its simulator plus the current state value, behind a lock so C# can drive
/// it from any thread.
private final class FlowMachine: @unchecked Sendable {
    private let lock = NSLock()
    let sim: MachineSimulator
    private var current: StateValue
    let slot = CallbackSlot()

    init(sim: MachineSimulator) {
        self.sim = sim
        self.current = sim.initialValue()
    }

    var value: StateValue { lock.lock(); defer { lock.unlock() }; return current }

    /// Step on an event. Returns the new value if it transitioned, else nil.
    func step(_ event: String) -> StateValue? {
        lock.lock()
        guard let next = sim.step(from: current, event: event) else { lock.unlock(); return nil }
        current = next
        lock.unlock()
        return next
    }

    func reset() -> StateValue {
        lock.lock(); current = sim.initialValue(); let v = current; lock.unlock()
        return v
    }
}

private final class FlowRegistry: @unchecked Sendable {
    static let shared = FlowRegistry()
    private let lock = NSLock()
    private var items: [Int64: FlowMachine] = [:]
    private var nextHandle: Int64 = 1

    func add(_ m: FlowMachine) -> Int64 {
        lock.lock(); defer { lock.unlock() }
        let id = nextHandle; nextHandle += 1
        items[id] = m
        return id
    }
    func get(_ id: Int64) -> FlowMachine? { lock.lock(); defer { lock.unlock() }; return items[id] }
    func remove(_ id: Int64) { lock.lock(); defer { lock.unlock() }; items[id] = nil }
}

/// `#absolute.targets` resolve against the machine id, so pull it from the definition (default "machine").
private func machineID(fromJSON json: String) -> String {
    guard let data = json.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let id = obj["id"] as? String else { return "machine" }
    return id
}

// MARK: - C exports

/// Create a machine from an XState-style definition JSON. Returns an opaque handle, or 0 if the JSON
/// isn't a valid machine definition. Release it with `machineRelease`.
@WinC
public func machineCreate(_ definitionJSON: UnsafePointer<CChar>?) -> Int64 {
    guard let definitionJSON else { return 0 }
    let json = String(cString: definitionJSON)
    guard let sim = MachineSimulator(definitionJSON: json, machineID: machineID(fromJSON: json)) else { return 0 }
    return FlowRegistry.shared.add(FlowMachine(sim: sim))
}

/// Current state value as a string (e.g. "projectOpen", or "a.b" for nested). Caller frees.
@WinC
public func machineState(_ handle: Int64) -> UnsafeMutablePointer<CChar>? {
    guard let m = FlowRegistry.shared.get(handle) else { return nil }
    return dupCString(m.value.description)
}

/// Send an event by name. Returns 1 if it caused a transition, 0 otherwise (unknown handle, or the
/// event isn't accepted in the current state). On a transition the state callback fires.
@WinC
public func machineSend(_ handle: Int64, _ event: UnsafePointer<CChar>?) -> Int32 {
    guard let event, let m = FlowRegistry.shared.get(handle) else { return 0 }
    guard let next = m.step(String(cString: event)) else { return 0 }
    m.slot.fire(next.description)
    return 1
}

/// The events accepted in the current state, as a JSON array of strings. Caller frees.
@WinC
public func machineEvents(_ handle: Int64) -> UnsafeMutablePointer<CChar>? {
    guard let m = FlowRegistry.shared.get(handle) else { return nil }
    return dupCString(jsonString(m.sim.availableEvents(from: m.value)))
}

/// 1 if the current state matches the given path (e.g. "copyingFiles", or "parent.child"), else 0.
@WinC
public func machineMatches(_ handle: Int64, _ statePath: UnsafePointer<CChar>?) -> Int32 {
    guard let statePath, let m = FlowRegistry.shared.get(handle) else { return 0 }
    return m.value.matches(String(cString: statePath)) ? 1 : 0
}

/// Reset the machine to its initial state. Fires the state callback.
@WinC
public func machineReset(_ handle: Int64) {
    guard let m = FlowRegistry.shared.get(handle) else { return }
    m.slot.fire(m.reset().description)
}

/// Register a C callback that fires on every state change with the new state value string. Pass null
/// to clear. The string is only valid during the call — copy it. Fires on the caller's thread.
@WinC
public func machineSetStateCallback(_ handle: Int64, _ callback: InspectCCallback?) {
    FlowRegistry.shared.get(handle)?.slot.set(callback)
}

/// Release a machine handle. Safe to call with an unknown handle.
@WinC
public func machineRelease(_ handle: Int64) {
    FlowRegistry.shared.remove(handle)
}
