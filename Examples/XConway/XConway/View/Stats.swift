import SwiftUI

/// Gen / Live readouts — these legitimately change every tick, so they get their own leaf view and
/// nothing else in the toolbar redraws with them.
struct Stats: View {
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
