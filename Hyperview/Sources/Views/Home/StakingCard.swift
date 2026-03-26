import SwiftUI

struct StakingCard: View {
    let event: StakingEvent

    var body: some View {
        CardContainer(borderColor: Color.purple.opacity(0.25)) {
            VStack(alignment: .leading, spacing: 12) {

                // ── Header ──────────────────────────────────────────
                HStack(spacing: 8) {
                    Text("🔐").font(.system(size: 20))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(event.isStaking ? "Staking Event" : "Unstaking Event")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                        Text(relativeTime(event.timestamp))
                            .font(.system(size: 11))
                            .foregroundColor(.gray)
                    }
                    Spacer()
                    Text(event.isStaking ? "STAKE" : "UNSTAKE")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(event.isStaking ? .hlGreen : .orange)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background((event.isStaking ? Color.hlGreen : Color.orange).opacity(0.15))
                        .cornerRadius(6)
                }

                // ── Stats ────────────────────────────────────────────
                HStack(alignment: .top, spacing: 0) {
                    StatCell(label: "Amount",
                             value: event.formattedAmount,
                             valueColor: .white, large: true)
                    Spacer()
                    StatCell(label: "USD Value",
                             value: event.formattedUSD,
                             valueColor: .hlGreen)
                    Spacer()
                    if let remaining = event.remainingUnstakingTime {
                        StatCell(label: "Unlocks in", value: remaining, valueColor: .orange)
                    }
                }

                Divider().background(Color.hlDivider)

                // ── Footer ───────────────────────────────────────────
                HStack {
                    Text(event.shortAddress)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.gray)
                    Spacer()
                    ShareButton { shareStaking() }
                }
            }
        }
    }

    private func shareStaking() {
        let action = event.isStaking ? "staked" : "unstaked"
        let unlock = event.remainingUnstakingTime.map { "\nUnlocks: \($0)" } ?? ""
        let text = """
        🔐 \(event.shortAddress) just \(action) \(event.formattedAmount)
        USD Value: \(event.formattedUSD)\(unlock)

        via Hyperview https://hyperview.app
        """
        shareText(text)
    }
}
