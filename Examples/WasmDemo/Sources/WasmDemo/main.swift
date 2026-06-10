import JavaScriptKit
import SwiftXState

// Top-level `main.swift` runs on @MainActor; the DOM helpers below match. JS callbacks run on the
// single browser thread, so it's safe to assume MainActor isolation inside handlers.

let document = JSObject.global.document

@MainActor func el(_ tag: String) -> JSValue { document.createElement(tag) }

// Keep JS closures alive for the program's lifetime.
var retained: [JSClosure] = []
@MainActor func handle(_ body: @escaping @MainActor () -> Void) -> JSValue {
    let closure = JSClosure { _ in
        MainActor.assumeIsolated { body() }
        return .undefined
    }
    retained.append(closure)
    return .object(closure)
}

// MARK: - Live state

var currentIndex = 0
var current: DemoSession?
var eventButtons: [(name: String, el: JSValue)] = []
var sidebarButtons: [JSValue] = []

// MARK: - Layout

var page = el("div")
page.style = .string("font:16px/1.5 -apple-system,system-ui,sans-serif;color:#1c1c1e;max-width:760px;margin:2.5rem auto;padding:0 1rem")

var header = el("div")
var h1 = el("h1")
h1.innerText = "SwiftXState · WebAssembly"
h1.style = .string("font-size:1.4rem;margin:0")
var sub = el("p")
sub.innerText = "Native Swift state machines, running in your browser. Pick one and send it events."
sub.style = .string("color:#666;margin:.25rem 0 1.5rem")
_ = header.appendChild(h1)
_ = header.appendChild(sub)

var columns = el("div")
columns.style = .string("display:flex;gap:1.5rem;align-items:flex-start;flex-wrap:wrap")

var sidebar = el("div")
sidebar.style = .string("flex:0 0 200px;display:flex;flex-direction:column;gap:.4rem")

var detail = el("div")
detail.style = .string("flex:1;min-width:280px;border:1px solid #e5e5ea;border-radius:12px;padding:1.25rem")

// Detail sub-elements (reused; only the event buttons are rebuilt per machine)
var titleEl = el("h2")
titleEl.style = .string("font-size:1.15rem;margin:0")
var summaryEl = el("p")
summaryEl.style = .string("color:#666;margin:.25rem 0 1rem")
var stateChip = el("div")
stateChip.style = .string("display:inline-block;font-weight:600;background:#efe9ff;color:#5b3df5;padding:.35rem .75rem;border-radius:8px")
var contextEl = el("div")
contextEl.style = .string("color:#444;margin:.75rem 0 1.25rem;font-variant-numeric:tabular-nums")
var eventsRow = el("div")
eventsRow.style = .string("display:flex;flex-wrap:wrap;gap:.5rem")
var resetEl = el("button")
resetEl.innerText = "↺ Reset"
resetEl.style = .string("margin-top:1.25rem;padding:.4rem .9rem;font-size:.9rem;border:1px solid #d0d0d5;border-radius:8px;background:#fff;cursor:pointer;color:#444")
resetEl.onclick = handle { selectMachine(currentIndex) }

_ = detail.appendChild(titleEl)
_ = detail.appendChild(summaryEl)
_ = detail.appendChild(stateChip)
_ = detail.appendChild(contextEl)
_ = detail.appendChild(eventsRow)
_ = detail.appendChild(resetEl)

// MARK: - Behavior

@MainActor func buttonStyle(primary: Bool, enabled: Bool) -> String {
    let base = "padding:.45rem .9rem;font-size:.95rem;border-radius:8px;cursor:pointer;border:0;"
    let look = primary ? "background:#7c5cff;color:#fff;" : "background:#f1f1f4;color:#1c1c1e;"
    let dim = enabled ? "" : "opacity:.4;cursor:not-allowed;"
    return base + look + dim
}

@MainActor func render() {
    guard let session = current else { return }
    stateChip.innerText = .string("State: \(session.state())")
    contextEl.innerText = .string("Context — \(session.context())")
    for (name, button) in eventButtons {
        let b = button
        let enabled = session.canSend(name)
        b.disabled = .boolean(!enabled)
        b.style = .string(buttonStyle(primary: true, enabled: enabled))
    }
}

@MainActor func selectMachine(_ index: Int) {
    currentIndex = index
    let spec = samples[index]
    current = spec.make()
    titleEl.innerText = .string(spec.name)
    summaryEl.innerText = .string(spec.summary)

    // Rebuild the event buttons for this machine.
    eventsRow.innerHTML = ""
    eventButtons = []
    for name in current!.events {
        let b = el("button")
        b.innerText = .string(name)
        b.onclick = handle {
            current?.send(name)
            render()
        }
        _ = eventsRow.appendChild(b)
        eventButtons.append((name, b))
    }

    // Highlight the selected sidebar entry.
    for (i, sb) in sidebarButtons.enumerated() {
        let s = sb
        s.style = .string(
            "text-align:left;padding:.55rem .8rem;border-radius:8px;cursor:pointer;border:1px solid #e5e5ea;"
            + (i == index ? "background:#7c5cff;color:#fff;border-color:#7c5cff;" : "background:#fff;color:#1c1c1e;")
        )
    }

    render()
}

// Build the sidebar
for (i, spec) in samples.enumerated() {
    let b = el("button")
    b.innerText = .string(spec.name)
    b.onclick = handle { selectMachine(i) }
    _ = sidebar.appendChild(b)
    sidebarButtons.append(b)
}

_ = columns.appendChild(sidebar)
_ = columns.appendChild(detail)
_ = page.appendChild(header)
_ = page.appendChild(columns)
_ = document.body.appendChild(page)

selectMachine(0)
