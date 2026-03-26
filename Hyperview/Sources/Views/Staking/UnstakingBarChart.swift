import SwiftUI

struct UnstakingBarChart: View {
    let bars: [DailyUnstakingBar]
    @State private var selectedIndex: Int? = nil

    private var maxValue: Double {
        bars.map(\.totalHYPE).max() ?? 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Tooltip
            if let idx = selectedIndex, idx < bars.count {
                HStack(spacing: 4) {
                    Text(bars[idx].id)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Color(white: 0.5))
                    Text(formatHYPE(bars[idx].totalHYPE))
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(.orange)
                }
                .padding(.horizontal, 4)
            } else {
                Text("Unstaking Queue (7 days)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color(white: 0.5))
                    .padding(.horizontal, 4)
            }

            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                let barCount = CGFloat(bars.count)
                let spacing: CGFloat = 6
                let barWidth = max((w - spacing * (barCount - 1)) / barCount, 4)

                HStack(alignment: .bottom, spacing: spacing) {
                    ForEach(Array(bars.enumerated()), id: \.element.id) { index, bar in
                        let fraction = maxValue > 0 ? CGFloat(bar.totalHYPE / maxValue) : 0
                        let barHeight = max(fraction * (h - 20), 2) // min 2pt

                        VStack(spacing: 3) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            selectedIndex == index ? Color.orange : Color.orange.opacity(0.8),
                                            selectedIndex == index ? Color.orange.opacity(0.6) : Color.orange.opacity(0.3)
                                        ],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                                .frame(width: barWidth, height: barHeight)

                            Text(bar.id)
                                .font(.system(size: 9))
                                .foregroundColor(Color(white: 0.4))
                                .frame(height: 14)
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                selectedIndex = selectedIndex == index ? nil : index
                            }
                        }
                    }
                }
            }
        }
        .frame(height: 200)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(white: 0.11))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color(white: 0.18), lineWidth: 1)
                )
        )
    }

    private func formatHYPE(_ value: Double) -> String {
        if value >= 1_000_000 {
            return String(format: "%.2fM HYPE", value / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.1fK HYPE", value / 1_000)
        }
        return String(format: "%.1f HYPE", value)
    }
}
