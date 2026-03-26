import SwiftUI

struct RepaySheet: View {
    let debtCoin: String          // e.g. "USDC", "USDH"
    let debtAmount: Double        // total borrowed
    let availableAssets: [TradeTabView.PMBalanceEntry]

    @Environment(\.dismiss) private var dismiss
    @State private var repayPercent: Double = 0
    @State private var repayAmountInput: String = ""
    @State private var selectedAssetIndex: Int = 0
    @State private var isExecuting = false
    @State private var resultMessage: String?
    @State private var resultIsError = false
    @FocusState private var isAmountFocused: Bool

    private var selectedAsset: TradeTabView.PMBalanceEntry? {
        guard selectedAssetIndex < availableAssets.count else { return nil }
        return availableAssets[selectedAssetIndex]
    }

    private var repayAmount: Double {
        if let manual = Double(repayAmountInput), manual > 0 {
            return manual
        }
        return debtAmount * repayPercent / 100
    }

    private var assetToSell: Double {
        guard let asset = selectedAsset, asset.usdcValue != 0 else { return 0 }
        let pricePerToken = abs(asset.usdcValue) / asset.netBalance
        guard pricePerToken > 0 else { return 0 }
        return repayAmount / pricePerToken
    }

    private var exceedsAvailable: Bool {
        guard let asset = selectedAsset else { return true }
        return assetToSell > asset.availableBalance && repayPercent > 0
    }

    private var canRepay: Bool {
        repayPercent > 0 && !isExecuting && selectedAsset != nil && !exceedsAvailable
    }

