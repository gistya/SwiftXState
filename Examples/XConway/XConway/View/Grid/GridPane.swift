import SwiftUI

struct GridPane: View {
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
