import SwiftUI

struct PlayButton: View {
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
