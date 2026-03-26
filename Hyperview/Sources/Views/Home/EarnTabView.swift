import SwiftUI

struct EarnTabView: View {
    @ObservedObject var earnVM: EarnViewModel
    @State private var showPMDisabledAlert = false
    @State private var repayCoin: String? = nil
    @State private var supplyAsset: EarnAsset? = nil
    @State private var withdrawAsset: EarnAsset? = nil

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                headerCards

                if !filteredSupplyAssets.isEmpty {
                    supplySection
                }

                if !earnVM.borrowAssets.filter({ $0.userBorrowed > 0 }).isEmpty {
                    borrowSection
                }

                if earnVM.portfolioMarginEnabled {
                    pmRatioCard
                }
            }
            .padding(.top, 14)
            .padding(.bottom, 30)
        }
        .background(Color.hlBackground.ignoresSafeArea())
        .sheet(item: $supplyAsset) { asset in
            SupplyWithdrawSheet(
                action: .supply,
                initialTokenName: asset.coin,
                initialTokenIndex: asset.tokenIndex,
                initialAvailableBalance: WalletManager.shared.spotTokenAvailable[asset.coin] ?? 0,
                allEarnAssets: earnVM.supplyAssets,
                onSuccess: { Task { await earnVM.load() } }
            )
        }
        .sheet(item: $withdrawAsset) { asset in
            SupplyWithdrawSheet(
                action: .withdraw,
                initialTokenName: asset.coin,
                initialTokenIndex: asset.tokenIndex,
                initialAvailableBalance: asset.userSupplied,
                exactSuppliedString: asset.userSuppliedExact,
                onSuccess: { Task { await earnVM.load() } }
            )
        }
        .alert("Portfolio Margin", isPresented: $showPMDisabledAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("When portfolio margin is enabled, users automatically earn interest on assets not used for trading. Manual supplying and withdrawing is disabled.")
        }
        .sheet(isPresented: Binding(
            get: { repayCoin != nil },
            set: { if !$0 { repayCoin = nil } }
        )) {
            if let coin = repayCoin,
               let borrow = earnVM.borrowAssets.first(where: { $0.coin == coin }) {
                RepaySheet(
                    debtCoin: coin,
                    debtAmount: borrow.userBorrowed,
                    availableAssets: earnVM.pmBalanceEntries.filter { !$0.isBorrowed && $0.netBalance > 0 }
                )
            }
        }
    }

    // In classic mode, hide BTC/HYPE from supply (only stablecoins)
    private static let classicEarnTokens: Set<String> = ["USDC", "USDH", "USDT0", "USDE"]

    private var filteredSupplyAssets: [EarnAsset] {
        if earnVM.portfolioMarginEnabled {
            return earnVM.supplyAssets
        }
        return earnVM.supplyAssets.filter { Self.classicEarnTokens.contains($0.coin) }
    }

    private func displayCoin(_ coin: String) -> String {
        coin == "UBTC" ? "BTC" : coin
    }

    private func iconName(_ coin: String) -> String {
        if coin == "UBTC" { return "BTC" }
        return coin
    }

    // MARK: - Header Cards

    private var headerCards: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                headerCard(
                    title: "Your Total Supplied",
                    value: formatUSD(earnVM.totalSuppliedUSD),
                    color: .white
                )
                headerCard(
                    title: "Your Health Factor",
                    value: earnVM.totalBorrowedUSD > 0
                        ? String(format: "%.2f%%", earnVM.healthFactor)
                        : "--",
                    color: .white
                )
            }
            HStack(spacing: 10) {
                headerCard(
                    title: "Your Total Borrowed",
                    value: formatUSD(earnVM.totalBorrowedUSD),
                    color: .white
                )
                Spacer()
            }
        }
        .padding(.horizontal, 14)
    }

    private func headerCard(title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11))
                .foregroundColor(.gray)
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .monospaced))
                .foregroundColor(color)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(white: 0.09))
        )
    }

    // MARK: - Supply Section

    private var supplySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Supplied")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .padding(.bottom, 10)

            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 0) {
                        Text("Asset").frame(width: 70, alignment: .leading)
                        Text("LTV").frame(width: 40, alignment: .trailing)
                        Text("APY").frame(width: 45, alignment: .trailing)
                        Text("Oracle Price").frame(width: 75, alignment: .trailing)
                        Text("Your Supplied").frame(width: 105, alignment: .trailing)
                        Text("Interest Earned").frame(width: 95, alignment: .trailing)
                        Text("Total Supplied").frame(width: 125, alignment: .trailing)
                        Text("Action").frame(width: 110, alignment: .center)
                    }
                    .font(.system(size: 10))
                    .foregroundColor(Color(white: 0.45))
                    .padding(.horizontal, 14)
                    .padding(.bottom, 6)

                    ForEach(filteredSupplyAssets) { asset in
                        supplyRow(asset)
                    }
                }
            }
        }
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(white: 0.09))
        )
        .padding(.horizontal, 14)
    }

    private func supplyRow(_ asset: EarnAsset) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 5) {
                CoinIconView(symbol: displayCoin(asset.coin), hlIconName: iconName(asset.coin), iconSize: 16)
                Text(displayCoin(asset.coin))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
            }
            .frame(width: 70, alignment: .leading)

            Text(asset.ltv > 0 ? "\(Int(asset.ltv * 100))%" : "N/A")
                .font(.system(size: 11))
                .foregroundColor(.gray)
                .frame(width: 40, alignment: .trailing)

            Text(String(format: "%.2f%%", asset.apy * 100))
                .font(.system(size: 11))
                .foregroundColor(.hlGreen)
                .frame(width: 45, alignment: .trailing)

            Text(formatPrice(asset.oraclePrice))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.white)
                .frame(width: 75, alignment: .trailing)

            Text(asset.userSupplied > 0
                 ? formatTokenAmount(asset.userSupplied, coin: asset.coin)
                 : "0")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.gray)
                .frame(width: 105, alignment: .trailing)

            Text(asset.userInterestEarned > 0
                 ? formatTokenAmount(asset.userInterestEarned, coin: asset.coin)
                 : "0")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(asset.userInterestEarned > 0 ? .hlGreen : .gray)
                .frame(width: 95, alignment: .trailing)

            Text(asset.totalSupplied > 0
                 ? formatLargeTokenAmount(asset.totalSupplied, coin: asset.coin)
                 : "--")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.gray)
                .frame(width: 125, alignment: .trailing)

            // Supply / Withdraw buttons
            HStack(spacing: 6) {
                Button {
                    if earnVM.portfolioMarginEnabled {
                        showPMDisabledAlert = true
                    } else {
                        supplyAsset = asset
                    }
                } label: {
                    Text("Supply")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(earnVM.portfolioMarginEnabled ? Color(white: 0.35) : .hlGreen)
                }

                Button {
                    if earnVM.portfolioMarginEnabled {
                        showPMDisabledAlert = true
                    } else {
                        withdrawAsset = asset
                    }
                } label: {
                    Text("Withdraw")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(earnVM.portfolioMarginEnabled ? Color(white: 0.35) : .hlGreen)
                }
            }
            .frame(width: 110, alignment: .center)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    // MARK: - Borrow Section

    private var borrowSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Borrowed")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .padding(.bottom, 10)

            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 0) {
                        Text("Asset").frame(width: 70, alignment: .leading)
                        Text("APY").frame(width: 45, alignment: .trailing)
                        Text("Oracle Price").frame(width: 75, alignment: .trailing)
                        Text("Your Borrowed").frame(width: 105, alignment: .trailing)
                        Text("Interest Owed").frame(width: 95, alignment: .trailing)
                        Text("Total Borrowed").frame(width: 125, alignment: .trailing)
                        Text("Action").frame(width: 55, alignment: .center)
                    }
                    .font(.system(size: 10))
                    .foregroundColor(Color(white: 0.45))
                    .padding(.horizontal, 14)
                    .padding(.bottom, 6)

                    ForEach(earnVM.borrowAssets.filter({ $0.userBorrowed > 0 })) { asset in
                        borrowRow(asset)
                    }
                }
            }
        }
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(white: 0.09))
        )
        .padding(.horizontal, 14)
    }

    private func borrowRow(_ asset: BorrowAsset) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 5) {
                CoinIconView(symbol: asset.coin, hlIconName: asset.coin, iconSize: 16)
                Text(asset.coin)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
            }
            .frame(width: 70, alignment: .leading)

            Text(String(format: "%.2f%%", asset.apy * 100))
                .font(.system(size: 11))
                .foregroundColor(.tradingRed)
                .frame(width: 45, alignment: .trailing)

            Text(formatPrice(asset.oraclePrice))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.white)
                .frame(width: 75, alignment: .trailing)

            Text(formatTokenAmount(asset.userBorrowed, coin: asset.coin))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.gray)
                .frame(width: 105, alignment: .trailing)

            Text(asset.userInterestOwed > 0
                 ? formatTokenAmount(asset.userInterestOwed, coin: asset.coin)
                 : "0")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.tradingRed)
                .frame(width: 95, alignment: .trailing)

            Text(asset.totalBorrowed > 0
                 ? formatLargeTokenAmount(asset.totalBorrowed, coin: asset.coin)
                 : "--")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.gray)
                .frame(width: 125, alignment: .trailing)

            Button {
                repayCoin = asset.coin
            } label: {
                Text("Repay")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.hlGreen)
            }
            .frame(width: 55, alignment: .center)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    // MARK: - Portfolio Margin Ratio Card

    private var pmRatioCard: some View {
        HStack {
            Text("Portfolio Margin Ratio")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.gray)
            Spacer()
            Text(String(format: "%.2f%%", earnVM.portfolioMarginRatio * 100))
                .font(.system(size: 15, weight: .bold, design: .monospaced))
                .foregroundColor(
                    earnVM.portfolioMarginRatio < 0.5 ? .hlGreen :
                    earnVM.portfolioMarginRatio < 0.8 ? .orange : .tradingRed
                )
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(white: 0.09))
        )
        .padding(.horizontal, 14)
    }

    // MARK: - Formatters

    private func formatUSD(_ v: Double) -> String {
        if abs(v) < 0.01 { return "$0" }
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "USD"
        f.locale = Locale(identifier: "en_US")
        f.maximumFractionDigits = 2
        return f.string(from: NSNumber(value: v)) ?? "$\(v)"
    }

    private func formatPrice(_ p: Double) -> String {
        if p >= 10000 {
            let f = NumberFormatter()
            f.numberStyle = .decimal
            f.locale = Locale(identifier: "en_US")
            f.maximumFractionDigits = 0
            return "$\(f.string(from: NSNumber(value: p)) ?? "\(Int(p))")"
        }
        if p >= 1 { return String(format: "$%.2f", p) }
        return String(format: "$%.4f", p)
    }

    private func formatTokenAmount(_ amount: Double, coin: String) -> String {
        if amount == 0 { return "0" }
        let stables = ["USDC", "USDH", "USDT", "USDE"]
        let dc = coin == "UBTC" ? "BTC" : coin
        if stables.contains(coin) {
            return String(format: "%.2f %@", amount, dc)
        }
        if amount >= 1 {
            return String(format: "%.4f %@", amount, dc)
        }
        return String(format: "%.8f %@", amount, dc)
    }

    private func formatLargeTokenAmount(_ amount: Double, coin: String) -> String {
        let dc = coin == "UBTC" ? "BTC" : coin
        let stables = ["USDC", "USDH", "USDT", "USDE"]

        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US")

        if stables.contains(coin) {
            if amount >= 1_000_000_000 {
                return String(format: "%.2fB %@", amount / 1_000_000_000, dc)
            } else if amount >= 1_000_000 {
                f.maximumFractionDigits = 0
                return "\(f.string(from: NSNumber(value: amount)) ?? "\(Int(amount))") \(dc)"
            } else if amount >= 1_000 {
                f.maximumFractionDigits = 0
                return "\(f.string(from: NSNumber(value: amount)) ?? "\(Int(amount))") \(dc)"
            }
            return String(format: "%.2f %@", amount, dc)
        }
        if amount >= 1_000_000 {
            return String(format: "%.2fM %@", amount / 1_000_000, dc)
        } else if amount >= 1_000 {
            f.maximumFractionDigits = 0
            return "\(f.string(from: NSNumber(value: amount)) ?? "\(Int(amount))") \(dc)"
        }
        return String(format: "%.4f %@", amount, dc)
    }
}
