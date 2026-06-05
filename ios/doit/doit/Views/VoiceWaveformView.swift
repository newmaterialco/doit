import SwiftUI

/// Animated waveform that scrolls left as new audio levels stream in.
struct WaveformView: View {
    let levels: [CGFloat]

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 3) {
                ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                    Capsule()
                        .fill(Color.primary.opacity(0.85))
                        .frame(
                            width: barWidth(in: proxy.size.width),
                            height: max(3, level * proxy.size.height)
                        )
                        .animation(.easeOut(duration: 0.08), value: level)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    private func barWidth(in totalWidth: CGFloat) -> CGFloat {
        guard !levels.isEmpty else { return 2 }
        let spacing: CGFloat = 3 * CGFloat(levels.count - 1)
        let usable = max(0, totalWidth - spacing)
        return max(2, usable / CGFloat(levels.count))
    }
}
