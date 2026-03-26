import SwiftUI

struct LiquidationCard: View {
    let event: LiquidationEvent

    var body: some View {
        CardContainer(borderColor: Color.tradingRed.opacity(0.3)) {
            VStack(alignment: .leading, spacing: 12) {

                // ── Header ──────────────────────────────────────────
                HStack(spacing: 8) {
                    Text("💥").font(.system(size: 20))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Liquidation")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                        Text(relativeTime(event.timestamp))
                            .font(.system(size: 11))
                            .foregroundColor(.gray)
                    }
                    Spacer()
                    Text(event.wasLong ? "LONG LIQ" : "SHORT LIQ")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.tradingRed)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.tradingRed.opacity(0.15))
                        .cornerRadius(6)
                }

                // ── Stats ────────────────────────────────────────────
                HStack(alignment: .top, spacing: 0) {
                    StatCell(label: "Asset",     value: event.asset, large: true)
                    Spacer()
                    StatCell(label: "Liq Size",  value: event.formattedSize,
                             valueColor: .tradingRed, large: true)
                    Spacer()
                    StatCell(label: "Side",
                             value: event.wasLong ? "Long" : "Short")
                }

                Divider().background(Color.hlDivider)

                // ── Footer ───────────────────────────────────────────
                HStack {
                    Button {
                        // Navigate to wallet detail
                    } label: {
                        Text(event.shortAddress)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.hlGreen)
                            .underline()
                    }
                    Spacer()
                    ShareButton { shareLiquidation() }
                }
            }
        }
    }

    private func shareLiquidation() {
        let side = event.wasLong ? "Long" : "Short"
        let text = """
        💥 \(event.asset) \(side) Liquidation
        Size: \(event.formattedSize)
        Wallet: \(event.shortAddress)

        via Hyperview https://hyperview.app
        """
        shareText(text)
    }
}
