import SwiftUI

struct EarnView: View {
    @StateObject private var vm = EarnViewModel()

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                // Header stats
                statsRow

                // Supply section
                supplySection

                // Borrow section
                borrowSection
            }
            .padding(14)
        }
        .background(Color.hlBackground.ignoresSafeArea())
        .task(id: WalletManager.shared.connectedWallet?.address) {
            await vm.load()
        }
        .refreshable {
            await vm.load()
        }
    }

    // MARK: - Header Stats

    private var statsRow: some View {
        HStack(spacing: 10) {
            statCard(
                title: "Your Health Factor",
                value: vm.healthFactor > 0
                    ? String(format: "%.2f%%", vm.healthFactor)
                    : "--",
                color: healthColor
            )
            statCard(
                title: "Your Total Supplied",
                value: formatUSD(vm.totalSuppliedUSD),
                color: .white
            )
            statCard(
                title: "Your Total Borrowed",
                value: formatUSD(vm.totalBorrowedUSD),
                color: .white
            )
        }
    }

    private var healthColor: Color {
        if vm.healthFactor <= 0 { return .gray }
        if vm.healthFactor < 110 { return .tradingRed }
        if vm.healthFactor < 150 { return .orange }
        return .hlGreen
    }

    private func statCard(title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11))
                .foregroundColor(.gray)
            Text(value)
                .font(.system(size: 17, weight: .bold, design: .monospaced))
                .foregroundColor(color)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(white: 0.11))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color(white: 0.18), lineWidth: 0.5)
                )
        )
    }

    // MARK: - Supply Section

    private var supplySection: some View {
        VStack(spacing: 0) {
            // Section header
            sectionHeader("Supplied")

            // Column headers
            supplyColumnHeaders

            // Rows
            if vm.supplyAssets.isEmpty && !vm.isLoading {
                emptyRow("No supply positions")
            } else {
                ForEach(vm.supplyAssets) { asset in
                    supplyRow(asset)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(white: 0.09))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(white: 0.15), lineWidth: 0.5)
        )
    }

    private var supplyColumnHeaders: some View {
        HStack(spacing: 0) {
            Text("Asset")
                .frame(width: 60, alignment: .leading)
            Text("LTV")
                .frame(width: 52, alignment: .trailing)
            Text("APY")
                .frame(width: 50, alignment: .trailing)
            Text("Oracle Price")
                .frame(maxWidth: .infinity, alignment: .trailing)
            Text("Your Supplied")
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundColor(.gray)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(white: 0.07))
    }

    private func supplyRow(_ asset: EarnAsset) -> some View {
        let dc = asset.coin == "UBTC" ? "BTC" : asset.coin
        let ic = asset.coin == "UBTC" ? "BTC" : asset.coin
        return HStack(spacing: 0) {
            HStack(spacing: 4) {
                CoinIconView(symbol: dc, hlIconName: ic, iconSize: 16)
                Text(dc)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
            }
            .frame(width: 60, alignment: .leading)

            Text(asset.ltv > 0 ? String(format: "%.0f%%", asset.ltv * 100) : "N/A")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(asset.ltv > 0 ? .white : .gray)
                .frame(width: 52, alignment: .trailing)

            Text(String(format: "%.2f%%", asset.apy * 100))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.hlGreen)
                .frame(width: 50, alignment: .trailing)

            Text(formatPrice(asset.oraclePrice))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity, alignment: .trailing)

            VStack(alignment: .trailing, spacing: 1) {
                Text(formatTokenAmount(asset.userSupplied, coin: asset.coin))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(white: 0.09))
    }

    // MARK: - Borrow Section

    private var borrowSection: some View {
        VStack(spacing: 0) {
            sectionHeader("Borrowed")

            borrowColumnHeaders

            if vm.borrowAssets.isEmpty && !vm.isLoading {
                emptyRow("No borrow positions")
            } else {
                ForEach(vm.borrowAssets) { asset in
                    borrowRow(asset)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(white: 0.09))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(white: 0.15), lineWidth: 0.5)
        )
    }

    private var borrowColumnHeaders: some View {
        HStack(spacing: 0) {
            Text("Asset")
                .frame(width: 60, alignment: .leading)
            Text("LTV")
                .frame(width: 52, alignment: .trailing)
            Text("APY")
                .frame(width: 50, alignment: .trailing)
            Text("Oracle Price")
                .frame(maxWidth: .infinity, alignment: .trailing)
            Text("Your Borrowed")
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundColor(.gray)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(white: 0.07))
    }

    private func borrowRow(_ asset: BorrowAsset) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 4) {
                CoinIconView(symbol: asset.coin, hlIconName: asset.coin, iconSize: 16)
                Text(asset.coin)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
            }
            .frame(width: 60, alignment: .leading)

            Text("--")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.gray)
                .frame(width: 52, alignment: .trailing)

            Text(String(format: "%.2f%%", asset.apy * 100))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.tradingRed)
                .frame(width: 50, alignment: .trailing)

            Text(formatPrice(asset.oraclePrice))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity, alignment: .trailing)

            VStack(alignment: .trailing, spacing: 1) {
                Text(formatTokenAmount(asset.userBorrowed, coin: asset.coin))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(white: 0.09))
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.white)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundColor(.gray)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
    }

    private func formatUSD(_ value: Double) -> String {
        if value == 0 { return "$0.00" }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.locale = Locale(identifier: "en_US")
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? "$0.00"
    }

    private func formatPrice(_ price: Double) -> String {
        if price >= 10000 {
            return String(format: "$%.0f", price)
        } else if price >= 1 {
            return String(format: "$%.2f", price)
        } else {
            return String(format: "$%.4f", price)
        }
    }

    private func formatTokenAmount(_ amount: Double, coin: String) -> String {
        let dc = coin == "UBTC" ? "BTC" : coin
        if amount == 0 { return "0 \(dc)" }
        let stables = ["USDC", "USDH", "USDT", "USDE"]
        if stables.contains(coin) {
            return String(format: "%.2f %@", amount, dc)
        }
        if coin == "UBTC" {
            return String(format: "%.5f %@", amount, dc)
        }
        return String(format: "%.4f %@", amount, dc)
    }
}
