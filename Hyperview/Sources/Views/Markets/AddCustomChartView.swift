import SwiftUI
import Combine

// MARK: - Symbol Search (Direct Exchange APIs via ExchangeSymbolIndex)

private struct TVSearchResult: Identifiable {
    let id = UUID()
    let symbol: String          // e.g. "ETHUSDT"
    let fullName: String        // e.g. "BINANCE:ETHUSDT"
    let description: String     // e.g. "Ethereum / TetherUS"
    let exchange: String        // e.g. "BINANCE"
    let type: String            // e.g. "crypto", "stock", "forex"

    var displayName: String { "\(exchange):\(symbol)" }
}

/// Groups search results by symbol, collecting all available exchanges
private struct TVSymbolExchanges: Identifiable {
    let id = UUID()
    let symbol: String
    let description: String
    let type: String
    let exchanges: [String]     // e.g. ["BINANCE", "OKX", "BYBIT"]
}

@MainActor
private final class TVSearchViewModel: ObservableObject {
    @Published var query = ""
    @Published var results: [TVSearchResult] = []
    @Published var isSearching = false

    // MARK: - Pair mode state
    @Published var isPairMode = false
    @Published var numeratorQuery = ""
    @Published var denominatorQuery = ""
    @Published var numeratorExchanges: TVSymbolExchanges?
    @Published var denominatorExchanges: TVSymbolExchanges?
    @Published var selectedNumeratorExchange: String?
    @Published var selectedDenominatorExchange: String?
    @Published var isSearchingNumerator = false
    @Published var isSearchingDenominator = false

    private var searchTask: Task<Void, Never>?
    private var numeratorTask: Task<Void, Never>?
    private var denominatorTask: Task<Void, Never>?

    /// The full TradingView pair expression, e.g. "BINANCE:HYPEUSDT/OKX:LITUSDT"
    /// When Hyperliquid is selected, uses the coin name (e.g., "HYPE") instead of the TV pair name
    var pairExpression: String? {
        guard let numExchanges = numeratorExchanges,
              let denExchanges = denominatorExchanges,
              let numEx = selectedNumeratorExchange,
              let denEx = selectedDenominatorExchange else { return nil }
        let numSymbol = Self.symbolForExchange(numEx, tvSymbol: numExchanges.symbol)
        let denSymbol = Self.symbolForExchange(denEx, tvSymbol: denExchanges.symbol)
        return "\(numEx):\(numSymbol)/\(denEx):\(denSymbol)"
    }

    /// For Hyperliquid, convert "HYPEUSDT" → "HYPE"; for others keep as-is
    static func symbolForExchange(_ exchange: String, tvSymbol: String) -> String {
        switch exchange.uppercased() {
        case "HYPERLIQUID", "HL":
            let upper = tvSymbol.uppercased()
            for suffix in ["USDT", "USDC", "BUSD", "USD", "PERP"] {
                if upper.hasSuffix(suffix) && upper.count > suffix.count {
                    return String(upper.dropLast(suffix.count))
                }
            }
            return tvSymbol
        default:
            return tvSymbol
        }
    }

    var canAddPair: Bool { pairExpression != nil }

    // MARK: - Search

