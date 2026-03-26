import SwiftUI

struct OISurgeCard: View {
    let event: OISurgeEvent

    var isPositive: Bool { event.oiChangeUSD >= 0 }

    var body: some View {
        CardContainer(borderColor: (isPositive ? Color.hlGreen : Color.tradingRed).opacity(0.25)) {
            VStack(alignment: .leading, spacing: 12) {

                // ── Header ──────────────────────────────────────────
                HStack(spacing: 8) {
                    Text("📡").font(.system(size: 20))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Open Interest Surge")
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

                // ── Main stat ────────────────────────────────────────
                HStack(alignment: .top, spacing: 0) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("OI Change")
                            .font(.system(size: 10))
                            .foregroundColor(Color(white: 0.45))
                        Text(event.formattedOI)
                            .font(.system(size: 22, weight: .bold))
                            .foregroundColor(isPositive ? .hlGreen : .tradingRed)
                    }
                    Spacer()
                    StatCell(label: "Window",
                             value: "Last \(event.windowMinutes) min")
                }

                Divider().background(Color.hlDivider)

                HStack {
                    Spacer()
                    ShareButton { shareOI() }
                }
            }
        }
    }

    private func shareOI() {
        let text = """
        📡 Open Interest Surge — \(event.asset)
        OI \(event.formattedOI) in the last \(event.windowMinutes) minutes

        via Hyperview https://hyperview.app
        """
        shareText(text)
    }
}
