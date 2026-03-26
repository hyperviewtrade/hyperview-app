import SwiftUI

// MARK: - TradingView — Full order form (Hyperliquid style)

struct TradingView: View {
    /// When true, strips navigation title, sheets, and symbol header (used inside ChartContainerView tabs)
    var embedded: Bool = false

    @EnvironmentObject var tradingVM:   TradingViewModel
    @EnvironmentObject var chartVM:     ChartViewModel
    @EnvironmentObject var marketsVM:   MarketsViewModel
    @EnvironmentObject var watchVM:     WatchlistViewModel
    @ObservedObject private var walletMgr = WalletManager.shared

    @State private var showWalletConnect = false
    @State private var showSymbolPicker  = false

    private enum Field: Int, CaseIterable { case size, limitPrice, tpPrice, slPrice }
    @FocusState private var focusedField: Field?

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if !embedded { walletBanner }
                if !embedded { symbolHeader }
                if !embedded { Divider().background(Color.hlSurface) }

                VStack(spacing: 12) {
                    sideSelector
                    orderTypePicker
                    leverageRow
                    sizeField          // includes quick size buttons
                    if tradingVM.orderType == .limit { limitPriceField }
                    if tradingVM.limitCrossesSpread  { crossSpreadWarning }
                    tpSlToggles
                    feeSummary
                    submitButton
                    if let result = tradingVM.lastOrderResult {
                        Text(result)
                            .font(.system(size: 13))
                            .foregroundColor(.hlGreen)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                }
                .padding(16)
            }
        }
        .background(Color.hlBackground.ignoresSafeArea())
        .scrollDismissesKeyboard(.interactively)
        // Keyboard Done bar is provided globally by KeyboardDoneBarSetup
        .modifier(TradingNavModifier(
            embedded: embedded,
            showWalletConnect: $showWalletConnect,
            showSymbolPicker: $showSymbolPicker,
            chartVM: chartVM,
            marketsVM: marketsVM
        ))
        .onAppear {
            tradingVM.selectedSymbol = chartVM.selectedSymbol
            tradingVM.currentPrice   = chartVM.livePrice
        }
        .onChange(of: chartVM.selectedSymbol) { _, sym   in tradingVM.selectedSymbol = sym }
        .onChange(of: chartVM.livePrice)      { _, price in tradingVM.currentPrice = price }
        .onChange(of: marketsVM.markets.count) {
            tradingVM.updateAvailableMargin(walletMgr.accountValue)
        }
    }

    // MARK: - Wallet banner

    private var walletBanner: some View {
        Group {
            if let wallet = walletMgr.connectedWallet {
                HStack(spacing: 8) {
                    Circle().fill(Color.hlGreen).frame(width: 7, height: 7)
                    Text(wallet.shortAddress)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.white)
                    Spacer()
                    Text(walletMgr.stakingTier.rawValue)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.hlGreen)
                    Button("Disconnect") { walletMgr.disconnect() }
                        .font(.system(size: 11))
                        .foregroundColor(.tradingRed)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.hlCardBackground)
            } else {
                Button { showWalletConnect = true } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "link.badge.plus")
                        Text("Connect Wallet to Trade")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundColor(.hlGreen)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.hlGreen.opacity(0.12))
                }
            }
        }
    }

    // MARK: - Symbol header

    private var symbolHeader: some View {
        HStack(spacing: 12) {
            Button { showSymbolPicker = true } label: {
                HStack(spacing: 6) {
                    CoinIconView(symbol: chartVM.displayBaseName, hlIconName: chartVM.hlCoinIconName)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Text(chartVM.displayName)
                                .font(.system(size: 18, weight: .bold))
                                .foregroundColor(.white)
                            Text(chartVM.marketTypeBadge)
                                .font(.system(size: 10))
                                .foregroundColor(.gray)
                        }
                        if let m = marketsVM.markets.first(where: { $0.symbol == tradingVM.selectedSymbol }) {
                            Text(String(format: "%@%.2f%%",
                                        m.isPositive ? "+" : "", m.change24h))
                                .font(.system(size: 11))
                                .foregroundColor(m.isPositive ? .hlGreen : .tradingRed)
                        }
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12))
                        .foregroundColor(Color(white: 0.45))
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 1) {
                Text(formatPrice(tradingVM.currentPrice))
                    .font(.system(size: 22, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                    .contentTransition(.numericText())
                    .animation(.easeInOut(duration: 0.2), value: tradingVM.currentPrice)
                Text("Mark Price")
                    .font(.system(size: 10))
                    .foregroundColor(.gray)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Side selector (Buy / Sell)
    // BUY: hlGreen background + white text
    // SELL: tradingRed background + white text

    private var sideSelector: some View {
        HStack(spacing: 0) {
            ForEach(TradingOrderSide.allCases, id: \.self) { s in
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { tradingVM.side = s }
                } label: {
                    Text(s.rawValue)
                        .font(.system(size: 15, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .foregroundColor(tradingVM.side == s ? .white : Color(white: 0.4))
                        .background(
                            tradingVM.side == s
                                ? (s == .buy ? Color.hlGreen : Color.tradingRed)
                                : Color.hlSurface
                        )
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Order type picker

    private var orderTypePicker: some View {
        HStack(spacing: 0) {
            ForEach(TradingOrderType.allCases) { type in
                Button { tradingVM.orderType = type } label: {
                    Text(type.rawValue)
                        .font(.system(size: 13,
                                      weight: tradingVM.orderType == type ? .semibold : .regular))
                        .foregroundColor(tradingVM.orderType == type ? .hlGreen : Color(white: 0.5))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(
                            tradingVM.orderType == type
                                ? Color.hlGreen.opacity(0.12)
                                : Color.hlCardBackground
                        )
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Leverage

    private var leverageRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Leverage")
                    .font(.system(size: 12))
                    .foregroundColor(Color(white: 0.5))
                Spacer()
                Text("\(Int(tradingVM.leverage))×")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(.hlGreen)
            }
            Slider(value: $tradingVM.leverage, in: 1...50, step: 1)
                .tint(.hlGreen)
                .contentShape(Rectangle())
                .simultaneousGesture(DragGesture(minimumDistance: 0))
                .onChange(of: tradingVM.leverage) { _, _ in
                    let g = UIImpactFeedbackGenerator(style: .light)
                    g.prepare()
                    g.impactOccurred()
                }
        }
        .padding(12)
        .background(Color.hlCardBackground)
        .cornerRadius(10)
    }

    // MARK: - Size input with quick size buttons

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
                TextField("0.00", text: $tradingVM.sizeUSD)
                    .keyboardType(.decimalPad)
                    .focused($focusedField, equals: .size)
                    .font(.system(size: 16, design: .monospaced))
                    .foregroundColor(.white)
                    .onChange(of: tradingVM.sizeUSD) { oldValue, newValue in
                        guard formatDecimalWithCommas(newValue) != newValue else { return }
                        let formatted = formatDecimalOnChange(oldValue: oldValue, newValue: newValue)
                        if formatted != newValue { tradingVM.sizeUSD = formatted }
                    }
                Spacer()
                if tradingVM.positionSize > 0 {
                    Text("\(String(format: "%.4f", tradingVM.positionSize)) \(chartVM.displayBaseName)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Color(white: 0.4))
                }
            }

            // Quick size buttons
            HStack(spacing: 6) {
                ForEach([10, 25, 50, 100], id: \.self) { pct in
                    Button {
                        let amount = walletMgr.accountValue * Double(pct) / 100.0
                        tradingVM.sizeUSD = formatDecimalWithCommas(String(format: "%.2f", amount))
                    } label: {
                        Text("\(pct)%")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Color(white: 0.7))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(Color.hlDivider)
                            .cornerRadius(6)
                    }
                }
            }
        }
        .padding(12)
        .background(Color.hlCardBackground)
        .cornerRadius(10)
    }

    // MARK: - Limit price

    private var limitPriceField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Limit Price")
                .font(.system(size: 12))
                .foregroundColor(Color(white: 0.5))
            HStack {
                TextField(String(format: "%.4f", tradingVM.currentPrice),
                          text: $tradingVM.limitPrice)
                    .keyboardType(.decimalPad)
                    .focused($focusedField, equals: .limitPrice)
                    .font(.system(size: 16, design: .monospaced))
                    .foregroundColor(.white)
                Spacer()
                Button("Market") {
                    tradingVM.limitPrice = String(format: "%.4f", tradingVM.currentPrice)
                }
                .font(.system(size: 12))
                .foregroundColor(Color(white: 0.45))
            }
        }
        .padding(12)
        .background(Color.hlCardBackground)
        .cornerRadius(10)
    }

    // MARK: - Cross-spread warning

    private var crossSpreadWarning: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
                .font(.system(size: 13))
            Text("Limit price crosses spread — order may fill immediately as taker")
                .font(.system(size: 12))
                .foregroundColor(.orange)
        }
        .padding(10)
        .background(Color.orange.opacity(0.1))
        .cornerRadius(8)
    }

    // MARK: - TP / SL

    private var tpSlToggles: some View {
        VStack(spacing: 10) {
            tpSlRow(label: "Take Profit", enabled: $tradingVM.tpEnabled,
                    price: $tradingVM.tpPrice,  color: .hlGreen)
            tpSlRow(label: "Stop Loss",   enabled: $tradingVM.slEnabled,
                    price: $tradingVM.slPrice,  color: .tradingRed)
        }
    }

    private func tpSlRow(label: String, enabled: Binding<Bool>,
                         price: Binding<String>, color: Color) -> some View {
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
                    .focused($focusedField, equals: label == "Take Profit" ? .tpPrice : .slPrice)
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(10)
                    .background(Color.hlSurface)
                    .cornerRadius(8)
            }
        }
        .padding(12)
        .background(Color.hlCardBackground)
        .cornerRadius(10)
    }

    // MARK: - Fee summary

    private var feeSummary: some View {
        VStack(spacing: 6) {
            feeRow("Notional Value",      formatUSD(tradingVM.notionalValue))
            feeRow(tradingVM.feeLabel,    formatUSD(tradingVM.totalFee))
            feeRow("Builder Fee (0.005%)", formatUSD(tradingVM.builderFeeAmt),
                   color: Color(white: 0.4))
            Divider().background(Color.hlDivider)
            feeRow("Slippage Tolerance",  String(format: "%.2f%%", tradingVM.slippagePct))
        }
        .padding(12)
        .background(Color.hlCardBackground)
        .cornerRadius(10)
    }

    private func feeRow(_ label: String, _ value: String,
                        color: Color = Color(white: 0.6)) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(Color(white: 0.45))
            Spacer()
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(color)
        }
    }

    // MARK: - Submit button
    // BUY → hlGreen bg + white text
    // SELL → tradingRed bg + white text
    // Disconnected → muted bg

    private var submitButton: some View {
        let isConnected = walletMgr.connectedWallet != nil
        let buttonColor: Color = {
            guard isConnected else { return Color(white: 0.25) }
            return tradingVM.side == .buy ? .hlGreen : .tradingRed
        }()

        return Button {
            if !isConnected { showWalletConnect = true }
            else            { Task { await tradingVM.submitOrder() } }
        } label: {
            Group {
                if tradingVM.isSubmitting {
                    HStack(spacing: 8) {
                        ProgressView().tint(.white)
                        Text(tradingVM.statusMessage ?? "Submitting…")
                    }
                } else {
                    Text(tradingVM.submitLabel)
                }
            }
            .font(.system(size: 16, weight: .bold))
            .foregroundColor(.white)        // always white on colored background
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(buttonColor)
            .cornerRadius(12)
        }
        .disabled(tradingVM.isSubmitting)
    }

    // MARK: - Formatters

    private func formatPrice(_ p: Double) -> String {
        if p >= 10_000 { return String(format: "%.1f", p) }
        if p >= 1_000  { return String(format: "%.2f", p) }
        if p >= 1      { return String(format: "%.4f", p) }
        return           String(format: "%.6f", p)
    }

    private func formatUSD(_ v: Double) -> String {
        if v == 0     { return "$0.00" }
        if v >= 1_000 { return String(format: "$%.2fK", v / 1_000) }
        return          String(format: "$%.4f", v)
    }

    // MARK: - Keyboard bar (chevrons + Done)

    private var tradingKeyboardBar: some View {
        HStack(spacing: 12) {
            Button {
                focusedField = focusedField.flatMap { Field(rawValue: $0.rawValue - 1) }
            } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(focusedField == .size ? Color(white: 0.3) : .white)
            }
            .disabled(focusedField == .size)

            Button {
                focusedField = focusedField.flatMap { Field(rawValue: $0.rawValue + 1) }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(focusedField == .slPrice ? Color(white: 0.3) : .white)
            }
            .disabled(focusedField == .slPrice)

            Spacer()

            Button("Done") {
                focusedField = nil
            }
            .fontWeight(.semibold)
            .foregroundColor(.hlGreen)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(white: 0.12))
    }
}

// MARK: - Conditional navigation modifier

/// Applies navigation title + sheets only when NOT embedded in ChartContainerView tabs.
private struct TradingNavModifier: ViewModifier {
    let embedded: Bool
    @Binding var showWalletConnect: Bool
    @Binding var showSymbolPicker: Bool
    let chartVM: ChartViewModel
    let marketsVM: MarketsViewModel

    func body(content: Content) -> some View {
        if embedded {
            content
        } else {
            content
                .navigationTitle("Trade")
                .navigationBarTitleDisplayMode(.inline)
                .sheet(isPresented: $showWalletConnect) { WalletConnectView() }
                .sheet(isPresented: $showSymbolPicker) {
                    SymbolPickerView()
                        .environmentObject(chartVM)
                        .environmentObject(marketsVM)
                }
        }
    }
}
