import SwiftUI

/// Search results view for outcome (prediction / options) markets.
/// Fetches recent trades from the testnet API and filters client-side.
struct TrackOutcomeSearchResultsView: View {
    let question: OutcomeQuestion
    let selectedOutcomeIndex: Int?   // nil = all outcomes
    let sideIndex: Int?              // nil = both sides, 0 = side0 (Yes), 1 = side1 (No)
    let minSize: Double?
    let maxSize: Double?
    let minPrice: Double?            // 0–1 probability
    let maxPrice: Double?

    @State private var allTrades: [OutcomeTrade] = []
    @State private var isLoading = false
    @State private var errorMsg: String?
    @State private var aliases: [String: String] = [:]
    @State private var walletToShow: WalletIdentifier?
    @State private var expandedAddresses: Set<String> = []

    // MARK: - Filtered & grouped

    private var filteredTrades: [OutcomeTrade] {
        var result = allTrades

        // Filter by outcome
        if let idx = selectedOutcomeIndex,
           question.outcomes.indices.contains(idx) {
            let outcome = question.outcomes[idx]
            let validCoins = Set(outcome.sides.map(\.apiCoin))
            result = result.filter { validCoins.contains($0.coin) }
        }

        // Filter by side (e.g. Yes/No) — matches trades on the side's coin
        if let si = sideIndex {
            let sideCoins = Set(question.outcomes.compactMap { outcome -> String? in
                outcome.sides.first(where: { $0.sideIndex == si })?.apiCoin
            })
            result = result.filter { sideCoins.contains($0.coin) }
        }

        // Filter by USD size
        if let mn = minSize {
            result = result.filter { $0.usdValue >= mn }
        }
        if let mx = maxSize {
            result = result.filter { $0.usdValue <= mx }
        }

        // Filter by price (probability)
        if let mn = minPrice {
            result = result.filter { $0.price >= mn }
        }
        if let mx = maxPrice {
            result = result.filter { $0.price <= mx }
        }

        return result
    }

    /// Group trades by address, sorted by total USD volume
    private var groupedByAddress: [(address: String, trades: [OutcomeTrade], totalUSD: Double)] {
        var dict: [String: [OutcomeTrade]] = [:]
        for trade in filteredTrades {
            dict[trade.address, default: []].append(trade)
        }
        return dict.map { (address: $0.key, trades: $0.value, totalUSD: $0.value.reduce(0) { $0 + $1.usdValue }) }
            .sorted { $0.totalUSD > $1.totalUSD }
    }

    private var larps: [(address: String, trades: [OutcomeTrade], totalUSD: Double)] {
        groupedByAddress.filter { $0.totalUSD < 1_000 }
    }

    private var notLarps: [(address: String, trades: [OutcomeTrade], totalUSD: Double)] {
        groupedByAddress.filter { $0.totalUSD >= 1_000 }
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider().background(Color.hlSurface)

            if isLoading && allTrades.isEmpty {
                loadingView
            } else if let err = errorMsg {
                errorView(err)
            } else if groupedByAddress.isEmpty && !isLoading {
                emptyView
            } else {
                resultsList
            }
        }
        .background(Color.hlBackground)
        .navigationTitle(question.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadAliases()
            guard allTrades.isEmpty else { return }
            await fetchTrades()
        }
        .navigationDestination(isPresented: Binding(
            get: { walletToShow != nil },
            set: { if !$0 { walletToShow = nil } }
        )) {
            if let wallet = walletToShow {
                WalletDetailView(address: wallet.address)
                    .navigationTitle("Wallet")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar(.hidden, for: .tabBar)
            }
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(question.displayTitle)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text("\(groupedByAddress.count) wallets")
                    .font(.system(size: 12))
                    .foregroundColor(Color(white: 0.5))
            }

            HStack(spacing: 6) {
                if let idx = selectedOutcomeIndex, question.outcomes.indices.contains(idx) {
                    filterTag(question.outcomes[idx].name)
                }
                if let si = sideIndex,
                   let sideName = question.outcomes.first?.sides.first(where: { $0.sideIndex == si })?.name {
                    filterTag(sideName)
                }
                if let mn = minSize { filterTag("Size ≥ $\(formatCompact(mn))") }
                if let mx = maxSize { filterTag("Size ≤ $\(formatCompact(mx))") }
                if let mn = minPrice { filterTag("Price ≥ \(formatPct(mn))") }
                if let mx = maxPrice { filterTag("Price ≤ \(formatPct(mx))") }
            }

