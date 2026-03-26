import SwiftUI

/// Detail sheet shown when tapping a position in the Positions tab.
/// Shows full position info + actions: Close Market, Close Limit, add TP/SL.
struct PositionDetailSheet: View {
    let position: PerpPosition
    let marketsVM: MarketsViewModel
    let onDismiss: () -> Void
    @ObservedObject private var walletMgr = WalletManager.shared

    // Close mode
    @State private var closeMode: CloseMode = .market
    @State private var closeLimitPrice = ""
    @State private var closeSize = ""     // empty = full close
    @State private var isPartialClose = false
    @State private var closePct: Double = 100  // 0..100 slider for partial close
    @State private var closeSizeInUSD = false  // toggle between token and USD for size input

    // TP / SL
    @State private var tpEnabled = false
    @State private var slEnabled = false
    @State private var tpPrice = ""
    @State private var slPrice = ""

    // State
    @State private var isSubmitting = false
    @State private var resultMessage: String?
    @State private var isSuccess = false
    @FocusState private var isCloseSizeFocused: Bool

    private enum CloseMode: String, CaseIterable {
        case market = "Market"
        case limit  = "Limit"
    }

    /// Resolve market for this position's coin
    private var market: Market? {
        marketsVM.markets.first { $0.asset.name == position.coin && !$0.isSpot }
    }

    private var assetIndex: Int { market?.index ?? 0 }
    private var szDecimals: Int { market?.asset.szDecimals ?? 4 }
    private var isHIP3: Bool { assetIndex >= 100000 }