    func search() {
        let trimmed = query.trimmingCharacters(in: .whitespaces)

        // Detect pair mode
        let hasPairSeparator = trimmed.contains("/")
        if hasPairSeparator != isPairMode {
            isPairMode = hasPairSeparator
            if !hasPairSeparator {
                clearPairState()
            }
        }

        if isPairMode {
            parsePairQuery(trimmed)
            return
        }

        // Regular single-symbol search
        guard trimmed.count >= 1 else {
            results = []
            isSearching = false
            return
        }

        searchTask?.cancel()
        isSearching = true

        searchTask = Task {
            // Small debounce
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }

            do {
                let fetched = try await Self.fetchSymbols(query: trimmed)
                guard !Task.isCancelled else { return }
                results = fetched
            } catch {
                guard !Task.isCancelled else { return }
                results = []
            }
            isSearching = false
        }
    }

    // MARK: - Pair Mode

    private func parsePairQuery(_ trimmed: String) {
        let parts = trimmed.split(separator: "/", maxSplits: 1)
        let numQ = parts.count > 0 ? String(parts[0]).trimmingCharacters(in: .whitespaces) : ""
        let denQ = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""

        if numQ != numeratorQuery {
            numeratorQuery = numQ
            selectedNumeratorExchange = nil
            numeratorExchanges = nil
            searchExchanges(for: numQ, side: .numerator)
        }

        if denQ != denominatorQuery {
            denominatorQuery = denQ
            selectedDenominatorExchange = nil
            denominatorExchanges = nil
            searchExchanges(for: denQ, side: .denominator)
        }
    }

    private enum PairSide { case numerator, denominator }

    private func searchExchanges(for symbolQuery: String, side: PairSide) {
        switch side {
        case .numerator:
            numeratorTask?.cancel()
            guard symbolQuery.count >= 1 else {
                numeratorExchanges = nil
                isSearchingNumerator = false
                return
            }
            isSearchingNumerator = true
            numeratorTask = Task {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
                let grouped = try? await Self.fetchGroupedExchanges(query: symbolQuery)
                guard !Task.isCancelled else { return }
                numeratorExchanges = grouped
                if let first = grouped?.exchanges.first {
                    selectedNumeratorExchange = first
                }
                isSearchingNumerator = false
            }
        case .denominator:
            denominatorTask?.cancel()
            guard symbolQuery.count >= 1 else {
                denominatorExchanges = nil
                isSearchingDenominator = false
                return
            }
            isSearchingDenominator = true
            denominatorTask = Task {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
                let grouped = try? await Self.fetchGroupedExchanges(query: symbolQuery)
                guard !Task.isCancelled else { return }
                denominatorExchanges = grouped
                if let first = grouped?.exchanges.first {
                    selectedDenominatorExchange = first
                }
                isSearchingDenominator = false
            }
        }
    }

    func clearPairState() {
        numeratorQuery = ""
        denominatorQuery = ""
        numeratorExchanges = nil
        denominatorExchanges = nil
        selectedNumeratorExchange = nil
        selectedDenominatorExchange = nil
        isSearchingNumerator = false
        isSearchingDenominator = false
        numeratorTask?.cancel()
        denominatorTask?.cancel()
    }

    // MARK: - API (powered by ExchangeSymbolIndex — no TradingView dependency)

    static func fetchSymbols(query: String) async throws -> [TVSearchResult] {
        let results = await ExchangeSymbolIndex.shared.search(query: query, limit: 40)
        return results.map { indexed in
            TVSearchResult(
                symbol: indexed.symbol,
                fullName: "\(indexed.exchange):\(indexed.symbol)",
                description: indexed.description,
                exchange: indexed.exchange,
                type: indexed.type
            )
        }
    }

    /// Find all exchanges that list a given symbol
    static func fetchGroupedExchanges(query: String) async throws -> TVSymbolExchanges? {
        guard let result = await ExchangeSymbolIndex.shared.exchanges(for: query) else { return nil }
        return TVSymbolExchanges(
            symbol: result.symbol,
            description: result.description,
            type: result.type,
            exchanges: result.exchanges
        )
    }
}

// MARK: - Add Custom Chart View

