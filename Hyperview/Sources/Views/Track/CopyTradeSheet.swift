import SwiftUI

/// Quick copy-trade sheet — pre-filled with the tracked position's direction,
/// leverage, and market. User just enters size and taps execute.
struct CopyTradeSheet: View {
    let position: TrackedPosition
    let market: Market
    let alias: String?

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var walletMgr = WalletManager.shared

    // Form state
    @State private var sizeUSD = ""
    @State private var leverage: Double
    @State private var tpEnabled = false
    @State private var slEnabled = false
    @State private var tpPrice = ""
    @State private var slPrice = ""

    // Execution state
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var showSuccess = false
    @State private var resultText: String?

    @FocusState private var focusedField: Field?
    private enum Field: Int { case size, tp, sl }

    @AppStorage("hl_slippage") private var slippagePct: Double = 0.1
    @AppStorage("hl_hideSlippageWarning") private var hideSlippageWarning = false
    @State private var showSlippageWarning = false
    @State private var pendingSlippagePct: Double = 0
    @State private var pendingBookDepthUSD: Double = 0

    init(position: TrackedPosition, market: Market, alias: String?) {
        self.position = position
        self.market = market
        self.alias = alias
        let ml = Double(market.asset.maxLeverage ?? 50)
        _leverage = State(initialValue: min(Double(position.leverage), ml))
    }

    private var isBuy: Bool { position.isLong }
    private var maxLev: Int { market.asset.maxLeverage ?? 50 }
    private var sizeValue: Double { Double(sizeUSD.replacingOccurrences(of: ",", with: "")) ?? 0 }
    private var tokenSize: Double {
        guard position.markPrice > 0 else { return 0 }
        // Size USD = notional. Leverage only affects margin, not trade size.
        return sizeValue / position.markPrice
    }
    private var notional: Double { tokenSize * position.markPrice }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    // Who you're copying
                    copyHeader

                    // Direction (locked)
                    directionBadge

                    // Leverage slider
                    leverageRow

                    // Size input
                    sizeField

                    // TP / SL
                    tpSlSection

                    // Execute button
                    executeButton

