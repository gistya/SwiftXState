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