            if isLoading {
                Text("Fetching trades…")
                    .font(.system(size: 11))
                    .foregroundColor(Color(white: 0.5))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.hlCardBackground)
    }

    private func filterTag(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(.hlGreen)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.hlGreen.opacity(0.12))
            .cornerRadius(6)
    }

    // MARK: - Results list

    private var resultsList: some View {
        List {
            if !larps.isEmpty {
                Section {
                    ForEach(larps, id: \.address) { group in
                        Button {
                            walletToShow = WalletIdentifier(address: group.address)
                        } label: {
                            walletRow(group)
                        }
                        .listRowBackground(Color(white: 0.11))
                        .listRowSeparatorTint(Color(white: 0.18))
                    }
                } header: {
                    Text(larps.count == 1 ? "LARP DETECTED ❗️" : "LARPS DETECTED ❗️")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white)
                        .textCase(nil)
                        .listRowInsets(EdgeInsets(top: 12, leading: 0, bottom: 8, trailing: 0))
                }
            }

            if !notLarps.isEmpty {
                Section {
                    ForEach(notLarps, id: \.address) { group in
                        Button {
                            walletToShow = WalletIdentifier(address: group.address)
                        } label: {
                            walletRow(group)
                        }
                        .listRowBackground(Color(white: 0.11))
                        .listRowSeparatorTint(Color(white: 0.18))
                    }
                } header: {
                    Text(notLarps.count == 1 ? "NOT LARP :" : "NOT LARPS :")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white)
                        .textCase(nil)
                        .listRowInsets(EdgeInsets(top: 12, leading: 0, bottom: 8, trailing: 0))
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private func walletRow(_ group: (address: String, trades: [OutcomeTrade], totalUSD: Double)) -> some View {
        let alias = aliases[group.address.lowercased()]
        return VStack(spacing: 8) {
            HStack {
                if let alias {
                    Text(alias)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                } else {
                    Text(shortAddr(group.address))
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white)
                }

                Text("\(group.trades.count) trade\(group.trades.count == 1 ? "" : "s")")
                    .font(.system(size: 11))
                    .foregroundColor(Color(white: 0.5))

                Spacer()

                Text("$\(formatCompact(group.totalUSD))")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white)
            }

            // Show trades (3 by default, all if expanded)
            let isExpanded = expandedAddresses.contains(group.address)
            let visibleTrades = isExpanded ? group.trades : Array(group.trades.prefix(3))
            ForEach(visibleTrades, id: \.id) { trade in
                tradeDetailRow(trade)
            }
            if group.trades.count > 3 {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if isExpanded {
                            expandedAddresses.remove(group.address)
                        } else {
                            expandedAddresses.insert(group.address)
                        }
                    }
                } label: {
                    Text(isExpanded ? "Show less" : "+\(group.trades.count - 3) more")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.hlGreen)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
        .padding(.vertical, 6)
    }

    private func tradeDetailRow(_ trade: OutcomeTrade) -> some View {
        let isYesSide = trade.sideIndex == 0
        return HStack(spacing: 6) {
            // Side pill with actual side name (Yes/No or custom)
            Text(trade.sideName)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.white)
                .padding(.horizontal, 5)
                .frame(height: 16)
                .background(isYesSide ? Color.hlGreen : Color.tradingRed)
                .cornerRadius(4)

            // Outcome name (only show if multi-outcome, to avoid redundancy)
            if question.isMultiOutcome {
                Text(trade.outcomeName)
                    .font(.system(size: 11))
                    .foregroundColor(Color(white: 0.6))
                    .lineLimit(1)
            }

            Spacer()

            // Price as %
            Text(String(format: "%.1f%%", trade.price * 100))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.white)

            // USD value
            Text("$\(formatCompact(trade.usdValue))")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(Color(white: 0.7))

            // Time
            Text(tradeTimeString(trade.time))
                .font(.system(size: 10))
                .foregroundColor(Color(white: 0.4))
        }
    }

    // MARK: - States

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView().tint(.white)
            Text("Fetching recent trades…")
                .font(.system(size: 12))
                .foregroundColor(Color(white: 0.4))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyView: some View {
        VStack(spacing: 14) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 36))
                .foregroundColor(Color(white: 0.3))
            Text("No matching trades found")
                .font(.system(size: 14))
                .foregroundColor(Color(white: 0.5))
            Text("Try adjusting your filters or searching another market.")
                .font(.system(size: 12))
                .foregroundColor(Color(white: 0.35))
                .multilineTextAlignment(.center)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ msg: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 36))
                .foregroundColor(.orange)
            Text(msg)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button("Retry") {
                Task { await fetchTrades() }
            }
            .buttonStyle(.bordered).tint(.hlGreen)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Data fetching

    private func fetchTrades() async {
        isLoading = true
        errorMsg = nil

        // Build a map of coin → (outcomeName, sideName, sideIndex) for labeling
        var coinInfo: [String: (outcomeName: String, sideName: String, sideIndex: Int)] = [:]
        for outcome in question.outcomes {
            for side in outcome.sides {
                coinInfo[side.apiCoin] = (outcomeName: outcome.name, sideName: side.name, sideIndex: side.sideIndex)
            }
        }

        // Fetch trades for all sides of all outcomes in parallel
        var allCoins: [String] = []
        let outcomesToFetch: [OutcomeMarket]
        if let idx = selectedOutcomeIndex, question.outcomes.indices.contains(idx) {
            outcomesToFetch = [question.outcomes[idx]]
        } else {
            outcomesToFetch = question.outcomes
        }
        for outcome in outcomesToFetch {
            for side in outcome.sides {
                allCoins.append(side.apiCoin)
            }
        }

        do {
            var fetched: [OutcomeTrade] = []
            try await withThrowingTaskGroup(of: (String, [Trade]).self) { group in
                for coin in allCoins {
                    group.addTask {
                        let trades = try await HyperliquidAPI.shared.fetchOutcomeRecentTrades(coin: coin)
                        return (coin, trades)
                    }
                }
                for try await (coin, trades) in group {
                    let info = coinInfo[coin]
                    for trade in trades {
                        let address = Self.extractAddress(from: trade.hash)
                        fetched.append(OutcomeTrade(
                            id: trade.tid,
                            coin: coin,
                            address: address,
                            isBuy: trade.isBuy,
                            price: trade.price,
                            size: trade.size,
                            usdValue: trade.size * trade.price,
                            time: trade.tradeTime,
                            outcomeName: info?.outcomeName ?? coin,
                            sideName: info?.sideName ?? (trade.isBuy ? "Yes" : "No"),
                            sideIndex: info?.sideIndex ?? (trade.isBuy ? 0 : 1)
                        ))
                    }
                }
            }

            await MainActor.run {
                allTrades = fetched.sorted { $0.time > $1.time }
                isLoading = false
            }
        } catch {
            await MainActor.run {
                errorMsg = "Failed to fetch trades: \(error.localizedDescription)"
                isLoading = false
            }
        }
    }

    private static func extractAddress(from hash: String) -> String {
        if hash.hasPrefix("0x") && hash.count == 42 { return hash.lowercased() }
        if hash.count >= 40 {
            return ("0x" + hash.suffix(40)).lowercased()
        }
        return hash.lowercased()
    }

    // MARK: - Aliases

    private func loadAliases() async {
        var merged = UserDefaults.standard.dictionary(forKey: "customWalletAliases") as? [String: String] ?? [:]
        if let url = URL(string: "https://api.hypurrscan.io/globalAliases"),
           let (data, _) = try? await URLSession.shared.data(from: url),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            for (k, v) in dict {
                let key = k.lowercased()
                if merged[key] == nil { merged[key] = v }
            }
        }
        aliases = merged
    }

    // MARK: - Helpers

    private func shortAddr(_ addr: String) -> String {
        guard addr.count > 10 else { return addr }
        return "\(addr.prefix(6))…\(addr.suffix(4))"
    }

    private func formatCompact(_ v: Double) -> String {
        if v >= 1_000_000 { return String(format: "%.1fM", v / 1_000_000) }
        if v >= 1_000     { return String(format: "%.1fK", v / 1_000) }
        if v >= 1         { return String(format: "%.0f", v) }
        return String(format: "%.2f", v)
    }

    private func formatPct(_ v: Double) -> String {
        String(format: "%.0f%%", v * 100)
    }

    private func tradeTimeString(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "\(Int(interval))s" }
        if interval < 3600 { return "\(Int(interval / 60))m" }
        if interval < 86400 { return "\(Int(interval / 3600))h" }
        let fmt = DateFormatter()
        fmt.dateFormat = "MM/dd"
        return fmt.string(from: date)
    }
}

// MARK: - Trade model for outcome markets

struct OutcomeTrade: Identifiable {
    let id: Int64
    let coin: String
    let address: String
    let isBuy: Bool
    let price: Double       // 0–1 probability
    let size: Double        // contracts
    let usdValue: Double    // size × price
    let time: Date
    let outcomeName: String
    let sideName: String    // "Yes", "No", or custom side name
    let sideIndex: Int      // 0 or 1
}
