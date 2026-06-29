struct ToolBarButtons: View {
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