struct AddCustomChartView: View {
    @EnvironmentObject var chartVM: ChartViewModel
    @ObservedObject private var store = CustomChartStore.shared
    @StateObject private var searchVM = TVSearchViewModel()
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Search field
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(Color(white: 0.4))
                        .font(.system(size: 15))
                    TextField(
                        searchVM.isPairMode
                            ? "e.g. HYPEUSDT/LITUSDT"
                            : "Search symbol… ETHUSDT, AAPL, EUR",
                        text: $searchVM.query
                    )
                        .font(.system(size: 15))
                        .foregroundColor(.white)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.characters)
                        .focused($isFocused)
                        .submitLabel(.search)
                        .onSubmit { searchVM.search() }
                        .onChange(of: searchVM.query) { _, _ in searchVM.search() }

                    if !searchVM.query.isEmpty {
                        Button {
                            searchVM.query = ""
                            searchVM.results = []
                            searchVM.isPairMode = false
                            searchVM.clearPairState()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(Color(white: 0.4))
                                .font(.system(size: 16))
                        }
                    }
                }
                .padding(12)
                .background(Color.hlSurface)
                .cornerRadius(10)
                .padding(.horizontal, 16)
                .padding(.top, 12)

                // Pair mode hint
                if searchVM.isPairMode {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 10))
                        Text("Pair / Compare mode")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(.hlGreen)
                    .padding(.top, 6)
                    .padding(.horizontal, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Divider().background(Color.hlDivider).padding(.top, 10)

                // Content
                if searchVM.isPairMode {
                    pairBuilderContent
                } else {
                    regularSearchContent
                }
            }
            .background(Color.hlBackground)
            .navigationTitle("Add Chart")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(.hlGreen)
                }
            }
            .onAppear { isFocused = true }
        }
    }

    // MARK: - Regular Search Content

    private var regularSearchContent: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if searchVM.query.isEmpty {
                    // Default: show existing custom charts + suggestions
                    if !store.charts.isEmpty {
                        sectionHeader("Your Charts")
                        ForEach(store.charts) { chart in
                            existingRow(chart)
                        }
                    }

                    sectionHeader("Popular")
                    ForEach(defaultSuggestions, id: \.symbol) { item in
                        searchResultRow(item)
                    }
                } else if searchVM.isSearching && searchVM.results.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().tint(.white).scaleEffect(0.8)
                        Text("Searching…")
                            .font(.system(size: 13))
                            .foregroundColor(Color(white: 0.4))
                    }
                    .padding(.top, 40)
                } else if searchVM.results.isEmpty && !searchVM.query.isEmpty {
                    VStack(spacing: 8) {
                        Text("No results for \"\(searchVM.query)\"")
                            .font(.system(size: 13))
                            .foregroundColor(Color(white: 0.4))
                        Text("Try a different symbol or exchange")
                            .font(.system(size: 11))
                            .foregroundColor(Color(white: 0.3))
                    }
                    .padding(.top, 40)
                } else {
                    // Live search results
                    ForEach(searchVM.results) { result in
                        searchResultRow(result)
                    }
                }
            }
        }
    }

    // MARK: - Pair Builder Content

    private var pairBuilderContent: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 16) {
                    // Numerator section
                    pairSideSection(
                        label: "Numerator",
                        query: searchVM.numeratorQuery,
                        symbolExchanges: searchVM.numeratorExchanges,
                        selectedExchange: searchVM.selectedNumeratorExchange,
                        isSearching: searchVM.isSearchingNumerator
                    ) { exchange in
                        searchVM.selectedNumeratorExchange = exchange
                    }

                    // Divider with "/"
                    HStack {
                        Rectangle()
                            .fill(Color(white: 0.2))
                            .frame(height: 1)
                        Text("/")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(Color(white: 0.5))
                        Rectangle()
                            .fill(Color(white: 0.2))
                            .frame(height: 1)
                    }
                    .padding(.horizontal, 16)

                    // Denominator section
                    pairSideSection(
                        label: "Denominator",
                        query: searchVM.denominatorQuery,
                        symbolExchanges: searchVM.denominatorExchanges,
                        selectedExchange: searchVM.selectedDenominatorExchange,
                        isSearching: searchVM.isSearchingDenominator
                    ) { exchange in
                        searchVM.selectedDenominatorExchange = exchange
                    }

                    // Expression preview
                    if let expr = searchVM.pairExpression {
                        VStack(spacing: 6) {
                            Text("Expression")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(Color(white: 0.3))
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(expr)
                                .font(.system(size: 14, weight: .medium, design: .monospaced))
                                .foregroundColor(.hlGreen)
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.hlGreen.opacity(0.08))
                                .cornerRadius(8)
                        }
                        .padding(.horizontal, 16)
                    }
                }
                .padding(.top, 16)
                .padding(.bottom, 100) // space for button
            }

            // Add Chart button pinned at bottom
            VStack(spacing: 0) {
                Divider().background(Color.hlDivider)
                Button {
                    addPairChart()
                } label: {
                    Text("Add Chart")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(searchVM.canAddPair ? .black : Color(white: 0.4))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(searchVM.canAddPair ? Color.hlGreen : Color(white: 0.15))
                        .cornerRadius(12)
                }
                .disabled(!searchVM.canAddPair)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(Color.hlBackground)
        }
    }

    // MARK: - Pair Side Section

    private func pairSideSection(
        label: String,
        query: String,
        symbolExchanges: TVSymbolExchanges?,
        selectedExchange: String?,
        isSearching: Bool,
        onSelectExchange: @escaping (String) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(Color(white: 0.35))
                .padding(.horizontal, 16)

            if query.isEmpty {
                Text("Type a symbol on this side of /")
                    .font(.system(size: 13))
                    .foregroundColor(Color(white: 0.3))
                    .padding(.horizontal, 16)
            } else if isSearching {
                HStack(spacing: 8) {
                    ProgressView().tint(.white).scaleEffect(0.7)
                    Text("Searching \"\(query)\"…")
                        .font(.system(size: 12))
                        .foregroundColor(Color(white: 0.4))
                }
                .padding(.horizontal, 16)
            } else if let sym = symbolExchanges {
                // Symbol name + description
                VStack(alignment: .leading, spacing: 2) {
                    Text(sym.symbol)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                    if !sym.description.isEmpty {
                        Text(sym.description)
                            .font(.system(size: 11))
                            .foregroundColor(Color(white: 0.4))
                    }
                }
                .padding(.horizontal, 16)

                // Exchange chips — horizontally scrollable
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(sym.exchanges, id: \.self) { exchange in
                            exchangeChip(
                                name: exchange,
                                isSelected: selectedExchange == exchange
                            ) {
                                onSelectExchange(exchange)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
            } else {
                Text("No results for \"\(query)\"")
                    .font(.system(size: 12))
                    .foregroundColor(Color(white: 0.35))
                    .padding(.horizontal, 16)
            }
        }
    }

    // MARK: - Exchange Chip

    private func exchangeChip(name: String, isSelected: Bool, onTap: @escaping () -> Void) -> some View {
        Button(action: onTap) {
            Text(name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(isSelected ? .black : Color(white: 0.6))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(isSelected ? Color.hlGreen : Color(white: 0.15))
                .cornerRadius(14)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Add Pair Chart

    private func addPairChart() {
        guard let expr = searchVM.pairExpression,
              let numSym = searchVM.numeratorExchanges,
              let denSym = searchVM.denominatorExchanges,
              let numEx = searchVM.selectedNumeratorExchange,
              let denEx = searchVM.selectedDenominatorExchange else { return }

        let numIconBase = extractIconBase(from: numSym.symbol)
        let denIconBase = extractIconBase(from: denSym.symbol)

        // Clean display name: "HYPE/LITUSDT.P" instead of "HYPERLIQUID:HYPE/BINANCE:LITUSDT.P"
        let numDisplay = TVSearchViewModel.symbolForExchange(numEx, tvSymbol: numSym.symbol)
        let denDisplay = TVSearchViewModel.symbolForExchange(denEx, tvSymbol: denSym.symbol)
        let cleanName = "\(numDisplay)/\(denDisplay)"

        addChart(
            displayName: cleanName,
            tvSymbol: expr,
            iconBase: numIconBase,
            iconQuote: denIconBase
        )
    }

    // MARK: - Search Result Row

    private func searchResultRow(_ result: TVSearchResult) -> some View {
        Button {
            let pair = extractIconPair(from: result.symbol)
            addChart(
                displayName: result.displayName,
                tvSymbol: result.fullName,
                iconBase: pair.base,
                iconQuote: pair.quote
            )
        } label: {
            HStack(spacing: 12) {
                // Type icon
                typeIcon(result.type)
                    .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(result.symbol)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                        Text(result.exchange)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(exchangeColor(result.type))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(exchangeColor(result.type).opacity(0.12))
                            .cornerRadius(3)
                    }
                    if !result.description.isEmpty {
                        Text(result.description)
                            .font(.system(size: 11))
                            .foregroundColor(Color(white: 0.4))
                            .lineLimit(1)
                    }
                }

                Spacer()

                if store.contains(result.fullName) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.hlGreen)
                        .font(.system(size: 16))
                } else {
                    Image(systemName: "plus.circle")
                        .foregroundColor(Color(white: 0.35))
                        .font(.system(size: 16))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    // MARK: - Existing Chart Row

    private func existingRow(_ chart: CustomChart) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "chart.xyaxis.line")
                .foregroundColor(.hlGreen)
                .font(.system(size: 16))
                .frame(width: 32, height: 32)
                .background(Color.hlGreen.opacity(0.1))
                .cornerRadius(8)

            VStack(alignment: .leading, spacing: 2) {
                Text(Self.cleanDisplayName(chart.displayName))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                Text(chart.tvSymbol)
                    .font(.system(size: 11))
                    .foregroundColor(Color(white: 0.4))
            }

            Spacer()

            // Open chart
            Button {
                AppState.shared.openChart(
                    symbol: chart.tvSymbol,
                    displayName: chart.displayName,
                    chartVM: chartVM,
                    isCustomTV: true
                )
                dismiss()
            } label: {
                Image(systemName: "chevron.right")
                    .foregroundColor(Color(white: 0.3))
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)

            // Delete
            Button {
                store.remove(chart)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(Color(white: 0.25))
                    .font(.system(size: 16))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture {
            AppState.shared.openChart(
                symbol: chart.tvSymbol,
                displayName: chart.displayName,
                chartVM: chartVM,
                isCustomTV: true
            )
            dismiss()
        }
    }

    // MARK: - Helpers

    /// Strip exchange prefixes: "HYPERLIQUID:HYPE/BINANCE:LITUSDT.P" → "HYPE/LITUSDT.P"
    private static func cleanDisplayName(_ name: String) -> String {
        if name.contains("/") {
            let sides = name.split(separator: "/", maxSplits: 1)
            let clean0 = stripExchange(String(sides[0]))
            let clean1 = sides.count > 1 ? stripExchange(String(sides[1])) : ""
            return clean1.isEmpty ? clean0 : "\(clean0)/\(clean1)"
        }
        return stripExchange(name)
    }

    private static func stripExchange(_ s: String) -> String {
        if let idx = s.firstIndex(of: ":") { return String(s[s.index(after: idx)...]) }
        return s
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(Color(white: 0.3))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 6)
    }

    @ViewBuilder
    private func typeIcon(_ type: String) -> some View {
        let (icon, color): (String, Color) = {
            switch type.lowercased() {
            case "crypto":  return ("bitcoinsign.circle.fill", .orange)
            case "stock":   return ("building.columns.fill", .blue)
            case "forex":   return ("dollarsign.arrow.circlepath", .green)
            case "futures": return ("chart.bar.fill", .purple)
            case "index":   return ("chart.line.uptrend.xyaxis", .cyan)
            case "bond":    return ("percent", .yellow)
            case "cfd":     return ("arrow.left.arrow.right", .pink)
            case "economy": return ("globe", .teal)
            default:        return ("chart.xyaxis.line", .gray)
            }
        }()
        Image(systemName: icon)
            .foregroundColor(color)
            .font(.system(size: 15))
            .frame(width: 32, height: 32)
            .background(color.opacity(0.1))
            .cornerRadius(8)
    }

    private func exchangeColor(_ type: String) -> Color {
        switch type.lowercased() {
        case "crypto":  return .orange
        case "stock":   return .blue
        case "forex":   return .green
        case "futures": return .purple
        case "index":   return .cyan
        default:        return .gray
        }
    }

    private func addChart(displayName: String, tvSymbol: String, iconBase: String, iconQuote: String? = nil) {
        let chart = CustomChart(
            symbol: tvSymbol,
            displayName: displayName,
            iconBase: iconBase,
            iconQuote: iconQuote,
            addedAt: Date()
        )
        store.add(chart)
        AppState.shared.openChart(
            symbol: tvSymbol,
            displayName: displayName,
            chartVM: chartVM,
            isCustomTV: true
        )
        dismiss()
    }

    private func extractIconBase(from symbol: String) -> String {
        extractIconPair(from: symbol).base
    }

    /// Parse a symbol into base + optional quote asset.
    /// "ETHBTC" -> ("ETH", "BTC"), "AAPL" -> ("AAPL", nil), "BTC.D" -> ("BTC", nil)
    /// Also handles pair expressions: "BINANCE:HYPEUSDT/OKX:LITUSDT" -> ("HYPE", "LIT")
    private func extractIconPair(from symbol: String) -> (base: String, quote: String?) {
        // Handle pair expressions with "/"
        if symbol.contains("/") {
            let parts = symbol.split(separator: "/", maxSplits: 1)
            let numPart = parts.count > 0 ? String(parts[0]) : symbol
            let denPart = parts.count > 1 ? String(parts[1]) : nil

            // Strip exchange prefix: "BINANCE:HYPEUSDT" -> "HYPEUSDT"
            let numSymbol = numPart.contains(":") ? String(numPart.split(separator: ":").last ?? Substring(numPart)) : numPart
            let numBase = extractIconPair(from: numSymbol).base

            if let den = denPart {
                let denSymbol = den.contains(":") ? String(den.split(separator: ":").last ?? Substring(den)) : den
                let denBase = extractIconPair(from: denSymbol).base
                return (numBase, denBase)
            }
            return (numBase, nil)
        }

        // Dominance / index symbols like "BTC.D" -> single icon
        if symbol.contains(".") {
            let base = String(symbol.split(separator: ".").first ?? Substring(symbol))
            return (base, nil)
        }

        let knownQuotes = ["USDT", "USDC", "BUSD", "USD", "EUR", "GBP", "JPY", "BNB", "SOL", "BTC", "ETH"]
        // Try longest match first to avoid "USD" matching before "USDT"
        let sorted = knownQuotes.sorted { $0.count > $1.count }
        for quote in sorted {
            if symbol.hasSuffix(quote) && symbol.count > quote.count {
                let base = String(symbol.dropLast(quote.count))
                return (base, quote)
            }
        }
        return (symbol, nil)
    }

    // MARK: - Default Suggestions

    /// Suggestions = only cross-pairs and exotic combos NOT available on Hyperliquid.
    /// Stocks, forex, commodities etc. are findable via the live search — no need to clutter suggestions.
    private var defaultSuggestions: [TVSearchResult] {
        [
            TVSearchResult(symbol: "ETHBTC",   fullName: "BINANCE:ETHBTC",   description: "Ethereum / Bitcoin",        exchange: "BINANCE", type: "crypto"),
            TVSearchResult(symbol: "HYPEUSDT", fullName: "BINANCE:HYPEUSDT", description: "Hyperliquid / TetherUS",    exchange: "BINANCE", type: "crypto"),
            TVSearchResult(symbol: "SOLETH",   fullName: "BINANCE:SOLETH",   description: "Solana / Ethereum",         exchange: "BINANCE", type: "crypto"),
            TVSearchResult(symbol: "SOLBTC",   fullName: "BINANCE:SOLBTC",   description: "Solana / Bitcoin",          exchange: "BINANCE", type: "crypto"),
            TVSearchResult(symbol: "BTCEUR",   fullName: "BINANCE:BTCEUR",   description: "Bitcoin / Euro",            exchange: "BINANCE", type: "crypto"),
            TVSearchResult(symbol: "ETHEUR",   fullName: "BINANCE:ETHEUR",   description: "Ethereum / Euro",           exchange: "BINANCE", type: "crypto"),
            TVSearchResult(symbol: "BTC.D",    fullName: "CRYPTOCAP:BTC.D",  description: "Bitcoin Dominance",         exchange: "CRYPTOCAP", type: "index"),
            TVSearchResult(symbol: "ETH.D",    fullName: "CRYPTOCAP:ETH.D",  description: "Ethereum Dominance",        exchange: "CRYPTOCAP", type: "index"),
            TVSearchResult(symbol: "TOTAL",    fullName: "CRYPTOCAP:TOTAL",  description: "Total Crypto Market Cap",   exchange: "CRYPTOCAP", type: "index"),
            TVSearchResult(symbol: "TOTAL3",   fullName: "CRYPTOCAP:TOTAL3", description: "Crypto Market Cap (ex BTC/ETH)", exchange: "CRYPTOCAP", type: "index"),
            TVSearchResult(symbol: "DXY",      fullName: "TVC:DXY",          description: "US Dollar Index",           exchange: "TVC",     type: "index"),
            TVSearchResult(symbol: "US10Y",    fullName: "TVC:US10Y",        description: "US 10Y Treasury Yield",     exchange: "TVC",     type: "bond"),
        ]
    }
}
