//


struct ReplayBar: View {
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