import SwiftUI

struct SpeedControl: View {
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
