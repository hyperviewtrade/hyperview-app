import SwiftUI

/// Displays a user's prediction or option market positions from the HIP-4 testnet.
struct WalletOutcomeTab: View {
    let address: String
    let mode: Mode

    enum Mode { case predictions, options }

    @EnvironmentObject var marketsVM: MarketsViewModel
    @State private var positions: [OutcomePosition] = []
    @State private var isLoading = false
    @State private var hasLoaded = false

    var body: some View {
        Group {
            if isLoading && !hasLoaded {
                VStack(spacing: 12) {
                    ProgressView().tint(.white)
                    Text("Loading testnet positions...")
                        .font(.system(size: 11))
                        .foregroundColor(Color(white: 0.4))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if positions.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: mode == .predictions ? "chart.pie" : "option")
                        .font(.system(size: 28))
                        .foregroundColor(Color(white: 0.25))
                    Text("No \(mode == .predictions ? "prediction" : "option") positions")
                        .font(.system(size: 13))
                        .foregroundColor(Color(white: 0.4))
                    TestnetBadge()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(positions) { pos in
                            positionRow(pos)
                        }
                    }
                }
            }
        }
        .task(id: address) {
            await loadPositions()
        }
    }

    private func positionRow(_ pos: OutcomePosition) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                // Icon + Name
                VStack(alignment: .leading, spacing: 3) {
                    Text(pos.displayName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Text(pos.sideName)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(pos.isLong ? .hlGreen : .tradingRed)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background((pos.isLong ? Color.hlGreen : Color.tradingRed).opacity(0.12))
                            .cornerRadius(3)
                        Text("Outcome #\(pos.outcomeId)")
                            .font(.system(size: 10))
                            .foregroundColor(Color(white: 0.4))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Size + PnL
                VStack(alignment: .trailing, spacing: 3) {
                    Text(String(format: "%.1f shares", abs(pos.size)))
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundColor(.white)

                    HStack(spacing: 4) {
                        Text(String(format: "%.1f\u{00A2}", pos.entryPrice * 100))
                            .font(.system(size: 10))
                            .foregroundColor(Color(white: 0.4))
                        if pos.unrealizedPnl != 0 {
                            Text(String(format: "%@$%.2f",
                                        pos.unrealizedPnl >= 0 ? "+" : "",
                                        pos.unrealizedPnl))
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(pos.unrealizedPnl >= 0 ? .hlGreen : .tradingRed)
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider().background(Color(white: 0.12))
        }
    }

    private func loadPositions() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false; hasLoaded = true }

        let api = HyperliquidAPI.shared
        do {
            let state = try await api.fetchOutcomeUserState(address: address)

            // Parse asset positions from clearinghouseState
            guard let assetPositions = state["assetPositions"] as? [[String: Any]] else { return }

            // Get outcome metadata for name resolution
            let questions = marketsVM.outcomeQuestions

            var result: [OutcomePosition] = []
            for ap in assetPositions {
                guard let posDict = ap["position"] as? [String: Any],
                      let coin = posDict["coin"] as? String,
                      coin.hasPrefix("#"),
                      let szsStr = posDict["szi"] as? String,
                      let sz = Double(szsStr), sz != 0,
                      let entryStr = posDict["entryPx"] as? String,
                      let entry = Double(entryStr)
                else { continue }

                // Parse encoding from coin "#<encoding>"
                let encodingStr = String(coin.dropFirst())
                guard let encoding = Int(encodingStr) else { continue }
                let outcomeId = encoding / 10
                let sideIndex = encoding % 10

                // Resolve name from loaded questions
                let (displayName, sideName, isPrediction) = resolveOutcome(
                    outcomeId: outcomeId, sideIndex: sideIndex, questions: questions)

                // Filter by mode
                let wantPrediction = mode == .predictions
                if isPrediction != wantPrediction { continue }

                // Mark price (use current price from marketsVM if available)
                let markPrice = marketsVM.outcomeQuestions
                    .flatMap(\.outcomes)
                    .flatMap(\.sides)
                    .first(where: { $0.encoding == encoding })?.price ?? entry

                let pnl = sz * (markPrice - entry)

                result.append(OutcomePosition(
                    id: coin,
                    coin: coin,
                    outcomeId: outcomeId,
                    sideIndex: sideIndex,
                    displayName: displayName,
                    sideName: sideName,
                    size: sz,
                    entryPrice: entry,
                    markPrice: markPrice,
                    unrealizedPnl: pnl,
                    isLong: sz > 0
                ))
            }

            await MainActor.run { positions = result }
        } catch {
            print("Failed to load outcome positions: \(error)")
        }
    }

    private func resolveOutcome(outcomeId: Int, sideIndex: Int,
                                questions: [OutcomeQuestion]) -> (String, String, Bool) {
        for q in questions {
            for outcome in q.outcomes where outcome.outcomeId == outcomeId {
                let sideName = outcome.sides.first(where: { $0.sideIndex == sideIndex })?.name
                    ?? (sideIndex == 0 ? "Yes" : "No")
                let name = outcome.isOption ? outcome.displaySymbol : q.displayTitle
                return (name, sideName, outcome.isPrediction)
            }
        }
        return ("#\(outcomeId)", sideIndex == 0 ? "Yes" : "No", true)
    }
}

// MARK: - Outcome Position Model

struct OutcomePosition: Identifiable {
    let id: String
    let coin: String
    let outcomeId: Int
    let sideIndex: Int
    let displayName: String
    let sideName: String
    let size: Double
    let entryPrice: Double
    let markPrice: Double
    let unrealizedPnl: Double
    let isLong: Bool
}
