import SwiftUI

struct WalletMoreTab: View {
    let address: String

    @State private var isLoading = true

    // Referral state
    @State private var referralCode: String?
    @State private var referredBy: String?
    @State private var referredByCode: String?
    @State private var cumVolume: Double = 0

    // Fee state
    @State private var perpTaker: String = "—"
    @State private var perpMaker: String = "—"
    @State private var spotTaker: String = "—"
    @State private var spotMaker: String = "—"
    @State private var referralDiscount: String?
    @State private var stakingDiscount: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if isLoading {
                    ProgressView().tint(.hlGreen)
                        .frame(maxWidth: .infinity, minHeight: 200)
                } else {
                    // ── Referrals ──
                    sectionCard {
                        VStack(spacing: 14) {
                            Text("Referrals")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)

                            VStack(alignment: .leading, spacing: 8) {
                                if let code = referralCode {
                                    infoRow(label: "Referral Code", value: code, valueColor: .hlGreen)
                                } else {
                                    infoRow(label: "Referral Code", value: "None", valueColor: Color(white: 0.4))
                                }

                                if let by = referredByCode {
                                    infoRow(label: "Referred By", value: by, valueColor: .hlGreen)
                                    if let addr = referredBy {
                                        Text(shortAddr(addr))
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundColor(Color(white: 0.35))
                                            .frame(maxWidth: .infinity, alignment: .trailing)
                                    }
                                } else {
                                    infoRow(label: "Referred By", value: "None", valueColor: Color(white: 0.4))
                                }

                                if cumVolume > 0 {
                                    infoRow(label: "Cumulative Volume", value: formatLargeNumber(cumVolume))
                                }
                            }
                        }
                    }

                    // ── Fees ──
                    sectionCard {
                        VStack(spacing: 14) {
                            Text("Fees (Taker / Maker)")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)

                            VStack(alignment: .leading, spacing: 8) {
                                feeRow(label: "Perps", taker: perpTaker, maker: perpMaker)
                                feeRow(label: "Spot", taker: spotTaker, maker: spotMaker)
                            }

                            if referralDiscount != nil || stakingDiscount != nil {
                                Divider().background(Color(white: 0.15))

                                VStack(alignment: .leading, spacing: 6) {
                                    if let rd = referralDiscount {
                                        discountRow(icon: "person.2.fill", label: "Referral Discount", value: rd)
                                    }
                                    if let sd = stakingDiscount {
                                        discountRow(icon: "lock.shield.fill", label: "Staking Discount", value: sd)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 20)
        }
        .task { await fetchData() }
    }

    // MARK: - Data fetching

    private func fetchData() async {
        let apiURL = URL(string: "https://api.hyperliquid.xyz/info")!

        // Fetch referral + fees in parallel
        async let referralTask: Void = fetchReferral(apiURL: apiURL)
        async let feesTask: Void = fetchFees(apiURL: apiURL)
        _ = await (referralTask, feesTask)

        isLoading = false
    }

    private func fetchReferral(apiURL: URL) async {
        let body: [String: Any] = ["type": "referral", "user": address]
        guard let data = try? await HyperliquidAPI.shared.post(url: apiURL, body: body),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        // Cumulative volume
        if let vlmStr = json["cumVlm"] as? String, let vlm = Double(vlmStr) {
            cumVolume = vlm
        }

        // Referred by
        if let rb = json["referredBy"] as? [String: Any] {
            referredBy = rb["referrer"] as? String
            referredByCode = rb["code"] as? String
        }

        // Referrer state (user's own code)
        if let rs = json["referrerState"] as? [String: Any],
           let data = rs["data"] as? [String: Any],
           let code = data["code"] as? String {
            referralCode = code
        }
    }

    private func fetchFees(apiURL: URL) async {
        let body: [String: Any] = ["type": "userFees", "user": address]
        guard let data = try? await HyperliquidAPI.shared.post(url: apiURL, body: body),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        // Applied fee rates
        if let rate = json["userCrossRate"] as? String, let val = Double(rate) {
            perpTaker = formatPercent(val)
        }
        if let rate = json["userAddRate"] as? String, let val = Double(rate) {
            perpMaker = formatPercent(val)
        }
        if let rate = json["userSpotCrossRate"] as? String, let val = Double(rate) {
            spotTaker = formatPercent(val)
        }
        if let rate = json["userSpotAddRate"] as? String, let val = Double(rate) {
            spotMaker = formatPercent(val)
        }

        // Discounts
        if let rd = json["activeReferralDiscount"] as? String, let val = Double(rd), val > 0 {
            referralDiscount = formatPercent(val)
        }
        if let sd = json["activeStakingDiscount"] as? String, let val = Double(sd), val > 0 {
            stakingDiscount = formatPercent(val)
        }
    }

    // MARK: - UI Helpers

    private func sectionCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(16)
            .background(Color(white: 0.09))
            .cornerRadius(14)
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color(white: 0.15), lineWidth: 1)
            )
    }

    private func infoRow(label: String, value: String, valueColor: Color = .white) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
                .foregroundColor(Color(white: 0.5))
            Spacer()
            Text(value)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(valueColor)
        }
    }

    private func feeRow(label: String, taker: String, maker: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(Color(white: 0.5))
                .frame(width: 50, alignment: .leading)
            Spacer()
            Text(taker)
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundColor(.white)
            Text("/")
                .font(.system(size: 12))
                .foregroundColor(Color(white: 0.3))
            Text(maker)
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundColor(.hlGreen)
        }
    }

    private func discountRow(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(.hlGreen)
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(Color(white: 0.5))
            Spacer()
            Text("-\(value)")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.hlGreen)
        }
    }

    private func shortAddr(_ addr: String) -> String {
        guard addr.count > 12 else { return addr }
        return "\(addr.prefix(6))…\(addr.suffix(4))"
    }

    private func formatPercent(_ val: Double) -> String {
        // API returns rate as decimal (0.00045 = 0.045%)
        let pct = val * 100
        if pct == 0 { return "0%" }
        // Show enough decimals
        let formatted = String(format: "%g%%", (pct * 1000).rounded() / 1000)
        return formatted
    }

    private func formatLargeNumber(_ v: Double) -> String {
        if v >= 1_000_000_000 { return String(format: "$%.1fB", v / 1_000_000_000) }
        if v >= 1_000_000     { return String(format: "$%.1fM", v / 1_000_000) }
        if v >= 1_000         { return String(format: "$%.0fK", v / 1_000) }
        return String(format: "$%.0f", v)
    }
}