                    // Result
                    if let err = errorMessage {
                        Text(err)
                            .font(.system(size: 12))
                            .foregroundColor(.tradingRed)
                            .multilineTextAlignment(.center)
                    }
                    if let result = resultText {
                        Text(result)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.hlGreen)
                    }
                }
                .padding(16)
            }
            .background(Color.hlBackground.ignoresSafeArea())
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Copy Trade")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(.hlGreen)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if focusedField != nil {
                    keyboardToolbar
                }
            }
            .overlay {
                if showSlippageWarning {
                    SlippageWarningView(
                        slippagePct: pendingSlippagePct,
                        orderSizeUSD: notional,
                        volume24h: market.volume24h,
                        bookDepthUSD: pendingBookDepthUSD,
                        coin: position.coin,
                        isBuy: isBuy,
                        onDismiss: { showSlippageWarning = false },
                        onProceed: {
                            showSlippageWarning = false
                            Task { await execute() }
                        },
                        onTWAP: { duration in
                            showSlippageWarning = false
                            Task { await executeTWAP(duration: duration) }
                        }
                    )
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.2), value: showSlippageWarning)
                }
            }
        }
    }

    // MARK: - Keyboard Toolbar

    private var keyboardToolbar: some View {
        HStack(spacing: 16) {
            Button(action: { moveFocus(-1) }) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 16, weight: .medium))
            }
            Button(action: { moveFocus(1) }) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 16, weight: .medium))
            }
            Spacer()
            Button("Done") {
                focusedField = nil
            }
            .font(.system(size: 16, weight: .semibold))
        }
        .foregroundColor(.hlGreen)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(white: 0.12))
    }

    // MARK: - Copy Header

    private var copyHeader: some View {
        HStack(spacing: 10) {
            CoinIconView(symbol: market.displayName, hlIconName: market.hlCoinIconName)

            VStack(alignment: .leading, spacing: 2) {
                Text(market.displaySymbol)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
                HStack(spacing: 4) {
                    Text("Copying")
                        .font(.system(size: 11))
                        .foregroundColor(Color(white: 0.4))
                    Text(alias ?? position.shortAddress)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(.hlGreen)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(market.formattedPrice)
                    .font(.system(size: 18, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                Text("Mark")
                    .font(.system(size: 9))
                    .foregroundColor(Color(white: 0.4))
            }
        }
        .padding(14)
        .background(Color.hlCardBackground)
        .cornerRadius(12)
    }

    // MARK: - Direction Badge

    private var directionBadge: some View {
        HStack {
            Text(isBuy ? "LONG" : "SHORT")
                .font(.system(size: 15, weight: .black))
                .foregroundColor(.white)
            Spacer()
            Text("Entry: \(position.formattedEntry)")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(Color(white: 0.5))
            Text("•")
                .foregroundColor(Color(white: 0.3))
            Text("\(position.leverage)×")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(Color(white: 0.5))
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .background(isBuy ? Color.hlGreen.opacity(0.15) : Color.tradingRed.opacity(0.15))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isBuy ? Color.hlGreen.opacity(0.3) : Color.tradingRed.opacity(0.3), lineWidth: 1)
        )
        .cornerRadius(10)
    }

    // MARK: - Leverage

    private var leverageRow: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Leverage")
                    .font(.system(size: 12))
                    .foregroundColor(Color(white: 0.5))
                Spacer()
                Text("\(Int(leverage))×")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(.hlGreen)
            }
            Slider(value: $leverage, in: 1...Double(maxLev), step: 1)
                .tint(.hlGreen)
                .simultaneousGesture(DragGesture(minimumDistance: 0))
        }
        .padding(12)
        .background(Color.hlCardBackground)
        .cornerRadius(10)
    }

    // MARK: - Size Input

    private var sizeField: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Size (USD)")
                    .font(.system(size: 12))
                    .foregroundColor(Color(white: 0.5))
                Spacer()
                Text("Avail: \(String(format: "$%.2f", walletMgr.accountValue))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Color(white: 0.4))
            }

            HStack {
                TextField("0.00", text: $sizeUSD)
                    .keyboardType(.decimalPad)
                    .focused($focusedField, equals: .size)
                    .font(.system(size: 20, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white)
                    .onChange(of: sizeUSD) { oldValue, newValue in
                        let formatted = formatDecimalOnChange(oldValue: oldValue, newValue: newValue)
                        if formatted != newValue { sizeUSD = formatted }
                    }
                Spacer()
                if tokenSize > 0 {
                    Text("\(String(format: "%.4f", tokenSize)) \(position.coin)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Color(white: 0.4))
                }
            }

            // Quick size buttons
            HStack(spacing: 6) {
                ForEach([25, 50, 75, 100], id: \.self) { pct in
                    Button {
                        let amount = walletMgr.accountValue * Double(pct) / 100.0
                        sizeUSD = formatDecimalWithCommas(String(format: "%.2f", amount))
                    } label: {
                        Text("\(pct)%")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Color(white: 0.7))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(Color(white: 0.12))
                            .cornerRadius(6)
                    }
                }
            }
        }
        .padding(12)
        .background(Color.hlCardBackground)
        .cornerRadius(10)
    }

    // MARK: - TP / SL

    private var tpSlSection: some View {
        VStack(spacing: 10) {
            tpSlRow(label: "Take Profit", enabled: $tpEnabled,
                    price: $tpPrice, color: .hlGreen, field: .tp)
            tpSlRow(label: "Stop Loss", enabled: $slEnabled,
                    price: $slPrice, color: .tradingRed, field: .sl)
        }
    }

    private func tpSlRow(label: String, enabled: Binding<Bool>,
                         price: Binding<String>, color: Color, field: Field) -> some View {
        VStack(spacing: 6) {
            HStack {
                Toggle(isOn: enabled) {
                    Text(label)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(enabled.wrappedValue ? color : Color(white: 0.5))
                }
                .tint(color)
            }
            if enabled.wrappedValue {
                TextField("Target price", text: price)
                    .keyboardType(.decimalPad)
                    .focused($focusedField, equals: field)
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(10)
                    .background(Color(white: 0.08))
                    .cornerRadius(8)
            }
        }
        .padding(12)
        .background(Color.hlCardBackground)
        .cornerRadius(10)
    }

    // MARK: - Fee Summary

    private var feeSummary: some View {
        VStack(spacing: 6) {
            feeRow("Notional", formatUSD(notional))
            feeRow("Fee (taker 0.035% + builder 0.005%)", formatUSD(notional * 0.0004))
            feeRow("Slippage", String(format: "%.2f%%", slippagePct))
        }
        .padding(12)
        .background(Color.hlCardBackground)
        .cornerRadius(10)
    }

    private func feeRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(Color(white: 0.45))
            Spacer()
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Color(white: 0.6))
        }
    }

    // MARK: - Execute Button

    private var executeButton: some View {
        let isConnected = walletMgr.connectedWallet != nil
        let color: Color = isBuy ? .hlGreen : .tradingRed

        return Button {
            Task { await checkSlippageAndExecute() }
        } label: {
            Group {
                if isSubmitting {
                    HStack(spacing: 8) {
                        ProgressView().tint(.white)
                        Text("Signing…")
                    }
                } else if showSuccess {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                        Text("Filled!")
                    }
                } else {
                    Text(isConnected
                         ? "\(isBuy ? "Long" : "Short") \(position.coin)"
                         : "Connect Wallet")
                }
            }
            .font(.system(size: 16, weight: .bold))
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(isConnected ? color : Color(white: 0.25))
            .cornerRadius(12)
        }
        .disabled(isSubmitting || showSuccess)
    }

    // MARK: - Execute Order

    private func execute() async {
        guard walletMgr.connectedWallet != nil else { return }
        guard sizeValue > 0 else {
            errorMessage = "Enter a size"
            return
        }
        guard tokenSize > 0 else {
            errorMessage = "Invalid size"
            return
        }

        isSubmitting = true
        errorMessage = nil

        do {
            // Market order with slippage
            let slip = slippagePct / 100.0
            let price = isBuy
                ? position.markPrice * (1 + slip)
                : position.markPrice * (1 - slip)

            let payload = try await TransactionSigner.signOrder(
                assetIndex: market.index,
                isBuy: isBuy,
                limitPrice: price,
                size: tokenSize,
                reduceOnly: false,
                orderType: ["limit": ["tif": "Ioc"]],
                szDecimals: market.asset.szDecimals
            )

            let result = try await TransactionSigner.postAction(payload)

            // Parse response
            if let status = result["status"] as? String, status == "err",
               let errMsg = result["response"] as? String {
                errorMessage = errMsg
                HapticsManager.notification(.error)
            } else if let response = result["response"] as? [String: Any] {
                let data = (response["data"] ?? response["payload"]) as? [String: Any]
                let statuses = data?["statuses"] as? [Any]
                let first = statuses?.first

                if let firstDict = first as? [String: Any], let filled = firstDict["filled"] as? [String: Any] {
                    let fillPx = filled["avgPx"] as? String ?? ""
                    let totalSz = filled["totalSz"] as? String ?? ""
                    resultText = "\(isBuy ? "LONG" : "SHORT") \(totalSz) \(position.coin) @ $\(fillPx)"
                    showSuccess = true
                    HapticsManager.notification(.success)

                    // Auto-dismiss after success
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { dismiss() }
                } else if let firstDict = first as? [String: Any], let error = firstDict["error"] as? String {
                    errorMessage = error
                    HapticsManager.notification(.error)
                } else {
                    errorMessage = "Unexpected response"
                    HapticsManager.notification(.error)
                }
            }

            // Force immediate position refresh after successful order
            if showSuccess {
                if market.index >= 100000 {
                    WalletManager.shared.refreshHIP3PositionsNow()
                } else {
                    WalletManager.shared.refreshMainPositionsNow()
                }
            }
        } catch {
            errorMessage = error.localizedDescription
            HapticsManager.notification(.error)
        }

        isSubmitting = false
    }

    // MARK: - Focus Navigation

    private func moveFocus(_ delta: Int) {
        let fields: [Field] = [.size, .tp, .sl]
        guard let current = focusedField, let idx = fields.firstIndex(of: current) else { return }
        let next = idx + delta
        if fields.indices.contains(next) {
            focusedField = fields[next]
        }
    }

    // MARK: - Helpers

    private func formatUSD(_ v: Double) -> String {
        if v == 0 { return "$0.00" }
        if v >= 1_000 { return String(format: "$%.2fK", v / 1_000) }
        return String(format: "$%.2f", v)
    }

    // MARK: - Slippage Check

    private func checkSlippageAndExecute() async {
        guard tokenSize > 0, !hideSlippageWarning else {
            await execute()
            return
        }

        // Fetch order book to check slippage
        do {
            let book = try await HyperliquidAPI.shared.fetchOrderBook(coin: market.apiCoin)
            if let result = book.estimateSlippage(isBuy: isBuy, sizeTokens: tokenSize),
               result.slippagePct > 0.05 {
                pendingSlippagePct = result.slippagePct
                let levels = isBuy ? book.asks : book.bids
                pendingBookDepthUSD = levels.reduce(0) { $0 + $1.size * $1.price }
                showSlippageWarning = true
                return
            }
        } catch { }

        // No significant slippage or book unavailable — proceed
        await execute()
    }

    /// Execute as TWAP order with the recommended duration
    private func executeTWAP(duration: Int) async {
        guard walletMgr.connectedWallet != nil, tokenSize > 0 else { return }

        isSubmitting = true
        errorMessage = nil

        do {
            let payload = try await TransactionSigner.signTwapOrder(
                assetIndex: market.index,
                isBuy: isBuy,
                size: tokenSize,
                reduceOnly: false,
                durationMinutes: duration,
                randomize: false,
                szDecimals: market.asset.szDecimals
            )
            let result = try await TransactionSigner.postAction(payload)

            if let status = result["status"] as? String, status == "err",
               let errMsg = result["response"] as? String {
                errorMessage = errMsg
                HapticsManager.notification(.error)
            } else {
                resultText = "TWAP \(isBuy ? "LONG" : "SHORT") \(position.coin) over \(TWAPRecommendation.formatDuration(duration))"
                showSuccess = true
                HapticsManager.notification(.success)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { dismiss() }
            }
        } catch {
            errorMessage = error.localizedDescription
            HapticsManager.notification(.error)
        }

        isSubmitting = false
    }
}