    private var pnlPct: Double {
        position.entryPrice != 0
            ? (position.unrealizedPnl / (position.sizeAbs * position.entryPrice)) * 100
            : 0
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 16) {
                    // Header: coin + side + leverage
                    positionHeader

                    // Position details grid
                    positionInfoCard

                    // Close position section
                    closeSection
                        .id("closeSection")

                    // TP/SL section
                    tpSlSection

                    // Result message
                    if let msg = resultMessage {
                        HStack(spacing: 8) {
                            Image(systemName: isSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundColor(isSuccess ? .hlGreen : .tradingRed)
                            Text(msg)
                                .font(.system(size: 13))
                                .foregroundColor(isSuccess ? .hlGreen : .tradingRed)
                        }
                    }

                    Spacer()
                }
                .padding(.top, 8)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: isPartialClose) { _, on in
                if on {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        withAnimation { proxy.scrollTo("closeSection", anchor: .top) }
                    }
                }
            }
            .onChange(of: isCloseSizeFocused) { _, focused in
                if focused {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        withAnimation { proxy.scrollTo("closeSection", anchor: .top) }
                    }
                }
            }
            } // ScrollViewReader
            .background(Color.hlBackground.ignoresSafeArea())
            .keyboardDoneBar()
            .navigationTitle(position.coin)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { onDismiss() }
                        .foregroundColor(.hlGreen)
                }
            }
        }
    }

    // MARK: - Header

    private var positionHeader: some View {
        HStack(spacing: 10) {
            CoinIconView(symbol: position.coin, hlIconName: position.coin, iconSize: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(position.coin)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.white)
                    Text(position.isLong ? "LONG" : "SHORT")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(position.isLong ? .hlGreen : .tradingRed)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background((position.isLong ? Color.hlGreen : Color.tradingRed).opacity(0.15))
                        .cornerRadius(4)
                    Text("\(position.isCross ? "Cross" : "Iso") \(position.leverage)×\(walletMgr.isPortfolioMargin ? " · PM" : "")")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Color(white: 0.4))
                }
                Text(String(format: "%+.2f USDC (%+.2f%%)", position.unrealizedPnl, pnlPct))
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundColor(position.unrealizedPnl >= 0 ? .hlGreen : .tradingRed)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Info card

    private var positionInfoCard: some View {
        VStack(spacing: 10) {
            infoRow("Size", String(format: "%.4f %@", position.sizeAbs, position.coin))
            infoRow("Notional", String(format: "$%.2f", position.notional))
            Divider().background(Color(white: 0.15))
            infoRow("Entry Price", formatPrice(position.entryPrice))
            infoRow("Mark Price", formatPrice(position.markPrice))
            if let liq = position.liquidationPx {
                infoRow("Liq. Price", formatPrice(liq), valueColor: .orange)
            }
            Divider().background(Color(white: 0.15))
            infoRow("Unrealized PnL", String(format: "%+.2f USDC", position.unrealizedPnl),
                     valueColor: position.unrealizedPnl >= 0 ? .hlGreen : .tradingRed)
            if position.cumulativeFunding != 0 {
                infoRow("Funding", String(format: "%+.4f USDC", position.cumulativeFunding),
                         valueColor: position.cumulativeFunding >= 0 ? .tradingRed : .hlGreen)
            }
        }
        .padding(14)
        .background(Color(white: 0.09))
        .cornerRadius(12)
        .padding(.horizontal, 16)
    }

    // MARK: - Close section

    private var closeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Close Position")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.white)

            // Market / Limit picker
            Picker("Close Mode", selection: $closeMode) {
                ForEach(CloseMode.allCases, id: \.self) { m in
                    Text(m.rawValue).tag(m)
                }
            }
            .pickerStyle(.segmented)

            // Partial close toggle
            Toggle(isOn: $isPartialClose) {
                Text("Partial close")
                    .font(.system(size: 13))
                    .foregroundColor(Color(white: 0.6))
            }
            .tint(.hlGreen)
            .onChange(of: isPartialClose) { _, on in
                if on {
                    closePct = 100
                    closeSize = String(format: "%g", position.sizeAbs)
                }
            }

            if isPartialClose {
                // Size input with token/USD toggle
                HStack {
                    Text("Size")
                        .font(.system(size: 12))
                        .foregroundColor(Color(white: 0.5))
                    TextField(closeSizeInUSD
                              ? "Full: $\(String(format: "%.2f", position.sizeAbs * position.markPrice))"
                              : "Full: \(String(format: "%.\(szDecimals)f", position.sizeAbs))",
                              text: $closeSize)
                        .keyboardType(.decimalPad)
                        .focused($isCloseSizeFocused)
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.trailing)
                        .onChange(of: closeSize) { _, newVal in
                            if let val = Double(newVal.replacingOccurrences(of: ",", with: ".")),
                               position.sizeAbs > 0 {
                                if closeSizeInUSD {
                                    let tokenAmt = val / max(position.markPrice, 0.0001)
                                    closePct = min((tokenAmt / position.sizeAbs) * 100, 100).rounded()
                                } else {
                                    closePct = min((val / position.sizeAbs) * 100, 100).rounded()
                                }
                            }
                        }

                    // Token name / USD toggle
                    Button {
                        closeSizeInUSD.toggle()
                        // Convert current value
                        if let val = Double(closeSize.replacingOccurrences(of: ",", with: ".")) {
                            if closeSizeInUSD {
                                // Was token, now USD
                                closeSize = String(format: "%.2f", val * position.markPrice)
                            } else {
                                // Was USD, now token
                                let tokenAmt = val / max(position.markPrice, 0.0001)
                                closeSize = String(format: "%.\(szDecimals)f", tokenAmt)
                            }
                        }
                    } label: {
                        Text(closeSizeInUSD ? "USD" : position.coin)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.hlGreen)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color(white: 0.15))
                            .cornerRadius(6)
                    }
                }
                .padding(10)
                .background(Color(white: 0.07))
                .cornerRadius(8)

                // Slider
                Slider(value: $closePct, in: 1...100)
                    .tint(.tradingRed)
                    .onChange(of: closePct) { _, pct in
                        let sz = position.sizeAbs * pct / 100.0
                        if closeSizeInUSD {
                            closeSize = String(format: "%.2f", sz * position.markPrice)
                        } else {
                            let decimals = szDecimals
                            let factor = pow(10.0, Double(decimals))
                            let truncated = floor(sz * factor) / factor
                            closeSize = String(format: "%.\(decimals)f", truncated)
                        }
                    }

                // Quick % buttons
                HStack(spacing: 6) {
                    ForEach([25, 50, 75, 100], id: \.self) { pct in
                        Button {
                            closePct = Double(pct)
                        } label: {
                            Text("\(pct)%")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(Int(closePct) == pct ? .white : .tradingRed)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 5)
                                .background(
                                    Int(closePct) == pct
                                        ? Color.tradingRed
                                        : Color.tradingRed.opacity(0.12)
                                )
                                .cornerRadius(4)
                        }
                    }
                }
            }

            // Limit price input
            if closeMode == .limit {
                HStack {
                    Text("Limit Price")
                        .font(.system(size: 12))
                        .foregroundColor(Color(white: 0.5))
                    TextField("Price", text: $closeLimitPrice)
                        .keyboardType(.decimalPad)
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.trailing)
                }
                .padding(10)
                .background(Color(white: 0.07))
                .cornerRadius(8)
            }

            // Close button
            Button {
                Task { await closePosition() }
            } label: {
                HStack(spacing: 8) {
                    if isSubmitting {
                        ProgressView().tint(.white)
                    }
                    Image(systemName: "faceid")
                        .font(.system(size: 13))
                    Text(closeMode == .market ? "Close Market" : "Close Limit")
                }
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.tradingRed)
                .cornerRadius(10)
            }
            .disabled(isSubmitting || (closeMode == .limit && closeLimitPrice.isEmpty))
        }
        .padding(14)
        .background(Color(white: 0.09))
        .cornerRadius(12)
        .padding(.horizontal, 16)
    }

    // MARK: - TP/SL section

    private var tpSlSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Take Profit / Stop Loss")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.white)

            // TP
            Toggle(isOn: $tpEnabled) {
                Text("Take Profit")
                    .font(.system(size: 13))
                    .foregroundColor(.hlGreen)
            }
            .tint(.hlGreen)

            if tpEnabled {
                HStack {
                    Text("TP Price")
                        .font(.system(size: 12))
                        .foregroundColor(Color(white: 0.5))
                    TextField("Trigger price", text: $tpPrice)
                        .keyboardType(.decimalPad)
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.trailing)
                }
                .padding(10)
                .background(Color(white: 0.07))
                .cornerRadius(8)

                Button {
                    Task { await placeTPOrder() }
                } label: {
                    HStack(spacing: 6) {
                        if isSubmitting { ProgressView().tint(.black) }
                        Text("Place TP Order")
                    }
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(tpPrice.isEmpty ? Color.hlGreen.opacity(0.3) : Color.hlGreen)
                    .cornerRadius(8)
                }
                .disabled(isSubmitting || tpPrice.isEmpty)
            }

            Divider().background(Color(white: 0.15))

            // SL
            Toggle(isOn: $slEnabled) {
                Text("Stop Loss")
                    .font(.system(size: 13))
                    .foregroundColor(.tradingRed)
            }
            .tint(.tradingRed)

            if slEnabled {
                HStack {
                    Text("SL Price")
                        .font(.system(size: 12))
                        .foregroundColor(Color(white: 0.5))
                    TextField("Trigger price", text: $slPrice)
                        .keyboardType(.decimalPad)
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.trailing)
                }
                .padding(10)
                .background(Color(white: 0.07))
                .cornerRadius(8)

                Button {
                    Task { await placeSLOrder() }
                } label: {
                    HStack(spacing: 6) {
                        if isSubmitting { ProgressView().tint(.white) }
                        Text("Place SL Order")
                    }
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(slPrice.isEmpty ? Color.tradingRed.opacity(0.3) : Color.tradingRed)
                    .cornerRadius(8)
                }
                .disabled(isSubmitting || slPrice.isEmpty)
            }
        }
        .padding(14)
        .background(Color(white: 0.09))
        .cornerRadius(12)
        .padding(.horizontal, 16)
    }

    // MARK: - Actions

    private func closePosition() async {
        isSubmitting = true
        resultMessage = nil
        #if DEBUG
        print("[CLOSE] coin=\(position.coin) asset=\(assetIndex) vault=\(WalletManager.shared.activeVaultAddress ?? "none")")
        #endif
        do {
            let closeSz: Double
            let isFullClose: Bool
            if isPartialClose, let sz = Double(closeSize.replacingOccurrences(of: ",", with: ".")), sz > 0 {
                if closeSizeInUSD {
                    // Convert USD to token amount
                    closeSz = min(sz / max(position.markPrice, 0.0001), position.sizeAbs)
                } else {
                    closeSz = min(sz, position.sizeAbs)
                }
                isFullClose = (closeSz >= position.sizeAbs)
            } else {
                closeSz = position.sizeAbs
                isFullClose = true
            }

            // Close = opposite side order, reduceOnly
            let isBuy = !position.isLong  // close long = sell, close short = buy
            let price: Double
            let orderType: [String: Any]

            if closeMode == .market {
                // Market close with slippage
                let slippage = 0.01 // 1%
                price = isBuy
                    ? position.markPrice * (1 + slippage)
                    : position.markPrice * (1 - slippage)
                orderType = ["limit": ["tif": "Ioc"]]
            } else {
                guard let p = Double(closeLimitPrice.replacingOccurrences(of: ",", with: ".")), p > 0 else {
                    resultMessage = "Enter a valid limit price"
                    isSubmitting = false
                    return
                }
                price = p
                orderType = ["limit": ["tif": "Gtc"]]
            }

            let payload = try await TransactionSigner.signOrder(
                assetIndex: assetIndex,
                isBuy: isBuy,
                limitPrice: price,
                size: closeSz,
                reduceOnly: true,
                orderType: orderType,
                szDecimals: szDecimals,
                roundUp: isFullClose
            )
            let result = try await TransactionSigner.postAction(payload)
            parseResult(result, action: closeMode == .market ? "Position closed" : "Close order placed", autoDismiss: true)
            if isSuccess {
                if isHIP3 {
                    WalletManager.shared.refreshHIP3PositionsNow()
                } else {
                    WalletManager.shared.refreshMainPositionsNow()
                }
            }
        } catch {
            isSuccess = false
            resultMessage = error.localizedDescription
        }
        isSubmitting = false
    }

    private func placeTPOrder() async {
        isSubmitting = true
        resultMessage = nil
        do {
            guard let triggerPrice = Double(tpPrice.replacingOccurrences(of: ",", with: ".")), triggerPrice > 0 else {
                resultMessage = "Enter a valid TP price"
                isSubmitting = false
                return
            }

            // TP: close the full position when trigger is hit
            // Long position TP: sell when price >= trigger (tp)
            // Short position TP: buy when price <= trigger (tp)
            let isBuy = !position.isLong
            let triggerType = position.isLong ? "tp" : "tp"

            // Use trigger order format
            let orderType: [String: Any] = ["trigger": [
                "isMarket": true,
                "triggerPx": TransactionSigner.floatToWire(triggerPrice),
                "tpsl": triggerType
            ]]

            // For trigger orders, the limit price is the trigger price (market execution)
            let payload = try await TransactionSigner.signOrder(
                assetIndex: assetIndex,
                isBuy: isBuy,
                limitPrice: triggerPrice,
                size: position.sizeAbs,
                reduceOnly: true,
                orderType: orderType,
                szDecimals: szDecimals
            )
            let result = try await TransactionSigner.postAction(payload)
            parseResult(result, action: "TP order placed")
            if isSuccess && isHIP3 { WalletManager.shared.refreshHIP3PositionsNow() }
        } catch {
            isSuccess = false
            resultMessage = error.localizedDescription
        }
        isSubmitting = false
    }

    private func placeSLOrder() async {
        isSubmitting = true
        resultMessage = nil
        do {
            guard let triggerPrice = Double(slPrice.replacingOccurrences(of: ",", with: ".")), triggerPrice > 0 else {
                resultMessage = "Enter a valid SL price"
                isSubmitting = false
                return
            }

            let isBuy = !position.isLong
            let triggerType = position.isLong ? "sl" : "sl"

            let orderType: [String: Any] = ["trigger": [
                "isMarket": true,
                "triggerPx": TransactionSigner.floatToWire(triggerPrice),
                "tpsl": triggerType
            ]]

            let payload = try await TransactionSigner.signOrder(
                assetIndex: assetIndex,
                isBuy: isBuy,
                limitPrice: triggerPrice,
                size: position.sizeAbs,
                reduceOnly: true,
                orderType: orderType,
                szDecimals: szDecimals
            )
            let result = try await TransactionSigner.postAction(payload)
            parseResult(result, action: "SL order placed")
            if isSuccess && isHIP3 { WalletManager.shared.refreshHIP3PositionsNow() }
        } catch {
            isSuccess = false
            resultMessage = error.localizedDescription
        }
        isSubmitting = false
    }

    // MARK: - Helpers

    private func parseResult(_ result: [String: Any], action: String, autoDismiss: Bool = false) {
        print("[CLOSE-RESULT] \(result)")
        if let status = result["status"] as? String, status == "ok" {
            // Check inner statuses for errors
            if let response = result["response"] as? [String: Any],
               let data = response["data"] as? [String: Any],
               let statuses = data["statuses"] as? [Any],
               let first = statuses.first {
                // Status can be a dict with "error" key or a dict with "filled"/"resting" key
                if let errDict = first as? [String: Any], let err = errDict["error"] as? String {
                    isSuccess = false
                    resultMessage = err
                    return
                }
            }
            isSuccess = true
            resultMessage = action
            if autoDismiss {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    onDismiss()
                }
            }
        } else if let err = result["response"] as? String {
            isSuccess = false
            resultMessage = err
        } else {
            isSuccess = false
            resultMessage = "Failed: \(result)"
        }
    }

    private func infoRow(_ label: String, _ value: String, valueColor: Color = .white) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(Color(white: 0.5))
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(valueColor)
        }
    }

    private func formatPrice(_ price: Double) -> String {
        if price >= 1000 { return String(format: "%.2f", price) }
        if price >= 1 { return String(format: "%.4f", price) }
        return String(format: "%.6f", price)
    }
}
