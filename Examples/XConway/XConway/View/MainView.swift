import SwiftUI

/// `MainView.body` reads NO per-tick state (no snapshot / context / displayContext / history), so it
/// does not re-evaluate on every simulation step. Each child takes `session` and reads only the slice
/// it needs, so only the grid and the small readouts redraw per tick — the menus, the rules editor,
/// and the toolbar buttons stay put and stay responsive.
struct MainView: View {
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
