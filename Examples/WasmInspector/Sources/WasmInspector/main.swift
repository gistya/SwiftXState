import JavaScriptKit
import JavaScriptEventLoop
import SwiftXState
import WebInspector

// A browser build of the SwiftXState inspector. Two live actors feed their inspection streams into a
// single store; the WebInspector toolkit renders the actor sidebar + State / Events / Sequence /
// Graph tabs (the Graph tab is the GPU WebGPUGraph renderer). A timer drives the actors so the feed
// and graph animate on their own.

JavaScriptEventLoop.installGlobalExecutor()

struct Ctx: Codable, Sendable, Equatable {}

let trafficLight = createMachine(MachineConfig(
    id: "trafficLight",
    initial: "green",
    context: Ctx(),
    states: [
        "green": StateNodeConfig(on: ["TIMER": .to("yellow")]),
        "yellow": StateNodeConfig(on: ["TIMER": .to("red")]),
        "red": StateNodeConfig(on: ["TIMER": .to("green")]),
    ]
))

let player = createMachine(MachineConfig(
    id: "player",
    initial: "idle",
    context: Ctx(),
    states: [
        "idle": StateNodeConfig(on: ["LOAD": .to("loading")]),
        "loading": StateNodeConfig(on: ["READY": .to("ready"), "FAIL": .to("error")]),
        "ready": StateNodeConfig(on: ["PLAY": .to("playing")]),
        "playing": StateNodeConfig(on: ["PAUSE": .to("paused"), "STOP": .to("ready")]),
        "paused": StateNodeConfig(on: ["PLAY": .to("playing"), "STOP": .to("ready")]),
        "error": StateNodeConfig(on: ["RETRY": .to("loading")]),
    ]
))

let store = WebInspectorStore()
let light = createActor(trafficLight, inspect: store.observe())
let media = createActor(player, inspect: store.observe())

// Text mode for the Graph tab: defaults to the embedded true-MSDF atlas; `?text=sdf` uses runtime SDF.
let search = (JSObject.global.location.search.string ?? "")
let textMode: StateGraph.TextMode = search.contains("sdf") ? .sdf : .msdf

WebInspector.mount(containerId: "app", store: store, graphTextMode: textMode)

// Auto-drive the actors so the feed, pills and graph animate without interaction.
let playerCycle = ["LOAD", "READY", "PLAY", "PAUSE", "PLAY", "STOP"]
Task { @MainActor in
    await light.start()
    await media.start()
    var i = 0
    while true {
        try? await Task.sleep(for: .seconds(1.3))
        await light.send(Event("TIMER"))
        await media.send(Event(playerCycle[i % playerCycle.count]))
        i += 1
    }
}
