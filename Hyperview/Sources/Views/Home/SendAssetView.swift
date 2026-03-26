import SwiftUI

// MARK: - Spot holding for token picker

private struct SpotHolding: Identifiable {
    let id = UUID()
    let coin: String
    let token: String      // e.g. "PURR:0xc4bf3f870c0e9465323c0b6ed28096c2"
    let balance: Double
    let usdValue: Double
}

// MARK: - SendAssetView

struct SendAssetView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var wallet = WalletManager.shared

    @State private var holdings: [SpotHolding] = []
    @State private var selectedHolding: SpotHolding?
    @State private var destinationAddress = ""
    @State private var amount = ""
    @State private var isSubmitting = false
    @State private var resultMessage: String?
    @State private var isSuccess = false
    @State private var isLoading = true
    @State private var showTokenPicker = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Token picker
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Token")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(Color(white: 0.5))

                        Button {
                            showTokenPicker = true
                        } label: {
                            HStack(spacing: 10) {
                                if let h = selectedHolding {
                                    CoinIconView(symbol: h.coin, hlIconName: h.coin, iconSize: 24, isSpot: true)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(h.coin)
                                            .font(.system(size: 15, weight: .bold))
                                            .foregroundColor(.white)
                                        Text(String(format: "%.4f available", h.balance))
                                            .font(.system(size: 11))
                                            .foregroundColor(Color(white: 0.4))
                                    }
                                } else {
                                    Image(systemName: "plus.circle")
                                        .foregroundColor(.hlGreen)
                                    Text("Select token")
                                        .font(.system(size: 15))
                                        .foregroundColor(Color(white: 0.5))
                                }
                                Spacer()
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundColor(Color(white: 0.4))
                            }
                            .padding(14)
                            .background(Color(white: 0.09))
                            .cornerRadius(12)
                        }
                    }
                    .padding(.horizontal, 16)

                    // Destination address
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Destination (Hypercore L1)")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(Color(white: 0.5))

                        HStack(spacing: 8) {
                            TextField("0x…", text: $destinationAddress)
                                .font(.system(size: 14, design: .monospaced))
                                .foregroundColor(.white)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)

                            Button {
                                if let str = UIPasteboard.general.string {
                                    destinationAddress = str.trimmingCharacters(in: .whitespacesAndNewlines)
                                }
                            } label: {
                                Image(systemName: "doc.on.clipboard")
                                    .font(.system(size: 14))
                                    .foregroundColor(.hlGreen)
                            }
                        }
                        .padding(14)
                        .background(Color(white: 0.09))
                        .cornerRadius(12)
                    }
                    .padding(.horizontal, 16)

                    // Amount
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Amount")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(Color(white: 0.5))

                        HStack(spacing: 10) {
                            TextField("0.00", text: $amount)
                                .keyboardType(.decimalPad)
                                .font(.system(size: 20, weight: .bold, design: .monospaced))
                                .foregroundColor(.white)
                                .onChange(of: amount) { oldValue, newValue in
                                    guard formatDecimalWithCommas(newValue) != newValue else { return }
                                    let formatted = formatDecimalOnChange(oldValue: oldValue, newValue: newValue)
                                    if formatted != newValue { amount = formatted }
                                }

                            if let h = selectedHolding {
                                Button("Max") {
                                    amount = String(format: "%g", h.balance)
                                }
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(.hlGreen)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Color.hlGreen.opacity(0.12))
                                .cornerRadius(8)
                            }
                        }
                        .padding(14)
                        .background(Color(white: 0.09))
                        .cornerRadius(12)
                    }
                    .padding(.horizontal, 16)

                    // Info
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle")
                            .foregroundColor(.hlGreen)
                        Text("Sends tokens on Hyperliquid L1 (Hypercore). Instant, no gas fees.")
                            .font(.system(size: 12))
                            .foregroundColor(Color(white: 0.5))
                    }
                    .padding(.horizontal, 20)

                    // Result message
                    if let msg = resultMessage {
                        HStack(spacing: 8) {
                            Image(systemName: isSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundColor(isSuccess ? .hlGreen : .tradingRed)
                            Text(msg)
                                .font(.system(size: 13))
                                .foregroundColor(isSuccess ? .hlGreen : .tradingRed)
                        }
                        .padding(.horizontal, 16)
                    }

                    // Submit
                    Button {
                        Task { await submitSend() }
                    } label: {
                        HStack(spacing: 8) {
                            if isSubmitting {
                                ProgressView().tint(.black)
                            }
                            Image(systemName: wallet.biometricEnabled ? "faceid" : "paperplane.fill")
                                .font(.system(size: 14))
                            Text(wallet.biometricEnabled ? "Confirm with Face ID" : "Confirm Send")
                        }
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(canSubmit ? Color.hlGreen : Color.hlGreen.opacity(0.3))
                        .cornerRadius(12)
                    }
                    .disabled(!canSubmit)
                    .padding(.horizontal, 16)

                    Spacer()
                }
                .padding(.top, 10)
            }
            .background(Color.hlBackground.ignoresSafeArea())
            .keyboardDoneBar()
            .navigationTitle("Send")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundColor(.hlGreen)
                }
            }
            .sheet(isPresented: $showTokenPicker) {
                tokenPickerSheet
            }
            .task { await fetchSpotHoldings() }
        }
    }

    // MARK: - Computed

    private var canSubmit: Bool {
        guard !isSubmitting,
              let h = selectedHolding,
              destinationAddress.count >= 10,
              let val = Double(stripCommas(amount)), val > 0
        else { return false }
        return val <= h.balance
    }

    // MARK: - Token picker sheet

    private var tokenPickerSheet: some View {
        NavigationStack {
            List {
                if isLoading {
                    HStack {
                        Spacer()
                        ProgressView().tint(.white)
                        Spacer()
                    }
                    .listRowBackground(Color.hlBackground)
                } else if holdings.isEmpty {
                    Text("No spot holdings found")
                        .foregroundColor(Color(white: 0.5))
                        .listRowBackground(Color.hlBackground)
                } else {
                    ForEach(holdings) { h in
                        Button {
                            selectedHolding = h
                            showTokenPicker = false
                        } label: {
                            HStack(spacing: 12) {
                                CoinIconView(symbol: h.coin, hlIconName: h.coin, iconSize: 28, isSpot: true)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(h.coin)
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundColor(.white)
                                    Text(String(format: "%.4f", h.balance))
                                        .font(.system(size: 11))
                                        .foregroundColor(Color(white: 0.4))
                                }
                                Spacer()
                                if h.usdValue > 0 {
                                    Text(String(format: "$%.2f", h.usdValue))
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundColor(Color(white: 0.6))
                                }
                                if selectedHolding?.coin == h.coin {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.hlGreen)
                                }
                            }
                        }
                        .listRowBackground(Color(white: 0.09))
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.hlBackground)
            .navigationTitle("Select Token")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showTokenPicker = false }
                        .foregroundColor(.hlGreen)
                }
            }
        }
    }

    // MARK: - Fetch

    private func fetchSpotHoldings() async {
        guard let address = wallet.connectedWallet?.address else {
            isLoading = false
            return
        }

        let body: [String: Any] = ["type": "spotClearinghouseState", "user": address]
        guard let data = try? await HyperliquidAPI.shared.post(
            url: URL(string: "https://api.hyperliquid.xyz/info")!,
            body: body
        ),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let balances = json["balances"] as? [[String: Any]]
        else {
            isLoading = false
            return
        }

        // Fetch mid prices for USD valuation
        let spotToPerpName: [String: String] = [
            "UBTC": "BTC", "UETH": "ETH", "USOL": "SOL",
            "UFART": "FARTCOIN", "UPUMP": "PUMP", "HPENGU": "PENGU",
            "UBONK": "BONK", "UENA": "ENA", "UMON": "MON",
            "UZEC": "ZEC", "MMOVE": "MOVE", "UDZ": "DZ",
        ]
        var midPrices: [String: Double] = [:]
        let midsBody: [String: Any] = ["type": "allMids"]
        if let midsData = try? await HyperliquidAPI.shared.post(
            url: URL(string: "https://api.hyperliquid.xyz/info")!, body: midsBody
        ), let mids = try? JSONSerialization.jsonObject(with: midsData) as? [String: String] {
            for (coin, priceStr) in mids {
                if let p = Double(priceStr) { midPrices[coin] = p }
            }
        }

        var result: [SpotHolding] = []
        for b in balances {
            guard let coin = b["coin"] as? String,
                  let totStr = b["total"] as? String,
                  let total = Double(totStr), total > 0
            else { continue }

            let token = b["token"] as? String ?? coin
            let priceCoin = spotToPerpName[coin] ?? coin
            let usd: Double
            if coin == "USDC" || coin == "USDH" || coin == "USDT" {
                usd = total
            } else if let price = midPrices[priceCoin], price > 0 {
                usd = total * price
            } else {
                usd = 0
            }
            result.append(SpotHolding(coin: coin, token: token, balance: total, usdValue: usd))
        }

        holdings = result.sorted { $0.usdValue > $1.usdValue }
        isLoading = false

        // Auto-select first holding if only one
        if holdings.count == 1 { selectedHolding = holdings.first }
    }

    // MARK: - Submit

    private func submitSend() async {
        guard let h = selectedHolding else { return }
        isSubmitting = true
        resultMessage = nil

        do {
            let cleanAmount = stripCommas(amount)
            let payload = try await TransactionSigner.signSpotSend(
                destination: destinationAddress,
                token: h.token,
                amount: cleanAmount
            )

            let response = try await TransactionSigner.postAction(payload)

            if let status = response["status"] as? String, status == "ok" {
                isSuccess = true
                resultMessage = "\(h.coin) sent successfully!"
                amount = ""
                await fetchSpotHoldings()
            } else if let err = response["error"] as? String {
                isSuccess = false
                resultMessage = err
            } else {
                isSuccess = false
                resultMessage = "Unexpected response"
            }
        } catch {
            isSuccess = false
            resultMessage = error.localizedDescription
        }

        isSubmitting = false
    }
}
