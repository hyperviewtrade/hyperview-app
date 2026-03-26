import SwiftUI

struct WatchlistView: View {
    @EnvironmentObject var watchVM:    WatchlistViewModel
    @EnvironmentObject var marketsVM:  MarketsViewModel
    @EnvironmentObject var chartVM:    ChartViewModel
    @State private var editMode       = EditMode.inactive

    var watchedMarkets: [Market] {
        watchVM.symbols.compactMap { sym in
            marketsVM.markets.first { $0.symbol == sym }
        }
    }


    var body: some View {
        Group {
            if watchVM.symbols.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(watchedMarkets) { market in
                        watchRow(market)
                            .listRowBackground(Color.clear)
                            .listRowSeparatorTint(Color.hlSurface)
                    }
                    .onDelete { watchVM.remove(at: $0) }
                    .onMove  { watchVM.move(from: $0, to: $1) }
                }
                .listStyle(.plain)
                .environment(\.editMode, $editMode)
                .refreshable { marketsVM.refresh() }
            }
        }
        .background(Color.hlBackground)
        .navigationTitle("Watchlist")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(editMode == .active ? "Done" : "Edit") {
                    withAnimation { editMode = editMode == .active ? .inactive : .active }
                }
                .tint(.hlGreen)
            }
        }
        .task { if marketsVM.markets.isEmpty { await marketsVM.loadMarkets() } }
    }

    // MARK: - Row

    private func watchRow(_ market: Market) -> some View {
        Button {
            AppState.shared.openChart(
                symbol: market.symbol,
                displayName: market.isSpot ? market.spotDisplayPairName : market.displayName,
                perpEquivalent: market.perpEquivalent,
                chartVM: chartVM)
        } label: {
            HStack(spacing: 12) {
                // Mini sparkline area (placeholder colored block)
                RoundedRectangle(cornerRadius: 4)
                    .fill(market.isPositive ? Color.hlGreen.opacity(0.15) : Color.tradingRed.opacity(0.15))
                    .frame(width: 50, height: 30)
                    .overlay(
                        Image(systemName: market.isPositive ? "chart.line.uptrend.xyaxis" : "chart.line.downtrend.xyaxis")
                            .font(.system(size: 14))
                            .foregroundColor(market.isPositive ? .hlGreen : .tradingRed)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(market.displaySymbol)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                    Text("Vol \(market.formattedVolume)")
                        .font(.system(size: 11))
                        .foregroundColor(.gray)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    Text(market.formattedPrice)
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white)
                    Text(String(format: "%@%.2f%%", market.isPositive ? "+" : "", market.change24h))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(market.isPositive ? .hlGreen : .tradingRed)
                }
            }
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "star.slash")
                .font(.system(size: 48))
                .foregroundColor(Color(white: 0.3))
            Text("Watchlist Empty")
                .font(.title3)
                .foregroundColor(.white)
            Text("Tap ★ on any market to add it here.")
                .font(.system(size: 14))
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
