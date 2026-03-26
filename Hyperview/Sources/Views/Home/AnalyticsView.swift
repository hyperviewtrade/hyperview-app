import SwiftUI

struct AnalyticsView: View {
    @StateObject private var vm = AnalyticsViewModel()
    @EnvironmentObject var marketsVM: MarketsViewModel
    @EnvironmentObject var chartVM: ChartViewModel
    @ObservedObject private var appState = AppState.shared

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 14) {
                Color.clear.frame(height: 0).id("analyticsTop")
                globalStatsCard
                oiChartCard
                oiMarketsTable
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 32)
        }
        .onChange(of: appState.homeReselect) { _, _ in
            withAnimation { proxy.scrollTo("analyticsTop", anchor: .top) }
        }
        }
        .background(Color.hlBackground.ignoresSafeArea())
        .task {
            vm.start(markets: marketsVM.markets)
        }
        .onDisappear { vm.stop() }
        .onChange(of: marketsVM.markets.count) { _, _ in
            vm.updateDashboard(markets: marketsVM.markets)
        }
    }

    // MARK: - Section 1: Global Stats Card

    private var globalStatsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Open Interest Analytics")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)

            HStack(spacing: 0) {
                statColumn(
                    label: "Total OI",
                    value: formatLargeUSD(vm.globalStats.totalOI)
                )
                Spacer()
                statColumn(
                    label: "Volume 24h",
                    value: formatLargeUSD(vm.globalStats.totalVolume24h)
                )
                Spacer()
                statColumn(
                    label: "Avg Funding",
                    value: String(format: "%@%.4f%%",
                                  vm.globalStats.avgFunding >= 0 ? "+" : "",
                                  vm.globalStats.avgFunding * 100),
                    valueColor: vm.globalStats.avgFunding >= 0 ? .hlGreen : .tradingRed
                )
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(white: 0.11))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color(white: 0.18), lineWidth: 1)
                )
        )
    }

    private func statColumn(label: String, value: String, valueColor: Color = .white) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(Color(white: 0.45))
            Text(value)
                .font(.system(size: 17, weight: .bold))
                .foregroundColor(valueColor)
        }
    }

    // MARK: - Section 2: OI Chart Card

    private var oiChartCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("OI History")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)

            // Coin selector — horizontal pills
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(coinSelectorList, id: \.self) { coin in
                        coinPill(coin)
                    }
                }
            }

            // Current OI + change
            let history = vm.selectedCoinHistory
            if let latest = history.last {
                HStack(spacing: 8) {
                    Text(formatLargeUSD(latest.oi))
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.white)

                    if history.count >= 2 {
                        let first = history.first!.oi
                        let change = first > 0 ? ((latest.oi - first) / first) * 100 : 0
                        Text(String(format: "%@%.2f%%", change >= 0 ? "+" : "", change))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(change >= 0 ? .hlGreen : .tradingRed)
                    }
                }
            }

            // Mini chart
            if history.count >= 5 {
                oiLineChart(data: history)
                    .frame(height: 120)
            } else {
                HStack {
                    Spacer()
                    VStack(spacing: 6) {
                        Image(systemName: "chart.line.uptrend.xyaxis")
                            .font(.system(size: 22))
                            .foregroundColor(Color(white: 0.3))
                        Text("Collecting data...")
                            .font(.system(size: 12))
                            .foregroundColor(Color(white: 0.4))
                        Text("OI history updates every 60s")
                            .font(.system(size: 10))
                            .foregroundColor(Color(white: 0.3))
                    }
                    .padding(.vertical, 24)
                    Spacer()
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(white: 0.11))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color(white: 0.18), lineWidth: 1)
                )
        )
    }

    private func coinPill(_ coin: String) -> some View {
        let isActive = vm.selectedCoin == coin
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) { vm.selectedCoin = coin }
        } label: {
            Text(coin)
                .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                .foregroundColor(isActive ? .black : Color(white: 0.5))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isActive ? Color.hlGreen : Color(white: 0.15))
                .cornerRadius(16)
        }
    }

    private var coinSelectorList: [String] {
        // Top coins from OI table + fallback defaults
        let defaults = ["BTC", "ETH", "SOL", "HYPE", "XRP", "DOGE", "SUI", "LINK", "AVAX", "ADA"]
        let fromTable = vm.topOIMarkets.prefix(10).map { $0.coin }
        var seen = Set<String>()
        var result: [String] = []
        for coin in fromTable + defaults {
            if seen.insert(coin).inserted { result.append(coin) }
        }
        return Array(result.prefix(12))
    }

    // MARK: - Canvas Line Chart

    private func oiLineChart(data: [OIDataPoint]) -> some View {
        Canvas { context, size in
            guard data.count >= 2 else { return }

            let values = data.map { $0.oi }
            let minVal = values.min()!
            let maxVal = values.max()!
            let range = maxVal - minVal
            let yRange = range > 0 ? range : 1

            let w = size.width
            let h = size.height
            let padding: CGFloat = 2

            func point(at index: Int) -> CGPoint {
                let x = padding + (w - padding * 2) * CGFloat(index) / CGFloat(data.count - 1)
                let y = h - padding - (h - padding * 2) * CGFloat((values[index] - minVal) / yRange)
                return CGPoint(x: x, y: y)
            }

            // Filled area path
            var areaPath = Path()
            areaPath.move(to: CGPoint(x: point(at: 0).x, y: h))
            for i in 0..<data.count {
                areaPath.addLine(to: point(at: i))
            }
            areaPath.addLine(to: CGPoint(x: point(at: data.count - 1).x, y: h))
            areaPath.closeSubpath()

            let gradient = Gradient(colors: [
                Color.hlGreen.opacity(0.25),
                Color.hlGreen.opacity(0.02)
            ])
            context.fill(
                areaPath,
                with: .linearGradient(
                    gradient,
                    startPoint: CGPoint(x: w / 2, y: 0),
                    endPoint: CGPoint(x: w / 2, y: h)
                )
            )

            // Line path
            var linePath = Path()
            linePath.move(to: point(at: 0))
            for i in 1..<data.count {
                linePath.addLine(to: point(at: i))
            }

            context.stroke(
                linePath,
                with: .color(.hlGreen),
                lineWidth: 1.5
            )
        }
    }

    // MARK: - Section 3: OI Markets Table

    private var oiMarketsTable: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header + sort pills
            HStack {
                Text("Top Markets")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
                Spacer()
            }

            // Sort pills
            HStack(spacing: 6) {
                ForEach(AnalyticsViewModel.OISortOption.allCases, id: \.self) { opt in
                    sortPill(opt)
                }
            }

            // Column headers
            HStack(spacing: 0) {
                Text("Coin")
                    .frame(width: 60, alignment: .leading)
                Spacer()
                Text("OI")
                    .frame(width: 72, alignment: .trailing)
                Text("Funding")
                    .frame(width: 80, alignment: .trailing)
                Text("Vol")
                    .frame(width: 64, alignment: .trailing)
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(Color(white: 0.4))
            .padding(.horizontal, 4)

            // Rows
            VStack(spacing: 0) {
                ForEach(Array(vm.topOIMarkets.enumerated()), id: \.element.id) { index, row in
                    if index > 0 {
                        Divider().background(Color(white: 0.15))
                    }
                    marketRow(row)
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(white: 0.11))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color(white: 0.18), lineWidth: 1)
                )
        )
    }

    private func sortPill(_ option: AnalyticsViewModel.OISortOption) -> some View {
        let isActive = vm.selectedSort == option
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                vm.selectedSort = option
                vm.updateDashboard(markets: marketsVM.markets)
            }
        } label: {
            Text(option.rawValue)
                .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                .foregroundColor(isActive ? .black : Color(white: 0.5))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isActive ? Color.hlGreen : Color(white: 0.15))
                .cornerRadius(16)
        }
    }

    private func marketRow(_ row: OIMarketRow) -> some View {
        Button {
            AppState.shared.openChart(
                symbol: row.symbol,
                displayName: row.coin,
                chartVM: chartVM
            )
        } label: {
            HStack(spacing: 0) {
                // Coin name
                Text(row.coin)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 60, alignment: .leading)
                    .lineLimit(1)

                Spacer()

                // OI
                Text(formatCompact(row.openInterest))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(.white)
                    .frame(width: 72, alignment: .trailing)

                // Funding
                let fundingPct = row.fundingRate * 100
                Text(String(format: "%@%.4f%%", fundingPct >= 0 ? "+" : "", fundingPct))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(fundingPct >= 0 ? .hlGreen : .tradingRed)
                    .frame(width: 80, alignment: .trailing)

                // Volume
                Text(formatCompact(row.volume24h))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(Color(white: 0.6))
                    .frame(width: 64, alignment: .trailing)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 4)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Formatting Helpers

    private func formatLargeUSD(_ value: Double) -> String {
        if value >= 1_000_000_000 { return String(format: "$%.2fB", value / 1_000_000_000) }
        if value >= 1_000_000     { return String(format: "$%.1fM", value / 1_000_000) }
        if value >= 1_000         { return String(format: "$%.1fK", value / 1_000) }
        return String(format: "$%.0f", value)
    }

    private func formatCompact(_ value: Double) -> String {
        if value >= 1_000_000_000 { return String(format: "$%.1fB", value / 1_000_000_000) }
        if value >= 1_000_000     { return String(format: "$%.0fM", value / 1_000_000) }
        if value >= 1_000         { return String(format: "$%.0fK", value / 1_000) }
        return String(format: "$%.0f", value)
    }
}
