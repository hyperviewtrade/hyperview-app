import SwiftUI

struct SignalCard: View {
    let event: SignalEvent

    var body: some View {
        CardContainer(borderColor: Color.blue.opacity(0.25)) {
            VStack(alignment: .leading, spacing: 12) {

                // ── Header ──────────────────────────────────────────
                HStack(spacing: 8) {
                    Text("📡").font(.system(size: 20))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(event.signalType.rawValue)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                        Text(relativeTime(event.timestamp))
                            .font(.system(size: 11))
                            .foregroundColor(.gray)
                    }
                    Spacer()
                    Text(event.asset)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.hlDivider)
                        .cornerRadius(6)
                }

                // ── Long/Short bar ───────────────────────────────────
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(event.formattedLong)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.hlGreen)
                        Spacer()
                        Text(event.formattedShort)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.tradingRed)
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.tradingRed.opacity(0.4))
                                .frame(maxWidth: .infinity)
                                .frame(height: 6)
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.hlGreen.opacity(0.8))
                                .frame(width: geo.size.width * event.longPercent, height: 6)
                        }
                    }
                    .frame(height: 6)
                }

                // ── Value ────────────────────────────────────────────
                if event.signalType != .crowdedTrade {
                    HStack {
                        Text(event.signalType == .fundingSpike ? "Funding Rate" : "OI Change")
                            .font(.system(size: 11))
                            .foregroundColor(.gray)
                        Spacer()
                        Text(event.formattedValue)
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundColor(event.signalType == .fundingSpike
                                             ? (event.value > 0 ? .hlGreen : .tradingRed)
                                             : .white)
                    }
                }

                Divider().background(Color.hlDivider)

                HStack {
                    Spacer()
                    ShareButton { shareSignal() }
                }
            }
        }
    }

    private func shareSignal() {
        let text = """
        📡 \(event.signalType.rawValue) — \(event.asset)
        \(event.formattedLong) | \(event.formattedShort)
        \(event.signalType != .crowdedTrade ? "Value: \(event.formattedValue)" : "")

        via Hyperview https://hyperview.app
        """
        shareText(text)
    }
}
