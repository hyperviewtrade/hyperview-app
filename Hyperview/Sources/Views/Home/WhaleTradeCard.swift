import SwiftUI

struct WhaleTradeCard: View {
    let event: WhaleTradeEvent

    var body: some View {
        CardContainer(borderColor: event.isLong
                      ? Color.hlGreen.opacity(0.25)
                      : Color.tradingRed.opacity(0.25)) {
            VStack(alignment: .leading, spacing: 12) {

                // ── Header ──────────────────────────────────────────
                HStack(spacing: 8) {
                    Text("🐋").font(.system(size: 20))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(event.whaleCount > 1 ? "Whale Activity" : "Whale Trade")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                        Text(relativeTime(event.timestamp))
                            .font(.system(size: 11))
                            .foregroundColor(.gray)
                    }
                    Spacer()
                    DirectionBadge(isLong: event.isLong)
                }

                // ── Stats ────────────────────────────────────────────
                HStack(alignment: .top, spacing: 0) {
                    StatCell(label: "Asset", value: event.asset, large: true)
                    Spacer()
                    StatCell(label: "Total Size", value: event.formattedSize,
                             valueColor: .white, large: true)
                    Spacer()
                    if event.whaleCount > 1 {
                        StatCell(label: "Whales", value: "\(event.whaleCount) 🐋")
                    } else {
                        StatCell(label: "Entry", value: event.formattedEntryPrice)
                    }
                }

                Divider().background(Color.hlDivider)

                // ── Footer ───────────────────────────────────────────
                HStack {
                    Text(event.shortAddress)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.gray)
                    Spacer()
                    ShareButton { shareWhale() }
                }
            }
        }
    }

    private func shareWhale() {
        let direction = event.isLong ? "LONG" : "SHORT"
        let countNote = event.whaleCount > 1
            ? "\(event.whaleCount) whales — Total: \(event.formattedSize)"
            : "Size: \(event.formattedSize)"
        let text = """
        🐋 Whale \(direction) on \(event.asset)
        \(countNote)
        Entry: \(event.formattedEntryPrice)

        via Hyperview https://hyperview.app
        """
        shareText(text)
    }
}
