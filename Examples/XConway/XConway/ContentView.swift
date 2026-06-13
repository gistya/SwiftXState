import SwiftUI
import SwiftXState
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var session: LifeSession?
    @State private var editorText: String = LifeRules.conway.jsonString

    var body: some View {
        Group {
            if let session {
                MainView(session: session, editorText: $editorText)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Create the session exactly once, after the environment (modelContext) is available. The
        // `== nil` guard means it never gets recreated — this is the long-lived observable object,
        // and it now gets the real modelContext so persistence (Save Snapshot) actually works.
        .task {
            if session == nil {
                session = LifeSession(modelContext: modelContext)
            }
        }
    }
}

// MARK: - Main layout
//
// `MainView.body` reads NO per-tick state (no snapshot / context / displayContext / history), so it
// does not re-evaluate on every simulation step. Each child takes `session` and reads only the slice
// it needs, so only the grid and the small readouts redraw per tick — the menus, the rules editor,
// and the toolbar buttons stay put and stay responsive.

private struct MainView: View {
    let session: LifeSession
    @Binding var editorText: String

    var body: some View {
        VStack(spacing: 0) {
            Toolbar(session: session)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial)

            // Main area: grid (left, with optional replay bar when paused) + rules sidebar (right).
            HSplitView {
                GridPane(session: session)

                RuleEditor(
                    editorText: $editorText,
                    applyRulesFromJSON: session.applyRulesFromJSON
                )
            }
        }
        .onAppear {
            if session.context.isPlaying { session.play() }
        }
        .onChange(of: session.rulesJSON) { _, new in
            if editorText != new { editorText = new }
        }
    }
}

// MARK: - Toolbar

private struct Toolbar: View {
    let session: LifeSession

    var body: some View {
        HStack(spacing: 12) {
            PlayButton(
                isPlaying: .init(
                    get: { session.context.isPlaying },
                    set: { value in
                        switch value {
                        case true: session.play()
                        case false: session.pause()
                        }
                    }
                ),
                isReplayMode: .init(
                    get: { session.isReplayMode },
                    set: { value in session.isReplayMode = value }
                ),
                restoreFromReplay: session.restoreFromReplay
            )

            ToolBarButtons(
                step: session.step,
                clear: session.clear,
                randomize: { session.randomize() },
                loadTemplate: session.loadTemplate,
                saveSnapshot: session.saveSnapshot
            )

            Spacer()

            Stats(session: session)

            if session.isReplayMode {
                Text("REPLAY")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.orange.opacity(0.25))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }

            Divider().frame(height: 18)

            SpeedControl(session: session)
        }
    }
}

private struct PlayButton: View {
    @Binding var isPlaying: Bool
    @Binding var isReplayMode: Bool
    let restoreFromReplay: () -> Void

    var body: some View {
        Button(isPlaying ? "Pause" : "Play") {
            if isReplayMode {
                restoreFromReplay()
            }

            if isPlaying {
                isPlaying = false
                isReplayMode = true
            } else {
                isPlaying = true
                isReplayMode = false
            }
        }
        .keyboardShortcut(.space, modifiers: [])
    }
}

private struct ToolBarButtons: View {
    let step: () -> Void
    let clear: () -> Void
    let randomize: () -> Void
    let loadTemplate: (String, Int?, Int?) -> Void
    let saveSnapshot: () -> Void
    @State private var justSaved: Bool = false

    var body: some View {
        Button("Step") { step() }
            .keyboardShortcut(.return, modifiers: [.command])

        Button("Clear") { clear() }

        Button("Random") { randomize() }

        Divider().frame(height: 18)

        Menu("Templates") {
            ForEach(LifeTemplate.allCases) { tmpl in
                Button(tmpl.rawValue) {
                    loadTemplate(tmpl.rawValue, nil, nil)
                }
            }
        }
        .menuStyle(.button)

        Button {
            saveSnapshot()
            justSaved = true
            _ = Task {
                try await Task.sleep(for: .milliseconds(30))
                justSaved = false
            }
        } label: {
            Label("Save Snapshot", systemImage: "square.and.arrow.down")
        }
        .help("Write the current full state (grid, rules, generation, etc.) as the last snapshot to SwiftData. No auto-save after steps.")

        if justSaved {
            Text("Saved!")
                .font(.caption)
                .foregroundStyle(.green)
                .transition(.opacity)
        }
    }
}