    var body: some View {
        NavigationStack {
            ScrollView {
            VStack(spacing: 20) {
                // Description
                Text("This will attempt to market sell the selected asset to repay debt.")
                    .font(.system(size: 13))
                    .foregroundColor(.gray)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)

                // Percentage slider
                VStack(spacing: 8) {
                    HStack {
                        Slider(value: $repayPercent, in: 0...100, step: 1)
                            .tint(.hlGreen)
                            .onChange(of: repayPercent) { _, newPct in
                                // Sync text field when slider moves (only if not typing)
                                if !isAmountFocused {
                                    let amt = debtAmount * newPct / 100
                                    repayAmountInput = amt > 0 ? String(format: "%.2f", amt) : ""
                                }
                            }

                        HStack(spacing: 2) {
                            Text("\(Int(repayPercent))")
                                .font(.system(size: 14, weight: .bold, design: .monospaced))
                                .foregroundColor(.white)
                                .frame(width: 32, alignment: .trailing)
                            Text("%")
                                .font(.system(size: 12))
                                .foregroundColor(.gray)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color(white: 0.12))
                        )
                    }

                    // Quick buttons
                    HStack(spacing: 8) {
                        ForEach([25, 50, 75, 100], id: \.self) { pct in
                            Button {
                                repayPercent = Double(pct)
                                let amt = debtAmount * Double(pct) / 100
                                repayAmountInput = String(format: "%.2f", amt)
                                isAmountFocused = false
                            } label: {
                                Text("\(pct)%")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(Int(repayPercent) == pct ? .black : .hlGreen)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 6)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(Int(repayPercent) == pct ? Color.hlGreen : Color.hlGreen.opacity(0.15))
                                    )
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)

                // Amount to repay
                VStack(spacing: 12) {
                    HStack {
                        TextField(
                            repayPercent > 0 && repayAmountInput.isEmpty
                                ? String(format: "%.2f", debtAmount * repayPercent / 100)
                                : "Amount to Repay",
                            text: $repayAmountInput
                        )
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(.white)
                            .keyboardType(.decimalPad)
                            .focused($isAmountFocused)
                            .onChange(of: repayAmountInput) { _, newVal in
                                // Sync slider when typing manually
                                if let val = Double(newVal), debtAmount > 0 {
                                    let pct = min((val / debtAmount) * 100, 100)
                                    repayPercent = pct
                                }
                            }
                        Text(debtCoin)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(isAmountFocused ? Color.hlGreen.opacity(0.5) : Color(white: 0.2), lineWidth: 1)
                    )

                    // Asset to sell
                    HStack {
                        Text("Asset to Sell")
                            .font(.system(size: 13))
                            .foregroundColor(.gray)
                        Spacer()
                        if availableAssets.count > 1 {
                            Menu {
                                ForEach(Array(availableAssets.enumerated()), id: \.offset) { idx, asset in
                                    Button {
                                        selectedAssetIndex = idx
                                    } label: {
                                        Text(asset.coin == "UBTC" ? "BTC" : asset.coin)
                                    }
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Text(displayCoin(selectedAsset?.coin ?? ""))
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundColor(.white)
                                    Image(systemName: "chevron.down")
                                        .font(.system(size: 10))
                                        .foregroundColor(.gray)
                                }
                            }
                        } else {
                            Text(displayCoin(selectedAsset?.coin ?? ""))
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.white)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color(white: 0.2), lineWidth: 1)
                    )
                }
                .padding(.horizontal, 20)

                // Available balance
                if let asset = selectedAsset {
                    HStack {
                        Text("Available Balance")
                            .font(.system(size: 12))
                            .foregroundColor(.gray)
                        Spacer()
                        Text(String(format: "%.6f %@", asset.availableBalance, displayCoin(asset.coin)))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 20)
                }

                // Exceeds warning
                if exceedsAvailable, let asset = selectedAsset {
                    Text("Insufficient \(displayCoin(asset.coin)) balance to cover this repay amount")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.tradingRed)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                }

                // Result message
                if let msg = resultMessage {
                    Text(msg)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(resultIsError ? .tradingRed : .hlGreen)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                }

                // Repay button
                Button {
                    isAmountFocused = false
                    Task { await executeRepay() }
                } label: {
                    if isExecuting {
                        ProgressView()
                            .tint(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    } else {
                        Text("Repay")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(canRepay ? .black : .gray)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(canRepay ? Color.hlGreen : Color(white: 0.2))
                )
                .disabled(!canRepay)
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
            .padding(.top, 10)
            } // ScrollView
            .scrollDismissesKeyboard(.interactively)
            .background(Color.hlBackground.ignoresSafeArea())
            .navigationTitle("Repay")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .foregroundColor(.white)
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if isAmountFocused {
                    HStack {
                        Spacer()
                        Button("Done") { isAmountFocused = false }
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.hlGreen)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color(white: 0.12))
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func displayCoin(_ coin: String) -> String {
        coin == "UBTC" ? "BTC" : coin
    }

    private func executeRepay() async {
        guard let asset = selectedAsset, repayAmount > 0 else { return }
        isExecuting = true
        resultMessage = nil

        do {
            let hlURL = URL(string: "https://api.hyperliquid.xyz/info")!

            // 1. Find the spot pair for asset.coin / debtCoin
            var metaReq = URLRequest(url: hlURL)
            metaReq.httpMethod = "POST"
            metaReq.addValue("application/json", forHTTPHeaderField: "Content-Type")
            metaReq.httpBody = try JSONSerialization.data(withJSONObject: ["type": "spotMetaAndAssetCtxs"])
            let (metaData, _) = try await URLSession.shared.data(for: metaReq)
            guard let metaJson = try JSONSerialization.jsonObject(with: metaData) as? [Any],
                  metaJson.count >= 2,
                  let meta = metaJson[0] as? [String: Any],
                  let tokens = meta["tokens"] as? [[String: Any]],
                  let universe = meta["universe"] as? [[String: Any]],
                  let ctxs = metaJson[1] as? [[String: Any]]
            else {
                resultMessage = "Failed to load spot markets"
                resultIsError = true
                isExecuting = false
                return
            }

            // Build token name → index map + szDecimals
            var tokenIndexMap: [String: Int] = [:]
            var tokenSzDecimals: [String: Int] = [:]
            for tok in tokens {
                if let name = tok["name"] as? String, let idx = tok["index"] as? Int {
                    tokenIndexMap[name] = idx
                    tokenSzDecimals[name] = (tok["szDecimals"] as? Int) ?? 4
                }
            }

            let sellCoin = asset.coin // e.g. "UBTC", "HYPE"
            guard let sellTokenIdx = tokenIndexMap[sellCoin],
                  let buyTokenIdx = tokenIndexMap[debtCoin] else {
                resultMessage = "Token not found"
                resultIsError = true
                isExecuting = false
                return
            }

            // Find pair where tokens[0] = sellCoin, tokens[1] = debtCoin
            var realPairIndex: Int?  // the "index" field from universe, NOT array position
            var pairName: String?
            for u in universe {
                if let toks = u["tokens"] as? [Int], toks.count >= 2,
                   toks[0] == sellTokenIdx, toks[1] == buyTokenIdx {
                    // Get the real pair index from the "index" field
                    if let idx = u["index"] as? Int {
                        realPairIndex = idx
                    } else if let n = u["index"] as? NSNumber {
                        realPairIndex = n.intValue
                    }
                    pairName = u["name"] as? String
                    break
                }
            }

            guard let spotIdx = realPairIndex else {
                resultMessage = "No \(displayCoin(sellCoin))/\(debtCoin) pair"
                resultIsError = true
                isExecuting = false
                return
            }

            // szDecimals = base token's szDecimals (not the pair's)
            let szDec = tokenSzDecimals[sellCoin] ?? 4

            // 2. Get real price from allMids using pair name (e.g. "@142")
            var midsReq = URLRequest(url: hlURL)
            midsReq.httpMethod = "POST"
            midsReq.addValue("application/json", forHTTPHeaderField: "Content-Type")
            midsReq.httpBody = try JSONSerialization.data(withJSONObject: ["type": "allMids"])
            let (midsData, _) = try await URLSession.shared.data(for: midsReq)
            let mids = (try? JSONSerialization.jsonObject(with: midsData) as? [String: String]) ?? [:]

            let pairKey = pairName ?? "@\(spotIdx)"
            let realPrice = Double(mids[pairKey] ?? "0") ?? 0
            guard realPrice > 0 else {
                resultMessage = "Could not get market price"
                resultIsError = true
                isExecuting = false
                return
            }

            // Sell price with 3% slippage (selling below market)
            let sellPrice = realPrice * 0.97

            // 3. Calculate size to sell (repayAmount is in debtCoin USD terms)
            let sellSize = repayAmount / realPrice

            // Spot asset index = universe index + 10000
            let spotAssetIndex = spotIdx + 10000

            print("[REPAY] pair=\(pairKey) price=\(realPrice) slippage=\(sellPrice) size=\(sellSize) szDec=\(szDec) assetIdx=\(spotAssetIndex)")

            // 4. Sign and submit the order
            let payload = try await TransactionSigner.signOrder(
                assetIndex: spotAssetIndex,
                isBuy: false,
                limitPrice: sellPrice,
                size: sellSize,
                reduceOnly: false,
                orderType: ["limit": ["tif": "Ioc"]],  // IoC = market order
                szDecimals: szDec
            )

            let response = try await HyperliquidAPI.shared.submitOrder(signedPayload: payload)

            // Check response
            if response.status == "ok" {
                let statuses = response.response?.data?.statuses ?? []
                let errorStatus = statuses.first(where: { $0.error != nil })

                if let err = errorStatus?.error {
                    resultMessage = err
                    resultIsError = true
                } else {
                    resultMessage = "Repay successful"
                    resultIsError = false
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    await MainActor.run { dismiss() }
                }
            } else {
                resultMessage = "Order failed: \(response.status)"
                resultIsError = true
            }
        } catch {
            resultMessage = error.localizedDescription
            resultIsError = true
        }

        isExecuting = false
    }
}
