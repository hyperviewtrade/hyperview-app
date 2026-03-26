import SwiftUI

struct SymbolPickerView: View {
    @EnvironmentObject var chartVM:    ChartViewModel
    @EnvironmentObject var marketsVM:  MarketsViewModel
    @Environment(\.dismiss) var dismiss

    @State private var query:          String             = ""
    @State private var selectedMain:   MainCategory       = .all
    @State private var selectedPerpSub: PerpSubCategory   = .all
    @State private var selectedCrypto: CryptoSubCategory  = .all
    @State private var selectedTradfi: TradfiSubCategory  = .all
    @State private var selectedSpot:   SpotQuoteCategory  = .all
    @State private var selectedDex:    String             = "All"
    @State private var selectedOptionsUnderlying: OptionsUnderlying = .all
    @State private var selectedOptionsPeriod: OptionsPeriod = .all
    @State private var selectedQuestion: OutcomeQuestion?

    // MARK: - Filtered regular markets

    var filtered: [Market] {
        var result = marketsVM.markets

        switch selectedMain {
        case .all:    break
        case .perps:
            result = result.filter { $0.marketType == .perp && !$0.isPreLaunch }
            switch selectedPerpSub {
            case .all: break
            case .crypto:
                result = result.filter { !$0.isHIP3 }
                if selectedCrypto != .all {
                    result = result.filter { $0.cryptoSubCategory == selectedCrypto }
                }
            case .tradfi:
                result = result.filter { $0.isHIP3 && marketsVM.isTradfi($0) }
                if selectedTradfi != .all {
                    result = result.filter { $0.tradfiSubCategory == selectedTradfi }
                }
            case .hip3:
                result = result.filter { $0.isHIP3 }
                if selectedDex != "All" {
                    result = result.filter { $0.dexName == selectedDex }
                }
            case .preLaunch:
                result = result.filter { $0.isPreLaunch }
            }
        case .spot:
            result = result.filter { $0.marketType == .spot }
            if selectedSpot != .all {
                result = result.filter { $0.spotQuoteCategory == selectedSpot }
            }
        case .crypto:
            result = result.filter { $0.marketType == .perp && !$0.isHIP3 && !$0.isPreLaunch }
            if selectedCrypto != .all {
                result = result.filter { $0.cryptoSubCategory == selectedCrypto }
            }
        case .tradfi:
            result = result.filter { $0.isHIP3 && marketsVM.isTradfi($0) }
            if selectedTradfi != .all {
                result = result.filter { $0.tradfiSubCategory == selectedTradfi }
            }
        case .hip3:
            result = result.filter { $0.isHIP3 }
            if selectedDex != "All" {
                result = result.filter { $0.dexName == selectedDex }
            }
        case .trending:
            result = result.filter { $0.marketType == .perp }
            result.sort { abs($0.change24h) > abs($1.change24h) }
            if !query.isEmpty {
                result = result.filter {
                    $0.displayName.localizedCaseInsensitiveContains(query) ||
                    $0.symbol.localizedCaseInsensitiveContains(query) ||
                    $0.spotDisplayBaseName.localizedCaseInsensitiveContains(query)
                }
            }
            return Array(result.prefix(50))
        case .preLaunch:
            result = result.filter { $0.isPreLaunch }
        case .predictions, .options:
            return [] // Handled separately via filteredOutcomes
        }

        if !query.isEmpty {
            result = result.filter {
                $0.displayName.localizedCaseInsensitiveContains(query) ||
                $0.symbol.localizedCaseInsensitiveContains(query) ||
                $0.spotDisplayBaseName.localizedCaseInsensitiveContains(query)
            }
        }
        return result.sorted { $0.volume24h > $1.volume24h }
    }

    // MARK: - Filtered outcome questions

    private var filteredOutcomes: [OutcomeQuestion] {
        let isPredictions = selectedMain == .predictions
        var result = marketsVM.outcomeQuestions.filter {
            isPredictions ? $0.isPrediction : $0.isOption
        }

        if selectedMain == .options {
            if selectedOptionsUnderlying != .all {
                let underlying = selectedOptionsUnderlying.rawValue
                result = result.filter { q in
                    q.outcomes.contains { $0.priceBinary?.underlying == underlying }
                }
            }
            if selectedOptionsPeriod != .all {
                let period = selectedOptionsPeriod.rawValue
                result = result.filter { q in
                    q.outcomes.contains { $0.priceBinary?.period == period }
                }
            }
        }

        if !query.isEmpty {
            result = result.filter {
                $0.name.localizedCaseInsensitiveContains(query) ||
                $0.displayTitle.localizedCaseInsensitiveContains(query)
            }
        }
        return result
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Search
                SearchBarView(text: $query, placeholder: "Search symbol…")
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)

