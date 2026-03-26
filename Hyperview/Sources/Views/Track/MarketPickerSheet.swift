import SwiftUI

struct MarketPickerSheet: View {
    @Binding var selection: Market?
    @Binding var outcomeSelection: OutcomeQuestion?
    @Binding var isPresented: Bool

    @EnvironmentObject var marketsVM: MarketsViewModel

    @State private var search = ""
    @State private var category: Category = .crypto

    enum Category: String, CaseIterable {
        case crypto      = "Crypto"
        case predictions = "Predictions"
        case options     = "Options"
    }

    // MARK: - Filtered lists

    /// Reactive: reads marketsVM.markets every render, so new data appears automatically.
    private var perpMarkets: [Market] {
        marketsVM.markets.filter { $0.marketType == .perp && !$0.isPreLaunch }
    }

    private var filteredCrypto: [Market] {
        let sorted = perpMarkets.sorted { ($0.openInterest * $0.price) > ($1.openInterest * $1.price) }
        if search.isEmpty { return sorted }
        let q = search.lowercased()
        return sorted.filter { $0.displayName.lowercased().contains(q) }
    }

    private var filteredOutcomes: [OutcomeQuestion] {
        let isPredictions = category == .predictions
        var result = marketsVM.outcomeQuestions.filter {
            isPredictions ? $0.isPrediction : $0.isOption
        }
        // Sort by volume (sum of all side volumes), highest first
        result.sort { a, b in
            let volA = a.outcomes.flatMap(\.sides).reduce(0.0) { $0 + $1.volume }
            let volB = b.outcomes.flatMap(\.sides).reduce(0.0) { $0 + $1.volume }
            return volA > volB
        }
        if !search.isEmpty {
            let q = search.lowercased()
            result = result.filter {
                $0.name.lowercased().contains(q) ||
                $0.displayTitle.lowercased().contains(q)
            }
        }
        return result
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Category tabs
                HStack(spacing: 0) {
                    ForEach(Category.allCases, id: \.self) { cat in
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) { category = cat }
                        } label: {
                            Text(cat.rawValue)
                                .font(.system(size: 13, weight: category == cat ? .semibold : .regular))
                                .foregroundColor(category == cat ? .black : Color(white: 0.5))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(category == cat ? Color.hlGreen : Color.clear)
                                .cornerRadius(8)
                        }
                    }
                }
                .padding(3)
                .background(Color(white: 0.08))
                .cornerRadius(10)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)

                Divider().background(Color.hlDivider)

                // Content
                switch category {
                case .crypto:
                    cryptoList
                case .predictions, .options:
                    outcomeList
                }
            }
            .background(Color.hlBackground)
            .searchable(text: $search, prompt: "Search market…")
            .navigationTitle("Select Market")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { isPresented = false }
                        .foregroundColor(.hlGreen)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onChange(of: category) { _, newCat in
            if (newCat == .predictions || newCat == .options),
               marketsVM.outcomeQuestions.isEmpty, !marketsVM.isLoadingOutcomes {
                Task { await marketsVM.loadOutcomeMarkets() }
            }
        }
    }

    // MARK: - Crypto list

    private var cryptoList: some View {
        Group {
            if filteredCrypto.isEmpty && marketsVM.isLoading {
                VStack(spacing: 12) {
                    ProgressView().tint(.white)
                    Text("Loading markets…")
                        .font(.system(size: 12))
                        .foregroundColor(Color(white: 0.4))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filteredCrypto, id: \.symbol) { market in
                    Button {
                        selection = market
                        outcomeSelection = nil
                        isPresented = false
                    } label: {
                        HStack(spacing: 12) {
                            CoinIconView(
                                symbol: market.displaySymbol,
                                hlIconName: market.hlCoinIconName,
                                iconSize: 28
                            )

                            VStack(alignment: .leading, spacing: 1) {
                                Text(market.displayName)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(.white)

                                HStack(spacing: 8) {
                                    if market.openInterest > 0 {
                                        Text("OI $\(market.formattedOI)")
                                            .font(.system(size: 11))
                                            .foregroundColor(Color(white: 0.4))
                                    }
                                    if market.volume24h > 0 {
                                        Text("Vol $\(market.formattedVolume)")
                                            .font(.system(size: 11))
                                            .foregroundColor(Color(white: 0.4))
                                    }
                                }
                            }

                            Spacer()

                            if selection?.symbol == market.symbol && outcomeSelection == nil {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.hlGreen)
                                    .font(.system(size: 14, weight: .semibold))
                            }
                        }
                    }
                    .listRowBackground(Color.hlCardBackground)
                    .listRowSeparatorTint(Color.hlDivider)
                }
                .listStyle(.plain)
            }
        }
    }

    // MARK: - Outcome list

    private var outcomeList: some View {
        Group {
            if marketsVM.isLoadingOutcomes && marketsVM.outcomeQuestions.isEmpty {
                VStack(spacing: 12) {
                    ProgressView().tint(.white)
                    Text("Loading from testnet…")
                        .font(.system(size: 12))
                        .foregroundColor(Color(white: 0.4))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredOutcomes.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: category == .predictions ? "chart.pie" : "option")
                        .font(.system(size: 28))
                        .foregroundColor(Color(white: 0.25))
                    Text("No \(category == .predictions ? "prediction" : "options") markets")
                        .font(.system(size: 13))
                        .foregroundColor(Color(white: 0.4))
                    TestnetBadge()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filteredOutcomes) { question in
                    Button {
                        outcomeSelection = question
                        selection = nil
                        isPresented = false
                    } label: {
                        HStack(spacing: 12) {
                            // Icon
                            ZStack {
                                Circle()
                                    .fill(Color.hlGreen.opacity(0.1))
                                    .frame(width: 28, height: 28)
                                if let pb = question.outcomes.first?.priceBinary {
                                    CoinIconView(symbol: pb.underlying, hlIconName: pb.underlying, iconSize: 18)
                                } else {
                                    Image(systemName: question.isMultiOutcome ? "list.bullet" : "chart.pie.fill")
                                        .font(.system(size: 12))
                                        .foregroundColor(.hlGreen)
                                }
                            }

                            VStack(alignment: .leading, spacing: 1) {
                                Text(question.displayTitle)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(.white)
                                    .lineLimit(1)

                                HStack(spacing: 6) {
                                    if question.isMultiOutcome {
                                        Text("\(question.outcomes.count) outcomes")
                                            .font(.system(size: 11))
                                            .foregroundColor(Color(white: 0.4))
                                    }
                                    let vol = question.outcomes.first?.formattedVolume ?? "—"
                                    if vol != "—" {
                                        Text("Vol $\(vol)")
                                            .font(.system(size: 11))
                                            .foregroundColor(Color(white: 0.4))
                                    }
                                }
                            }

                            Spacer()

                            // Probability
                            if let prob = question.outcomes.first?.side0Price {
                                Text(String(format: "%.0f%%", prob * 100))
                                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                                    .foregroundColor(prob >= 0.6 ? .hlGreen : (prob <= 0.4 ? .tradingRed : .white))
                            }

                            if outcomeSelection?.id == question.id {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.hlGreen)
                                    .font(.system(size: 14, weight: .semibold))
                            }
                        }
                    }
                    .listRowBackground(Color.hlCardBackground)
                    .listRowSeparatorTint(Color.hlDivider)
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
}
