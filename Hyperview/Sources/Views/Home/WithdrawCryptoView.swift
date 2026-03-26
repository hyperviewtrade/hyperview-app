import SwiftUI

// MARK: - Withdraw asset descriptor

struct WithdrawAssetInfo: Identifiable {
    let id = UUID()
    let name: String
    let network: String
    let minWithdraw: String
    let fee: String
    let estimatedTime: String
    /// "withdraw3" for USDC, "spotSend" for spot tokens via UNIT bridge
    let method: WithdrawMethod

    enum WithdrawMethod {
        case withdraw3           // USDC L1 → Arbitrum
        case unitBridge(String)  // spot token → UNIT generates HL intermediate address
    }
}

// MARK: - WithdrawCryptoView

struct WithdrawCryptoView: View {
    @Environment(\.dismiss) private var dismiss

    private let assets: [WithdrawAssetInfo] = [
        .init(name: "BTC",      network: "Bitcoin",     minWithdraw: "0.0005", fee: "~$2",    estimatedTime: "~30 min", method: .unitBridge("bitcoin")),
        .init(name: "HYPE",     network: "Hyperliquid", minWithdraw: "1",      fee: "~$0.01", estimatedTime: "~1 min",  method: .unitBridge("hyperliquid")),
        .init(name: "ETH",      network: "Ethereum",    minWithdraw: "0.01",   fee: "~$5",    estimatedTime: "~15 min", method: .unitBridge("ethereum")),
        .init(name: "SOL",      network: "Solana",      minWithdraw: "0.2",    fee: "~$0.5",  estimatedTime: "~2 min",  method: .unitBridge("solana")),
        .init(name: "ZEC",      network: "Zcash",       minWithdraw: "0.05",   fee: "~$1",    estimatedTime: "~30 min", method: .unitBridge("zcash")),
        .init(name: "PUMP",     network: "Solana",      minWithdraw: "10",     fee: "~$0.5",  estimatedTime: "~2 min",  method: .unitBridge("solana")),
        .init(name: "USDC",     network: "Arbitrum",    minWithdraw: "5",      fee: "$1",     estimatedTime: "~5 min",  method: .withdraw3),
        .init(name: "USDH",     network: "Hyperliquid", minWithdraw: "5",      fee: "~$0.01", estimatedTime: "~1 min",  method: .unitBridge("hyperliquid")),
        .init(name: "2Z",       network: "Solana",      minWithdraw: "10",     fee: "~$0.5",  estimatedTime: "~2 min",  method: .unitBridge("solana")),
        .init(name: "BONK",     network: "Solana",      minWithdraw: "50000",  fee: "~$0.5",  estimatedTime: "~2 min",  method: .unitBridge("solana")),
        .init(name: "ENA",      network: "Ethereum",    minWithdraw: "5",      fee: "~$5",    estimatedTime: "~15 min", method: .unitBridge("ethereum")),
        .init(name: "FARTCOIN", network: "Solana",      minWithdraw: "5",      fee: "~$0.5",  estimatedTime: "~2 min",  method: .unitBridge("solana")),
        .init(name: "MON",      network: "Ethereum",    minWithdraw: "1",      fee: "~$5",    estimatedTime: "~15 min", method: .unitBridge("ethereum")),
        .init(name: "PURR",     network: "Hyperliquid", minWithdraw: "100",    fee: "~$0.01", estimatedTime: "~1 min",  method: .unitBridge("hyperliquid")),
        .init(name: "SPX",      network: "Ethereum",    minWithdraw: "100",    fee: "~$5",    estimatedTime: "~15 min", method: .unitBridge("ethereum")),
        .init(name: "XPL",      network: "Solana",      minWithdraw: "10",     fee: "~$0.5",  estimatedTime: "~2 min",  method: .unitBridge("solana")),
    ]

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                ForEach(assets) { asset in
                    NavigationLink {
                        WithdrawAssetView(asset: asset)
                    } label: {
                        assetRow(asset)
                    }
                }
            }
            .padding(.top, 4)
        }
        .background(Color.hlBackground.ignoresSafeArea())
        .navigationTitle("Withdraw Crypto")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel") { dismiss() }
                    .foregroundColor(.hlGreen)
            }
        }
    }

    private func assetRow(_ asset: WithdrawAssetInfo) -> some View {
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
                Text("Fee: \(asset.fee)")
                    .font(.system(size: 12))
                    .foregroundColor(Color(white: 0.5))
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
