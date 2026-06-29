struct Toolbar: View {
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
