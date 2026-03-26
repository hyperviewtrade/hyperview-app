import SwiftUI

struct ChartContainerView: View {
    @EnvironmentObject var chartVM:    ChartViewModel
    @EnvironmentObject var tradingVM:  TradingViewModel
    @EnvironmentObject var watchVM:    WatchlistViewModel
    @EnvironmentObject var marketsVM:  MarketsViewModel

    @State private var showPicker = false
    @State private var tab: ChartTab = .chart

    enum ChartTab: String, CaseIterable {
        case chart   = "Chart"
        case trade   = "Trade"
        case book    = "Order Book"
    }


    var body: some View {
        VStack(spacing: 0) {
            // ── Top bar ───────────────────────────────────────
            topBar

            // ── Price strip ───────────────────────────────────
            if !chartVM.isCustomTVChart {
                priceStrip
            }

            // ── Tab strip ─────────────────────────────────────
            tabStrip

            // ── Content ───────────────────────────────────────
            // Use ZStack + opacity so the TradingView WKWebView stays alive
            // when switching to Trade/Book tabs (avoids expensive chart reload).
            ZStack {
                chartContent
                    .opacity(tab == .chart ? 1 : 0)
                    .allowsHitTesting(tab == .chart)

                if tab == .trade {
                    tradeContent
                }
                if tab == .book {
                    bookContent
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.hlBackground)
        .navigationBarHidden(true)
        .sheet(isPresented: $showPicker) {
            SymbolPickerView()
                .environmentObject(chartVM)
                .environmentObject(marketsVM)
        }
        .task {
            if chartVM.candles.isEmpty && !chartVM.isCustomTVChart {
                await chartVM.loadChart(
                    symbol: chartVM.selectedSymbol,
                    interval: chartVM.selectedInterval
                )
            }
        }
        .onChange(of: chartVM.isCustomTVChart) { _, isCustom in
            if isCustom && tab != .chart { tab = .chart }
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 12) {
            // Symbol button — show displayName (strips "xyz:" prefix for HIP-3)
            Button { showPicker = true } label: {
                HStack(spacing: 5) {
                    Text(chartVM.displayName)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.white)
                    Text(chartVM.isCustomTVChart ? "TV" : chartVM.marketTypeBadge)
                        .font(.system(size: 11))
                        .foregroundColor(chartVM.isCustomTVChart ? .blue : .gray)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.hlGreen)
                }
            }

            Spacer()

            // Star
            Button { watchVM.toggle(chartVM.selectedSymbol) } label: {
                Image(systemName: watchVM.isWatched(chartVM.selectedSymbol) ? "star.fill" : "star")
                    .foregroundColor(watchVM.isWatched(chartVM.selectedSymbol) ? .hlGreen : Color(white: 0.5))
                    .font(.system(size: 17))
            }

            // Reload
            Button {
                Task {
                    await chartVM.loadChart(
                        symbol: chartVM.selectedSymbol,
                        interval: chartVM.selectedInterval
                    )
                }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .foregroundColor(Color(white: 0.5))
                    .font(.system(size: 15))
            }
            .disabled(chartVM.isLoading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Price strip

    private var priceStrip: some View {
        let lastPrice = chartVM.livePrice
        let candles   = chartVM.candles
        let periodChange: Double = {
            guard let last = candles.last, last.open != 0 else { return 0 }
            return ((last.close - last.open) / last.open) * 100
        }()
        let isPos = periodChange >= 0
        let priceColor = candles.last.map { $0.isGreen ? Color.hlGreen : Color.tradingRed } ?? .white

        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(formatPrice(lastPrice))
                .font(.system(size: 28, weight: .bold, design: .monospaced))
                .foregroundColor(priceColor)
                .contentTransition(.numericText())
                .animation(.easeInOut(duration: 0.15), value: lastPrice)

            VStack(alignment: .leading, spacing: 1) {
                Text(String(format: "%@%.2f%%", isPos ? "+" : "", periodChange))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(isPos ? .hlGreen : .tradingRed)
                Text(chartVM.selectedInterval.rawValue)
                    .font(.system(size: 10))
                    .foregroundColor(.gray)
            }

            Spacer()

            periodVolumeInfo
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    /// Volume summed over a period matching the selected timeframe
    private var periodVolumeInfo: some View {
        let candles = chartVM.candles
        let interval = chartVM.selectedInterval

        // Window = one candle duration, label = timeframe name
        let windowSec = interval.durationSeconds
        let label = "\(interval.rawValue) Vol"

        // Sum volume of candles within the window
        let cutoff = Date().timeIntervalSince1970 - Double(windowSec)
        let vol = candles
            .filter { Double($0.t) / 1000 >= cutoff }
            .reduce(0.0) { $0 + $1.volume * $1.close }

        return VStack(alignment: .trailing, spacing: 1) {
            Text(formatVolume(vol))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.white)
            Text(label)
                .font(.system(size: 9))
                .foregroundColor(.gray)
        }
    }

    // MARK: - Tab strip

    private var tabStrip: some View {
        HStack(spacing: 0) {
            ForEach(ChartTab.allCases, id: \.self) { t in
                let isDisabled = chartVM.isCustomTVChart && (t == .trade || t == .book)
                Button {
                    guard !isDisabled else { return }
                    tab = t
                    if t == .book { Task { await chartVM.refreshOrderBook() } }
                    if t == .trade { tradingVM.syncSymbol(from: chartVM) }
                } label: {
                    Text(t.rawValue)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(isDisabled ? Color(white: 0.2) : (tab == t ? .hlGreen : Color(white: 0.45)))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .overlay(
                            Rectangle()
                                .frame(height: 2)
                                .foregroundColor(tab == t ? .hlGreen : .clear),
                            alignment: .bottom
                        )
                }
                .disabled(isDisabled)
            }
        }
        .background(Color.hlCardBackground)
    }

    // MARK: - Chart content

    @ViewBuilder
    private var chartContent: some View {
        VStack(spacing: 0) {
            TradingViewChartView()
                .environmentObject(chartVM)

            // Long / Short quick-trade buttons (only for tradable HL markets)
            if !chartVM.isCustomTVChart {
                longShortButtons
            }
        }
    }

    /// Compact Long / Short (perp) or Buy / Sell (spot) buttons pinned below the chart
    private var longShortButtons: some View {
        HStack(spacing: 10) {
            Button {
                tradingVM.syncSymbol(from: chartVM)
                tradingVM.side = .buy
                withAnimation(.easeInOut(duration: 0.2)) { tab = .trade }
            } label: {
                Text(chartVM.isSpotMarket ? "Buy" : "Long")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.hlGreen)
                    .cornerRadius(8)
            }

            Button {
                tradingVM.syncSymbol(from: chartVM)
                tradingVM.side = .sell
                withAnimation(.easeInOut(duration: 0.2)) { tab = .trade }
            } label: {
                Text(chartVM.isSpotMarket ? "Sell" : "Short")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.tradingRed)
                    .cornerRadius(8)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color.hlBackground)
    }

    // MARK: - Order book content

    @ViewBuilder
    private var bookContent: some View {
        if let book = chartVM.orderBook {
            OrderBookView(orderBook: book, onPriceTap: { tappedPrice in
                // Pre-fill the trade form with the tapped price and switch to Trade tab
                tradingVM.syncSymbol(from: chartVM)
                tradingVM.orderType = .limit
                tradingVM.limitPrice = formatPrice(tappedPrice)
                withAnimation(.easeInOut(duration: 0.2)) { tab = .trade }
            })
        } else {
            VStack(spacing: 12) {
                ProgressView().tint(.white)
                Text("Loading order book…")
                    .font(.system(size: 13))
                    .foregroundColor(.gray)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Trade content

    private var tradeContent: some View {
        TradeTabView()
            .environmentObject(tradingVM)
            .environmentObject(chartVM)
            .environmentObject(marketsVM)
            .environmentObject(watchVM)
    }

    private func findMarket() -> Market? {
        marketsVM.markets.first { $0.symbol == chartVM.selectedSymbol }
    }

    // MARK: - Formatters

    private func formatPrice(_ p: Double) -> String {
        // Use szDecimals-derived precision for Hyperliquid markets (matches chart Y-axis)
        if !chartVM.isCustomTVChart {
            let symbol = chartVM.selectedSymbol
            let isSpot = symbol.hasPrefix("@") || symbol.contains("/")
            let baseCoin: String = {
                if symbol.hasPrefix("@") { return symbol }
                if let slash = symbol.firstIndex(of: "/") { return String(symbol[..<slash]) }
                if symbol.contains(":") {
                    let parts = symbol.split(separator: ":", maxSplits: 1)
                    return parts.count > 1 ? String(parts[1]) : symbol
                }
                return symbol
            }()
            let szDec = MarketsViewModel.szDecimals(for: baseCoin)
            let maxBase = isSpot ? 8 : 6
            let decimals = max(0, min(maxBase - szDec, 8))
            return String(format: "%.\(decimals)f", p)
        }
        // Fallback for custom TradingView charts
        if p >= 10_000 { return String(format: "%.1f", p) }
        if p >= 1_000  { return String(format: "%.2f", p) }
        if p >= 1      { return String(format: "%.4f", p) }
        if p >= 0.01   { return String(format: "%.5f", p) }
        return String(format: "%.8f", p)
    }

    private func formatVolume(_ v: Double) -> String {
        if v >= 1_000_000_000 { return String(format: "%.1fB", v / 1_000_000_000) }
        if v >= 1_000_000     { return String(format: "%.1fM", v / 1_000_000) }
        if v >= 1_000         { return String(format: "%.1fK", v / 1_000) }
        return String(format: "%.2f", v)
    }
}
