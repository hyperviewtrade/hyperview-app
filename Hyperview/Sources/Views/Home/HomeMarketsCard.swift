import SwiftUI
import Combine

struct HomeMarketsCard: View {
    @EnvironmentObject var marketsVM: MarketsViewModel
    @EnvironmentObject var watchVM:   WatchlistViewModel
    @EnvironmentObject var chartVM:   ChartViewModel

    @State private var selectedCategory: MarketCategory = .perpetuals
    @State private var selectedTab: MarketTab = .favorites
    @State private var selectedQuestion: OutcomeQuestion?
    @State private var refreshTimer: Timer?

    enum MarketCategory: String, CaseIterable {
        case perpetuals   = "Perps"
        case spot         = "Spot"
        case hip3         = "HIP3"
        case predictions  = "Predict"
        case options      = "Options"

        var mainCategory: MainCategory {
            switch self {
            case .perpetuals:  return .perps
            case .spot:        return .spot
            case .hip3:        return .perps   // HIP-3 is a Perps sub-category
            case .predictions: return .predictions
            case .options:     return .options
            }
        }
    }

    enum MarketTab: String, CaseIterable {
        case favorites = "Favorites"
        case hot       = "Hot"
        case gainers   = "Gainers"
        case losers    = "Losers"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Text("Markets")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.white)
                Spacer()
                Button {
                    if selectedCategory == .hip3 {
                        AppState.shared.pendingPerpSub = .hip3
                    }
                    AppState.shared.openMarkets(category: selectedCategory.mainCategory)
                } label: {
                    Text("View All")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.hlGreen)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.hlGreen)
                }
            }

            // Category tabs
            HStack(spacing: 6) {
                ForEach(MarketCategory.allCases, id: \.self) { cat in
                    categoryPill(cat)
                }
            }

            // Sub-tabs
            HStack(spacing: 0) {
                ForEach(MarketTab.allCases, id: \.self) { tab in
                    subTab(tab)
                }
            }
            .background(Color(white: 0.08))
            .cornerRadius(10)

            // Market rows
            if selectedCategory == .predictions || selectedCategory == .options {
                // HIP-4 outcome markets preview
                let outcomes = displayedOutcomes
                if marketsVM.isLoadingOutcomes && marketsVM.outcomeQuestions.isEmpty {
                    HStack {
                        Spacer()
                        ProgressView().tint(.white)
                            .padding(.vertical, 20)
                        Spacer()
                    }
                } else if outcomes.isEmpty {
                    outcomeEmptyState
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(outcomes.enumerated()), id: \.element.id) { index, outcome in
                            if index > 0 {
                                Divider().background(Color(white: 0.15))
                            }
                            compactOutcomeRow(outcome)
                        }
                    }
                }
            } else {
                let markets = displayedMarkets
                if markets.isEmpty {
                    HStack {
                        Spacer()
                        VStack(spacing: 6) {
                            Image(systemName: selectedTab == .favorites ? "star" : "chart.line.downtrend.xyaxis")
                                .font(.system(size: 20))
                                .foregroundColor(Color(white: 0.3))
                            Text(selectedTab == .favorites ? "No favorites yet" : "No markets")
                                .font(.system(size: 12))
                                .foregroundColor(Color(white: 0.4))
                        }
                        .padding(.vertical, 16)
                        Spacer()
                    }
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(markets.enumerated()), id: \.element.id) { index, market in
                            if index > 0 {
                                Divider().background(Color(white: 0.15))
                            }
                            compactRow(market)
                        }
                    }
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
        .sheet(item: $selectedQuestion) { question in
            OutcomeDetailView(question: question)
        }
        .onChange(of: selectedCategory) { _, newCat in
            if (newCat == .predictions || newCat == .options),
               marketsVM.outcomeQuestions.isEmpty, !marketsVM.isLoadingOutcomes {
                Task { await marketsVM.loadOutcomeMarkets() }
            }
        }
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { _ in
            guard selectedCategory == .options || selectedCategory == .predictions else { return }
            // Check if any displayed option just expired — reload to get new markets
            let hasExpired = marketsVM.outcomeQuestions.contains { q in
                q.isOption && (q.outcomes.first?.priceBinary?.isExpired == true)
            }
            if hasExpired && !marketsVM.isLoadingOutcomes {
                Task { await marketsVM.loadOutcomeMarkets() }
            }
        }
    }

    // MARK: - Category pill

    private func categoryPill(_ cat: MarketCategory) -> some View {
        let isActive = selectedCategory == cat
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) { selectedCategory = cat }
        } label: {
            Text(cat.rawValue)
                .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                .foregroundColor(isActive ? .black : Color(white: 0.5))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isActive ? Color.hlGreen : Color(white: 0.15))
                .cornerRadius(16)
        }
    }

    // MARK: - Sub tab

    private func subTab(_ tab: MarketTab) -> some View {
        let isActive = selectedTab == tab
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) { selectedTab = tab }
        } label: {
            Text(tab.rawValue)
                .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                .foregroundColor(isActive ? .black : Color(white: 0.5))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(isActive ? Color.hlGreen : Color.clear)
                .cornerRadius(10)
        }
    }

    // MARK: - Compact market row

    private func compactRow(_ market: Market) -> some View {
        Button {
            AppState.shared.openChart(
                symbol: market.symbol,
                displayName: market.isSpot ? market.spotDisplayPairName : market.displayName,
                perpEquivalent: market.perpEquivalent,
                chartVM: chartVM
            )
        } label: {
            HStack(spacing: 0) {
                // Star
                Button {
                    watchVM.toggle(market.symbol)
                } label: {
                    Image(systemName: watchVM.isWatched(market.symbol) ? "star.fill" : "star")
                        .foregroundColor(watchVM.isWatched(market.symbol) ? .hlGreen : Color(white: 0.3))
                        .font(.system(size: 12))
                        .frame(width: 28)
                }
                .buttonStyle(.plain)

                // Coin icon
                CoinIconView(symbol: market.spotDisplayBaseName, hlIconName: market.hlCoinIconName, iconSize: 20)
                    .padding(.trailing, 6)

                // Coin name
                Text(market.displaySymbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)

                Spacer(minLength: 8)

                // Price
                let price = marketsVM.livePrices[market.symbol] ?? market.price
                Text(market.format(price))
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundColor(.white)
                    .frame(minWidth: 80, alignment: .trailing)

                // Change badge (daily open based when available, else rolling 24h)
                let chg: Double = {
                    if let open = market.dailyOpenPrice, open > 0 {
                        return ((price - open) / open) * 100
                    }
                    return market.change24h
                }()
                let isPositive = chg >= 0
                Text(String(format: "%@%.2f%%", isPositive ? "+" : "", chg))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(isPositive ? .hlGreen : .white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(isPositive ? Color.hlButtonBg : Color.tradingRed)
                    .cornerRadius(4)
                    .frame(width: 72, alignment: .trailing)
            }
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Data

    private var filteredByCategory: [Market] {
        switch selectedCategory {
        case .perpetuals:
            return marketsVM.markets.filter { $0.marketType == .perp && !$0.isPreLaunch }
        case .spot:
            return marketsVM.markets.filter { $0.marketType == .spot }
        case .hip3:
            return marketsVM.markets.filter { $0.isHIP3 }
        case .predictions, .options:
            return [] // Handled separately via displayedOutcomes
        }
    }

    private var displayedMarkets: [Market] {
        let base = filteredByCategory
        switch selectedTab {
        case .favorites:
            let favSet = Set(watchVM.symbols)
            // Filter to favorites first, then sort within that set.
            // Using the drag order from the Markets tab when available — markets not in the
            // saved order (e.g. HIP-3 loaded after the drag) fall back to volume sort so they
            // are never silently excluded from the card.
            let filtered = base.filter { favSet.contains($0.symbol) }
            if let order = marketsVM.customSymbolOrder {
                let orderMap = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
                return filtered.sorted {
                    let posA = orderMap[$0.symbol]
                    let posB = orderMap[$1.symbol]
                    switch (posA, posB) {
                    case let (a?, b?): return a < b              // both in saved order → respect it
                    case (_?, nil):    return true               // only a in order → a first
                    case (nil, _?):    return false              // only b in order → b first
                    case (nil, nil):   return $0.volume24h > $1.volume24h  // neither → sort by volume
                    }
                }.prefix5()
            } else {
                return filtered.sorted { $0.volume24h > $1.volume24h }.prefix5()
            }
        case .hot:
            return base.sorted { $0.volume24h > $1.volume24h }.prefix5()
        case .gainers:
            return base.sorted { $0.change24h > $1.change24h }.prefix5()
        case .losers:
            return base.sorted { $0.change24h < $1.change24h }.prefix5()
        }
    }

    // MARK: - Outcome markets data

    private var displayedOutcomes: [OutcomeQuestion] {
        let isPredictions = selectedCategory == .predictions
        let filtered = marketsVM.outcomeQuestions.filter {
            let match = isPredictions ? $0.isPrediction : $0.isOption
            // Hide expired options
            if $0.isOption, let pb = $0.outcomes.first?.priceBinary, pb.isExpired { return false }
            return match
        }

        switch selectedTab {
        case .favorites:
            // Show top 5 by decisiveness (most decisive markets first)
            return Array(filtered.sorted { a, b in
                let aPrice = a.outcomes.first?.side0Price ?? 0.5
                let bPrice = b.outcomes.first?.side0Price ?? 0.5
                return abs(aPrice - 0.5) > abs(bPrice - 0.5)
            }.prefix(5))
        case .hot:
            return Array(filtered.sorted { a, b in
                let aPrice = a.outcomes.first?.side0Price ?? 0.5
                let bPrice = b.outcomes.first?.side0Price ?? 0.5
                return abs(aPrice - 0.5) > abs(bPrice - 0.5)
            }.prefix(5))
        case .gainers:
            return Array(filtered.sorted { $0.yesChange24h > $1.yesChange24h }.prefix(5))
        case .losers:
            return Array(filtered.sorted { $0.yesChange24h < $1.yesChange24h }.prefix(5))
        }
    }

    private var outcomeEmptyState: some View {
        HStack {
            Spacer()
            VStack(spacing: 6) {
                Image(systemName: selectedCategory == .predictions
                      ? "chart.pie" : "option")
                    .font(.system(size: 20))
                    .foregroundColor(Color(white: 0.3))
                Text("HIP-4 Testnet")
                    .font(.system(size: 12))
                    .foregroundColor(Color(white: 0.4))
                Text("Coming soon to mainnet")
                    .font(.system(size: 10))
                    .foregroundColor(Color(white: 0.3))
            }
            .padding(.vertical, 16)
            Spacer()
        }
    }

    // MARK: - Compact outcome row

    private func compactOutcomeRow(_ question: OutcomeQuestion) -> some View {
        let outcome = question.outcomes.first
        let pb = outcome?.priceBinary
        let side0 = outcome?.sides.first
        let side1 = outcome?.sides.count ?? 0 > 1 ? outcome?.sides[1] : nil

        return Button {
            selectedQuestion = question
        } label: {
            HStack(spacing: 0) {
                // Icon
                ZStack {
                    Circle()
                        .fill(Color.hlGreen.opacity(0.1))
                        .frame(width: 28, height: 28)
                    if let pb {
                        CoinIconView(symbol: pb.underlying, hlIconName: pb.underlying, iconSize: 18)
                    } else {
                        Image(systemName: question.isMultiOutcome ? "list.bullet" : "chart.pie.fill")
                            .font(.system(size: 12))
                            .foregroundColor(.hlGreen)
                    }
                }
                .padding(.trailing, 8)

                // Name
                VStack(alignment: .leading, spacing: 2) {
                    Text(question.displayTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    if let pb {
                        if pb.isExpired {
                            Text("Expired")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.tradingRed)
                        } else {
                            Text("\(pb.formattedExpiryFull) \u{00B7} \(pb.periodDisplay) \u{00B7} \(pb.timeRemaining)")
                                .font(.system(size: 10))
                                .foregroundColor(Color(white: 0.4))
                                .lineLimit(1)
                        }
                    } else if question.isMultiOutcome {
                        Text("\(question.outcomes.count) outcomes")
                            .font(.system(size: 10))
                            .foregroundColor(Color(white: 0.4))
                    }
                }

                Spacer(minLength: 8)

                // Probability badge
                let prob = outcome?.side0Price ?? 0.5
                Text(String(format: "%.0f%%", prob * 100))
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundColor(prob >= 0.6 ? .hlGreen : (prob <= 0.4 ? .tradingRed : .white))
                    .frame(width: 50, alignment: .trailing)

                // Change badge or side mini pills
                if selectedTab == .gainers || selectedTab == .losers {
                    let chg = question.yesChange24h
                    let isPos = chg >= 0
                    Text(String(format: "%@%.1f%%", isPos ? "+" : "", chg))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(isPos ? .hlGreen : .white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(isPos ? Color.hlButtonBg : Color.tradingRed)
                        .cornerRadius(4)
                        .frame(width: 72, alignment: .trailing)
                } else {
                    HStack(spacing: 3) {
                        if let s0 = side0 {
                            Text(String(format: "%@%.0f", String(s0.name.prefix(1)), s0.price * 100))
                                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                .foregroundColor(.hlGreen)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .background(Color.hlGreen.opacity(0.12))
                                .cornerRadius(3)
                        }
                        if let s1 = side1 {
                            Text(String(format: "%@%.0f", String(s1.name.prefix(1)), s1.price * 100))
                                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                .foregroundColor(.tradingRed)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .background(Color.tradingRed.opacity(0.12))
                                .cornerRadius(3)
                        }
                    }
                    .frame(width: 72, alignment: .trailing)
                }
            }
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
    }
}

private extension Array {
    func prefix5() -> [Element] {
        Array(prefix(5))
    }
}