                // Main category chips
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(MainCategory.topRow) { cat in
                            mainChip(cat)
                        }
                    }
                    .padding(.horizontal, 14)
                }
                .frame(height: 40)

                // Sub-category chips
                subCategoryChips

                Divider().background(Color.hlSurface)

                // Content
                if selectedMain == .predictions || selectedMain == .options {
                    outcomeContent
                } else {
                    marketsList
                }
            }
            .background(Color.hlBackground)
            .navigationTitle("Select Symbol")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }.tint(.hlGreen)
                }
            }
            .keyboardDoneBar()
            .sheet(item: $selectedQuestion) { question in
                OutcomeDetailView(question: question)
            }
        }
        .preferredColorScheme(.dark)
        .task {
            if marketsVM.markets.isEmpty { await marketsVM.loadMarkets() }
        }
        .onChange(of: selectedMain) { _, newVal in
            if (newVal == .predictions || newVal == .options),
               marketsVM.outcomeQuestions.isEmpty, !marketsVM.isLoadingOutcomes {
                Task { await marketsVM.loadOutcomeMarkets() }
            }
        }
    }

    // MARK: - Sub-category chips

    @ViewBuilder
    private var subCategoryChips: some View {
        if selectedMain == .perps {
            VStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(PerpSubCategory.allCases) { sub in
                            subChip(sub.rawValue, isActive: selectedPerpSub == sub) {
                                selectedPerpSub = sub
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                }
                .frame(height: 36)

                // Third level
                if selectedPerpSub == .crypto {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(CryptoSubCategory.allCases) { sub in
                                subChip(sub.rawValue, isActive: selectedCrypto == sub) {
                                    selectedCrypto = sub
                                }
                            }
                        }
                        .padding(.horizontal, 14)
                    }
                    .frame(height: 32)
                } else if selectedPerpSub == .tradfi {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(TradfiSubCategory.allCases) { sub in
                                subChip(sub.rawValue, isActive: selectedTradfi == sub) {
                                    selectedTradfi = sub
                                }
                            }
                        }
                        .padding(.horizontal, 14)
                    }
                    .frame(height: 32)
                } else if selectedPerpSub == .hip3 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            subChip("All", isActive: selectedDex == "All") {
                                selectedDex = "All"
                            }
                            ForEach(marketsVM.availableHIP3Dexes, id: \.self) { dex in
                                subChip(dex, isActive: selectedDex == dex) {
                                    selectedDex = dex
                                }
                            }
                        }
                        .padding(.horizontal, 14)
                    }
                    .frame(height: 32)
                }
            }
        } else if selectedMain == .spot {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(SpotQuoteCategory.allCases) { sub in
                        subChip(sub.rawValue, isActive: selectedSpot == sub) {
                            selectedSpot = sub
                        }
                    }
                }
                .padding(.horizontal, 14)
            }
            .frame(height: 36)
        } else if selectedMain == .crypto {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(CryptoSubCategory.allCases) { sub in
                        subChip(sub.rawValue, isActive: selectedCrypto == sub) {
                            selectedCrypto = sub
                        }
                    }
                }
                .padding(.horizontal, 14)
            }
            .frame(height: 36)
        } else if selectedMain == .tradfi {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(TradfiSubCategory.allCases) { sub in
                        subChip(sub.rawValue, isActive: selectedTradfi == sub) {
                            selectedTradfi = sub
                        }
                    }
                }
                .padding(.horizontal, 14)
            }
            .frame(height: 36)
        } else if selectedMain == .hip3 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    subChip("All", isActive: selectedDex == "All") {
                        selectedDex = "All"
                    }
                    ForEach(marketsVM.availableHIP3Dexes, id: \.self) { dex in
                        subChip(dex, isActive: selectedDex == dex) {
                            selectedDex = dex
                        }
                    }
                }
                .padding(.horizontal, 14)
            }
            .frame(height: 36)
        } else if selectedMain == .predictions {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    TestnetBadge()
                    Text("HIP-4 Outcome Trading")
                        .font(.system(size: 11))
                        .foregroundColor(Color(white: 0.4))
                }
                .padding(.horizontal, 14)
            }
            .frame(height: 36)
        } else if selectedMain == .options {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    TestnetBadge()
                    Divider().frame(height: 20).background(Color(white: 0.25))
                    ForEach(OptionsUnderlying.allCases) { sub in
                        subChip(sub.rawValue, isActive: selectedOptionsUnderlying == sub) {
                            selectedOptionsUnderlying = sub
                        }
                    }
                    Divider().frame(height: 20).background(Color(white: 0.25))
                    ForEach(OptionsPeriod.allCases) { sub in
                        subChip(sub.displayName, isActive: selectedOptionsPeriod == sub) {
                            selectedOptionsPeriod = sub
                        }
                    }
                }
                .padding(.horizontal, 14)
            }
            .frame(height: 36)
        }
    }

    // MARK: - Regular markets list

    private var marketsList: some View {
        List(filtered) { market in
            Button {
                chartVM.changeSymbol(
                    market.symbol,
                    displayName: market.isSpot ? market.spotDisplayPairName : market.displayName,
                    perpEquivalent: market.perpEquivalent)
                dismiss()
            } label: {
                HStack(spacing: 10) {
                    CoinIconView(symbol: market.spotDisplayBaseName, hlIconName: market.hlCoinIconName)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(market.isSpot ? "\(market.spotDisplayPairName)  SPOT" : market.displaySymbol)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                        Text("Vol \(market.formattedVolume)")
                            .font(.system(size: 11))
                            .foregroundColor(.gray)
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 2) {
                        Text(market.formattedPrice)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(.white)
                        Text(String(format: "%@%.2f%%",
                                    market.isPositive ? "+" : "",
                                    market.change24h))
                            .font(.system(size: 12))
                            .foregroundColor(market.isPositive ? .hlGreen : .tradingRed)
                    }
                }
            }
            .listRowBackground(
                market.symbol == chartVM.selectedSymbol
                    ? Color.hlGreen.opacity(0.08) : Color.clear
            )
            .listRowSeparatorTint(Color.hlSurface)
        }
        .listStyle(.plain)
    }

    // MARK: - Outcome markets content

    private var outcomeContent: some View {
        Group {
            if marketsVM.isLoadingOutcomes && marketsVM.outcomeQuestions.isEmpty {
                VStack(spacing: 12) {
                    ProgressView().tint(.white)
                    Text("Loading from testnet...")
                        .font(.system(size: 12))
                        .foregroundColor(Color(white: 0.4))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredOutcomes.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: selectedMain == .predictions
                          ? "chart.pie" : "option")
                        .font(.system(size: 28))
                        .foregroundColor(Color(white: 0.25))
                    Text("No \(selectedMain == .predictions ? "prediction" : "options") markets")
                        .font(.system(size: 13))
                        .foregroundColor(Color(white: 0.4))
                    Text("HIP-4 is live on testnet")
                        .font(.system(size: 11))
                        .foregroundColor(Color(white: 0.3))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(filteredOutcomes) { question in
                        Group {
                            if question.isOption {
                                OptionQuestionRowView(question: question)
                            } else {
                                QuestionRowView(question: question)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { selectedQuestion = question }
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 14))
                        .listRowSeparator(.visible)
                        .listRowSeparatorTint(Color.hlSurface)
                    }
                }
                .listStyle(.plain)
            }
        }
        .onAppear {
            if marketsVM.outcomeQuestions.isEmpty && !marketsVM.isLoadingOutcomes {
                Task { await marketsVM.loadOutcomeMarkets() }
            }
        }
    }

    // MARK: - Chip helpers

    private func mainChip(_ cat: MainCategory) -> some View {
        let isActive = selectedMain == cat
        return Button { selectedMain = cat } label: {
            Text(cat.rawValue)
                .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                .foregroundColor(isActive ? .black : Color(white: 0.6))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isActive ? Color.hlGreen : Color.hlButtonBg)
                .cornerRadius(20)
        }
    }

    private func subChip(_ label: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                .foregroundColor(isActive ? .hlGreen : Color(white: 0.5))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(isActive ? Color.hlGreen.opacity(0.12) : Color.clear)
                .cornerRadius(7)
        }
    }
}