// Gen / Live readouts — these legitimately change every tick, so they get their own leaf view and
// nothing else in the toolbar redraws with them.
private struct Stats: View {
    let session: LifeSession

    var body: some View {
        let shown = session.displayContext
        HStack(spacing: 12) {
            Text("Gen \(shown.generation)")
                .monospacedDigit()
                .foregroundStyle(.secondary)

            Text("Live \(shown.liveCount)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}

private struct SpeedControl: View {
    let session: LifeSession

    var body: some View {
        HStack(spacing: 6) {
            Text("Speed")
                .foregroundStyle(.secondary)
            Slider(
                value: Binding(
                    get: { session.context.speed },
                    set: { session.setSpeed($0) }
                ),
                in: 1...60, step: 0.5
            )
            .frame(width: 140)
            Text("\(Int(session.context.speed)) /s")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .trailing)
        }
    }
}

// MARK: - Grid + replay scrubber (the per-tick views)

private struct GridPane: View {
    let session: LifeSession

    var body: some View {
        VStack(spacing: 0) {
            // Performant Metal-backed grid (Canvas). The per-tick `displayContext` read lives here,
            // so only this subtree invalidates each step.
            LifeGridView(context: session.displayContext) { x, y in
                if !session.isReplayMode {
                    session.toggleCell(x: x, y: y)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .layoutPriority(1)

            // Replay bar – only when paused and we have prior snapshots to scrub.
            if !session.context.isPlaying && session.history.count > 1 {
                ReplayBar(session: session)
            }
        }
    }
}

private struct ReplayBar: View {
    let session: LifeSession

    var body: some View {
        HStack(spacing: 10) {
            Text("Replay")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            Button {
                session.scrub(to: Int.max)
            } label: {
                Image(systemName: "backward.end.fill")
            }
            .buttonStyle(.plain)

            Slider(
                value: Binding(
                    get: { Double(session.replayIndex) },
                    set: { session.scrub(to: Int($0.rounded())) }
                ),
                in: 0...Double(max(0, session.history.count - 1))
            )

            let hist = session.history
            let idx = min(session.replayIndex, max(0, hist.count - 1))
            Text("\(hist[idx].generation)")
                .monospacedDigit()
                .frame(width: 42, alignment: .trailing)
                .foregroundStyle(.secondary)

            Button("Restore") {
                session.restoreFromReplay()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

            Button("Exit") {
                session.exitReplay()
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.thinMaterial)
    }
}

struct RuleEditor: View {
    @Binding var editorText: String
    @State var disableApply: Bool = false
    @State var jsonError: String? = nil
    let applyRulesFromJSON: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Rules (JSON)")
                    .font(.headline)
                Spacer()
                if disableApply {
                    Text(jsonError ?? "Invalid JSON or schema")
                        .font(.caption)
                        .foregroundStyle(.red)
                } else {
                    Text("Valid — ⌘↩ to apply")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Apply") { applyRulesFromJSON(editorText) }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(disableApply)

                Menu("Presets") {
                    Button("Conway (B3/S23)") { loadRulePreset(.conway) }
                    Button("HighLife (B36/S23)") { loadRulePreset(.highLife) }
                    Button("Seeds (B2/S)") { loadRulePreset(.seeds) }
                    Button("Life w/o Death") { loadRulePreset(.lifeWithoutDeath) }
                    Button("Day & Night (B3678/S34678)") { loadRulePreset(.dayAndNight) }
                }

            }

            TextEditor(text: $editorText)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 220)
                .border(Color.secondary.opacity(0.3))
                .onChange(of: editorText) { _, new in
                    applyEditorJSON()
                }
                .onSubmit { applyEditorJSON() }


        }
        .frame(minWidth: 250, idealWidth: 280, maxWidth: 360)
        .padding(12)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    func loadRulePreset(_ r: LifeRules) {
        let json = r.jsonString
        editorText = json
        jsonError = nil
    }

    private func applyEditorJSON() {
        guard isJSONValid(editorText) else {
            disableApply = true
            jsonError = "Could not parse as LifeRules { \"birth\": [...], \"survive\": [...] }"
            return
        }

        disableApply = false
        jsonError = nil
    }

    private func isJSONValid(_ json: String) -> Bool {
        LifeRules.from(json: json) != nil
    }

}

#Preview {
//    ContentView(session = LifeSession())
//        .frame(width: 960, height: 720)
}
