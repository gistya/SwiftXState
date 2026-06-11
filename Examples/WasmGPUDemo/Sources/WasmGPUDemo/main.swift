import JavaScriptKit
import JavaScriptEventLoop
import SwiftXState
import WebGPUGraph

// Thin demo: a SwiftXState machine, with its graph rendered on the GPU by the reusable
// `WebGPUGraph` toolkit. The toolkit owns the rendering; this file owns the machine + buttons.

JavaScriptEventLoop.installGlobalExecutor()

struct PlayerCtx: Sendable, Equatable {}

let machine = createMachine(MachineConfig(
    id: "player",
    initial: "idle",
    context: PlayerCtx(),
    states: [
        "idle": StateNodeConfig(on: ["LOAD": .to("loading")]),
        "loading": StateNodeConfig(on: ["READY": .to("ready"), "FAIL": .to("error")]),
        "ready": StateNodeConfig(on: ["PLAY": .to("playing")]),
        "playing": StateNodeConfig(on: ["PAUSE": .to("paused"), "STOP": .to("ready")]),
        "paused": StateNodeConfig(on: ["PLAY": .to("playing"), "STOP": .to("ready")]),
        "error": StateNodeConfig(on: ["RETRY": .to("loading")]),
    ]
))
let actor = createActor(machine).start()

var eventButtons: [(name: String, el: JSValue)] = []
var retained: [JSClosure] = []
var lastSelected: String?

@MainActor func refresh() {
    let active = actor.snapshot.value.description
    StateGraph.setActiveState(active)
    for (name, button) in eventButtons {
        let enabled = actor.snapshot.can(Event(name))
        button.disabled = .boolean(!enabled)
        button.style = .string(buttonStyle(enabled: enabled))
    }
    var text = "Active: \(active)"
    if let s = lastSelected { text += "    ·    tapped: \(s)" }
    let el = JSObject.global.document.getElementById("status")
    el.innerText = .string(text)
}

@MainActor func buttonStyle(enabled: Bool) -> String {
    "margin:.25rem;padding:.45rem .9rem;font-size:.9rem;border:0;border-radius:8px;"
        + "background:#7c5cff;color:#fff;cursor:pointer;" + (enabled ? "" : "opacity:.3;cursor:not-allowed;")
}

@MainActor func buildButtons() {
    let document = JSObject.global.document
    let events = document.getElementById("events").object!
    for name in machine.events {
        let button = document.createElement("button")
        button.innerText = .string(name)
        let closure = JSClosure { _ in
            MainActor.assumeIsolated {
                actor.send(Event(name))
                refresh()
            }
            return .undefined
        }
        retained.append(closure)
        button.onclick = .object(closure)
        _ = events.appendChild!(button)
        eventButtons.append((name, button))
    }
}

Task {
    await StateGraph.start(
        canvasElementId: "gpu",
        definitionJSON: (try? machine.definitionJSON()) ?? ""
    ) { tappedName in
        lastSelected = tappedName
        refresh()
    }
    buildButtons()
    refresh()
}
