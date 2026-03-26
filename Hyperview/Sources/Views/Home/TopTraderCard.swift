import SwiftUI

struct TopTraderCard: View {
    let event: TopTraderEvent

    var body: some View {
        CardContainer(borderColor: Color(red: 1, green: 0.84, blue: 0).opacity(0.2)) {
            VStack(alignment: .leading, spacing: 12) {

                // ── Header ──────────────────────────────────────────
                HStack(spacing: 8) {
                    Text("🏆").font(.system(size: 20))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(event.isClosed ? "Top Trader Closed" : "Top Trader Opened")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                        Text(relativeTime(event.timestamp))
                            .font(.system(size: 11))
                            .foregroundColor(.gray)
                    }
                    Spacer()
                    DirectionBadge(isLong: event.isLong)
                }

                // ── Stats row 1 ──────────────────────────────────────
                HStack(alignment: .top, spacing: 0) {
                    StatCell(label: "Asset",  value: event.asset, large: true)
                    Spacer()
                    StatCell(label: "Size",   value: event.formattedSize,
                             valueColor: .white, large: true)
                    Spacer()
                    StatCell(label: "Winrate",
                             value: event.formattedWinrate,
                             valueColor: .hlGreen)
                }

                // ── Stats row 2 ──────────────────────────────────────
                HStack(alignment: .top, spacing: 0) {
                    StatCell(label: "Entry",  value: event.formattedEntry)
                    Spacer()
                    StatCell(label: event.isClosed ? "Exit" : "Current",
                             value: event.formattedExit)
                    Spacer()
                    StatCell(label: "PnL",
                             value: event.formattedPnl,
                             valueColor: event.pnl >= 0 ? .hlGreen : .tradingRed)
                    Spacer()
                    StatCell(label: "ROI",
                             value: event.formattedROI,
                             valueColor: event.pnl >= 0 ? .hlGreen : .tradingRed)
                }

                Divider().background(Color.hlDivider)

                // ── Footer ───────────────────────────────────────────
                HStack {
                    Button {
                        // Navigate to wallet detail
                    } label: {
                        HStack(spacing: 4) {
                            Text(event.shortAddress)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.hlGreen)
                                .underline()
                            Text("View Wallet")
                                .font(.system(size: 11))
                                .foregroundColor(.hlGreen)
                        }
                    }
                    Spacer()
                    ShareButton { shareTrader() }
                }
            }
        }
    }

    private func shareTrader() {
        let action  = event.isClosed ? "closed" : "opened"
        let dir     = event.isLong ? "long" : "short"
        let pnlLine = event.isClosed
            ? "\nPnL: \(event.formattedPnl) (\(event.formattedROI))"
            : ""
        let text = """
        🏆 Top trader \(event.shortAddress) just \(action) a \(event.formattedSize) \(event.asset) \(dir)
        Entry: \(event.formattedEntry)\(pnlLine)
        Winrate: \(event.formattedWinrate)

        via Hyperview https://hyperview.app
        """
        shareText(text)
    }
}
