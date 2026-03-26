import SwiftUI

// MARK: - Supported deposit asset

struct DepositAsset: Identifiable {
    let id = UUID()
    let name: String
    let network: String
    let minDeposit: String
    let estimatedTime: String
    let estimatedFee: String      // e.g. "~$0.50" — charged by Unit, not Hyperview
    /// Nil = fetch from UNIT API; non-nil = fixed bridge address
    let fixedAddress: String?

    /// Source chain identifier for UNIT API (e.g. "bitcoin", "ethereum", "solana")
    var unitSrcChain: String? {
        switch network.lowercased() {
        case "bitcoin":      return "bitcoin"
        case "ethereum":     return "ethereum"
        case "solana":       return "solana"
        case "plasma":       return "plasma"
        case "monad":        return "monad"
        case "zcash":        return "zcash"
        case "arbitrum":     return "arbitrum"
        default:             return nil
        }
    }

    /// Asset identifier for UNIT API
    var unitAsset: String { name.lowercased() }
}

// MARK: - DepositCryptoView

struct DepositCryptoView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var searchQuery = ""

    private let assets: [DepositAsset] = [
        .init(name: "BTC",      network: "Bitcoin",       minDeposit: "0.0003",  estimatedTime: "~30 min", estimatedFee: "~$2.50",  fixedAddress: nil),
        .init(name: "HYPE",     network: "Hyperliquid",   minDeposit: "1",       estimatedTime: "~1 min",  estimatedFee: "Free",    fixedAddress: nil),
        .init(name: "ETH",      network: "Ethereum",      minDeposit: "0.007",   estimatedTime: "~15 min", estimatedFee: "~$1.50",  fixedAddress: nil),
        .init(name: "SOL",      network: "Solana",        minDeposit: "0.12",    estimatedTime: "~2 min",  estimatedFee: "~$0.10",  fixedAddress: nil),
        .init(name: "ZEC",      network: "Zcash",         minDeposit: "0.05",    estimatedTime: "~30 min", estimatedFee: "~$1.30",  fixedAddress: nil),
        .init(name: "PUMP",     network: "Solana",        minDeposit: "10",      estimatedTime: "~2 min",  estimatedFee: "~$0.10",  fixedAddress: nil),
        .init(name: "USDC",     network: "Arbitrum",      minDeposit: "5",       estimatedTime: "~2 min",  estimatedFee: "~$0.10",
              fixedAddress: "0x2Df1c51E09aECF9cacB7bc98cB1742757f163dF7"),
        .init(name: "USDH",     network: "Hyperliquid",   minDeposit: "5",       estimatedTime: "~1 min",  estimatedFee: "Free",    fixedAddress: nil),
        .init(name: "2Z",       network: "Solana",        minDeposit: "10",      estimatedTime: "~2 min",  estimatedFee: "~$0.10",  fixedAddress: nil),
        .init(name: "BONK",     network: "Solana",        minDeposit: "50000",   estimatedTime: "~2 min",  estimatedFee: "~$0.10",  fixedAddress: nil),
        .init(name: "ENA",      network: "Ethereum",      minDeposit: "5",       estimatedTime: "~15 min", estimatedFee: "~$1.50",  fixedAddress: nil),
        .init(name: "FARTCOIN", network: "Solana",        minDeposit: "5",       estimatedTime: "~2 min",  estimatedFee: "~$0.10",  fixedAddress: nil),
        .init(name: "MON",      network: "Ethereum",      minDeposit: "1",       estimatedTime: "~15 min", estimatedFee: "~$1.50",  fixedAddress: nil),
        .init(name: "PURR",     network: "Hyperliquid",   minDeposit: "100",     estimatedTime: "~1 min",  estimatedFee: "Free",    fixedAddress: nil),
        .init(name: "SPX",      network: "Ethereum",      minDeposit: "100",     estimatedTime: "~15 min", estimatedFee: "~$1.50",  fixedAddress: nil),
        .init(name: "XPL",      network: "Solana",        minDeposit: "10",      estimatedTime: "~2 min",  estimatedFee: "~$0.10",  fixedAddress: nil),
    ]

    private var filtered: [DepositAsset] {
        guard !searchQuery.isEmpty else { return assets }
        return assets.filter {
            $0.name.localizedCaseInsensitiveContains(searchQuery) ||
            $0.network.localizedCaseInsensitiveContains(searchQuery)
        }
    }

    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Search bar
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(Color(white: 0.4))
                TextField("Search asset", text: $searchQuery)
                    .font(.system(size: 15))
                    .foregroundColor(.white)
                    .focused($isSearchFocused)
            }
            .padding(10)
            .background(Color.hlSurface)
            .cornerRadius(10)
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded { isSearchFocused = true })
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider().background(Color.hlSurface)

            // Asset list
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(filtered) { asset in
                        NavigationLink {
                            DepositAddressView(asset: asset)
                        } label: {
                            assetRow(asset)
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
        .background(Color.hlBackground.ignoresSafeArea())
        .keyboardDoneBar()
        .navigationTitle("Deposit Crypto")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel") { dismiss() }
                    .foregroundColor(.hlGreen)
            }
        }
    }

    private func assetRow(_ asset: DepositAsset) -> some View {
        HStack(spacing: 12) {
            CoinIconView(symbol: asset.name, hlIconName: asset.name)

            VStack(alignment: .leading, spacing: 2) {
                Text(asset.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                Text(asset.network)
                    .font(.system(size: 12))
                    .foregroundColor(Color(white: 0.5))
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text("Min: \(asset.minDeposit)")
                    .font(.system(size: 12))
                    .foregroundColor(Color(white: 0.5))
                Text("Fee: \(asset.estimatedFee)")
                    .font(.system(size: 11))
                    .foregroundColor(asset.estimatedFee == "Free" ? .hlGreen : Color(white: 0.4))
                Text(asset.estimatedTime)
                    .font(.system(size: 11))
                    .foregroundColor(Color(white: 0.4))
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Color(white: 0.3))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.hlCardBackground)
    }

}
