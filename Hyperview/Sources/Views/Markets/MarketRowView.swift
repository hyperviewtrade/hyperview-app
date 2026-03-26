import SwiftUI

struct MarketRowView: View {
    let market: Market
    let livePrice: Double?          // passé depuis MarketsView (dict léger)
    @EnvironmentObject var watchVM: WatchlistViewModel

    private var displayPrice: Double { livePrice ?? market.price }
    private var displayPriceFmt: String { market.format(displayPrice) }

    /// Change % computed from daily candle open (TradingView style) using live price.
    private var liveChange: Double {
        if let open = market.dailyOpenPrice, open > 0 {
            return ((displayPrice - open) / open) * 100
        }
        return market.change24h
    }
    private var isPositive: Bool { liveChange >= 0 }

    var body: some View {
        HStack(spacing: 0) {
            // Star
            Button { watchVM.toggle(market.symbol) } label: {
                Image(systemName: watchVM.isWatched(market.symbol) ? "star.fill" : "star")
                    .foregroundColor(watchVM.isWatched(market.symbol) ? .hlGreen : Color(white: 0.35))
                    .font(.system(size: 13))
                    .frame(width: 32)
            }
            .buttonStyle(.plain)

            // Icône + Symbol + volume + OI
            HStack(spacing: 8) {
                CoinIconView(symbol: market.spotDisplayBaseName, hlIconName: market.hlCoinIconName)
                VStack(alignment: .leading, spacing: 2) {
                    Text(market.isSpot ? "\(market.spotDisplayPairName)  SPOT" : market.displaySymbol)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                    HStack(spacing: 6) {
                        Text("Vol \(market.formattedVolume)")
                        if !market.isSpot && market.openInterest > 0 {
                            Text("OI \(market.formattedOI)")
                                .foregroundColor(Color(white: 0.35))
                        }
                    }
                    .font(.system(size: 10))
                    .foregroundColor(Color(white: 0.4))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Prix live
            Text(displayPriceFmt)
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundColor(.white)
                .frame(width: 90, alignment: .trailing)
                .contentTransition(.numericText())
                .animation(.easeInOut(duration: 0.3), value: displayPriceFmt)

            // Change badge
            Text(changeBadge)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(isPositive ? .hlGreen : .white)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(isPositive ? Color.hlButtonBg : Color.tradingRed)
                .cornerRadius(5)
                .frame(width: 76, alignment: .trailing)
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 4)
    }

    private var changeBadge: String {
        String(format: "%@%.2f%%", isPositive ? "+" : "", liveChange)
    }
}
