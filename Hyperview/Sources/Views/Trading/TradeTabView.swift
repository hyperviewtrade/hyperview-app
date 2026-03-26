import SwiftUI

/// Split-view trade tab: mini order book (left) + compact trade form (right)
/// Bottom section: scrollable tabs (Balances, Positions, Open Orders, Trade History, Funding)
struct TradeTabView: View {
    @EnvironmentObject var tradingVM:  TradingViewModel
    @EnvironmentObject var chartVM:    ChartViewModel
    @EnvironmentObject var marketsVM:  MarketsViewModel
    @EnvironmentObject var watchVM:    WatchlistViewModel
    @ObservedObject private var walletMgr = WalletManager.shared

    @FocusState private var focusedField: TradeField?
    @State private var showWalletConnect = false
    @State private var showLeveragePicker = false
    @State private var selectedPosition: PerpPosition?
    @State private var showPositionDetail = false
    @State private var sizeInToken = false   // false = USD, true = token (BTC, ETH...)
    @State private var sizePct: Double = 0   // 0..100 slider value

    // Slippage warning
    @State private var showSlippageWarning = false
    @State private var pendingSlippagePct: Double = 0
    @State private var pendingBookDepthUSD: Double = 0
    @AppStorage("hl_hideSlippageWarning") private var hideSlippageWarning = false

    private let haptic = UIImpactFeedbackGenerator(style: .light)

    private enum TradeField: Int { case size, limitPrice, tpPrice, slPrice, twapHours, twapMinutes }

    /// Max leverage for the currently selected market
    private var maxLeverage: Int {
        marketsVM.markets
            .first { $0.symbol == chartVM.selectedSymbol }?
            .asset.maxLeverage ?? 50
    }

    /// Whether the current market is spot (no leverage, no long/short)
    private var isSpotMarket: Bool {
        currentMarket?.isSpot ?? false
    }

    /// The currently selected market object
    private var currentMarket: Market? {
        marketsVM.markets.first { $0.symbol == chartVM.selectedSymbol }
    }

    /// Internal base token name for spot (e.g. "UBTC", "HYPE") — used to look up spot balance
    private var spotBaseCoin: String {
        currentMarket?.baseName ?? ""
    }

    /// Quote currency display name for the current market (e.g. "USDC", "USDH")
    private var spotQuoteName: String {
        if let q = currentMarket?.quoteName, !q.isEmpty { return q }
        return "USD"
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    // ── Top: Order Book + Trade Form ──
                    HStack(alignment: .top, spacing: 0) {
                        miniOrderBook
                            .frame(width: UIScreen.main.bounds.width * 0.40)

                        Divider().background(Color(white: 0.15))

                        tradeForm
                            .frame(maxWidth: .infinity)
                    }

                    Divider().background(Color(white: 0.12)).padding(.vertical, 4)

                    // ── Bottom tabs bar ──
                    bottomTabBar

                    // ── Bottom tab content ──
                    bottomTabContent
                        .frame(minHeight: 120, alignment: .top)

                    // PM balances polling (invisible, always active)
                    pmBalancesTask
                }
            }
            .onChange(of: focusedField) { _, field in
                guard let field else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo(field, anchor: .center)
                    }
                }
            }
        }
        .background(Color.hlBackground)
        .scrollDismissesKeyboard(.interactively)
        // Keyboard Done bar is provided globally by KeyboardDoneBarSetup
        .sheet(isPresented: $showWalletConnect) { WalletConnectView() }
        .overlay {
            if showSlippageWarning {
                SlippageWarningView(
                    slippagePct: pendingSlippagePct,
                    orderSizeUSD: tradingVM.notionalValue,
                    volume24h: currentMarket?.volume24h ?? 0,
                    bookDepthUSD: pendingBookDepthUSD,
                    coin: tradingVM.displayCoinName.isEmpty ? tradingVM.selectedSymbol : tradingVM.displayCoinName,
                    isBuy: tradingVM.side == .buy,
                    onDismiss: { showSlippageWarning = false },
                    onProceed: {
                        showSlippageWarning = false
                        executeOrder()
                    },
                    onTWAP: { duration in
                        showSlippageWarning = false
                        executeTWAP(duration: duration)
                    }
                )
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.2), value: showSlippageWarning)
            }
        }
        .onAppear {
            tradingVM.selectedSymbol = chartVM.selectedSymbol
            tradingVM.currentPrice = chartVM.livePrice
            syncMarketContext()
            if tradingVM.leverage > Double(maxLeverage) {
                tradingVM.leverage = Double(maxLeverage)
            }
            // Sync leverage/margin mode from existing position on first load
            let coinKey = chartVM.selectedSymbol.components(separatedBy: "/").first ?? chartVM.selectedSymbol
            if let existingPos = WalletManager.shared.activePositions.first(where: { $0.coin == coinKey }) {
                tradingVM.isCross = existingPos.isCross
                tradingVM.leverage = Double(existingPos.leverage)
            }
            Task { await tradingVM.fetchBottomTabData() }
        }
        .onChange(of: chartVM.selectedSymbol) { _, sym in
            tradingVM.selectedSymbol = sym
            syncMarketContext()
            let ml = currentMarket?.asset.maxLeverage ?? 50
            if tradingVM.leverage > Double(ml) { tradingVM.leverage = Double(ml) }
            // Sync margin mode from existing position (if any)
            let coinKey = sym.components(separatedBy: "/").first ?? sym
            if let existingPos = WalletManager.shared.activePositions.first(where: { $0.coin == coinKey }) {
                tradingVM.isCross = existingPos.isCross
                tradingVM.leverage = Double(existingPos.leverage)
            }
            // Disable TP/SL when switching to spot
            if currentMarket?.isSpot == true {
                tradingVM.tpEnabled = false
                tradingVM.slEnabled = false
            }
            // Reset size slider
            sizePct = 0
            // Default to stablecoin mode on all markets
            sizeInToken = false
        }
        .onChange(of: chartVM.livePrice) { _, price in
            // Only update if price changed meaningfully (avoid constant re-renders)
            if abs(price - tradingVM.currentPrice) / max(tradingVM.currentPrice, 1) > 0.0001 {
                tradingVM.currentPrice = price
            }
        }
        .onChange(of: sizeInToken) { _, val in tradingVM.sizeIsToken = val }
        .onChange(of: tradingVM.side) { _, _ in
            if sizePct > 0 {
                applySizePct(sizePct)
            } else {
                tradingVM.sizeUSD = ""
            }
        }
        .onChange(of: tradingVM.bottomTab) { _, _ in
            Task { await tradingVM.fetchBottomTabData() }
        }
    }

    // MARK: - Mini Order Book (left side)

    private var miniOrderBook: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Price")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(Color(white: 0.4))
                Spacer()
                Text("Size (USD)")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(Color(white: 0.4))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)

            if let book = chartVM.orderBook {
                let rawAsks = book.asks.lazy.filter { $0.size > 0 }.prefix(8).reversed()
                let asksArray = Array(rawAsks)
                let rawBids = Array(book.bids.lazy.filter { $0.size > 0 }.prefix(8))
                let maxSize = max(
                    asksArray.reduce(0.0) { max($0, $1.size) },
                    rawBids.reduce(0.0) { max($0, $1.size) }
                )

                VStack(spacing: 0) {
                    ForEach(Array(asksArray.enumerated()), id: \.offset) { _, level in
                        miniBookRow(level: level, isBid: false, maxSize: maxSize)
                    }

                    HStack {
                        let bestAsk = book.asks.first(where: { $0.size > 0 })?.price ?? 0
                        let bestBid = book.bids.first(where: { $0.size > 0 })?.price ?? 0
                        let spread = bestAsk > 0 && bestBid > 0 ? bestAsk - bestBid : 0
                        let spreadPct = bestBid > 0 ? (spread / bestBid) * 100 : 0
                        let spreadStr: String = {
                            if spread >= 1 { return String(format: "%.0f", spread) }
                            if spread >= 0.01 { return String(format: "%.2f", spread) }
                            return String(format: "%.4f", spread)
                        }()
                        Text("Spread")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(Color(white: 0.4))
                        Text(spreadStr)
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                        Text(String(format: "%.3f%%", spreadPct))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(Color(white: 0.5))
                        Spacer()
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color(white: 0.1))

                    ForEach(Array(rawBids.enumerated()), id: \.offset) { _, level in
                        miniBookRow(level: level, isBid: true, maxSize: maxSize)
                    }
                }
            } else {
                ProgressView().tint(Color(white: 0.3))
                    .frame(maxHeight: .infinity)
            }
        }
        .task { await chartVM.refreshOrderBook() }
    }

    private func miniBookRow(level: OrderBookLevel, isBid: Bool, maxSize: Double) -> some View {
        let color = isBid ? Color.hlGreen : Color.tradingRed
        let barFrac = CGFloat(level.size / max(maxSize, 0.001))

        return HStack(spacing: 0) {
            Text(formatPrice(level.price))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(color)
            Spacer()
            Text(formatSize(level.size * level.price))
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(Color(white: 0.5))
        }
        .padding(.horizontal, 6)
        .frame(height: 20)
        .background(
            GeometryReader { geo in
                HStack(spacing: 0) {
                    Spacer()
                    color.opacity(0.12)
                        .frame(width: geo.size.width * barFrac)
                }
            }
        )
        .contentShape(Rectangle())
        .onTapGesture {
            tradingVM.orderType = .limit
            tradingVM.limitPrice = formatPrice(level.price)
        }
    }

    // MARK: - Trade Form (right side)

    private var tradeForm: some View {
        VStack(spacing: 8) {
            // Available balance
            HStack {
                if isSpotMarket && tradingVM.side == .sell {
                    let tokenBal = walletMgr.spotTokenAvailable[spotBaseCoin] ?? 0
                    Text("Avbl. (\(chartVM.displayBaseName))")
                        .font(.system(size: 10))
                        .foregroundColor(Color(white: 0.4))
                    Spacer()
                    Text(String(format: "%.\(tradingVM.szDecimals)f", tokenBal))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(.white)
                } else {
                    // Buy spot or perp trading: show unified USDC balance
                    Text("Avbl. (USDC)")
                        .font(.system(size: 10))
                        .foregroundColor(Color(white: 0.4))
                    Spacer()
                    Text(String(format: "%.2f", unifiedUSDCBalance))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(.white)
                }
            }

            // Order type
            orderTypePicker

            // Side selector: Long/Short for perps, Buy/Sell for spot
            if isSpotMarket {
                spotSideSelector
            } else {
                sideSelector
                HStack(spacing: 8) {
                    marginModeButton
                    leverageButton
                    accountModeButton
                }
            }

            // Size input
            sizeInput

            // Limit price (only for limit orders, not TWAP)
            if tradingVM.orderType == .limit {
                limitPriceInput
            }

            // Quick % buttons + slider
            HStack(spacing: 6) {
                ForEach([25, 50, 75, 100], id: \.self) { pct in
                    Button {
                        sizePct = Double(pct)
                        haptic.impactOccurred()
                        applySizePct(Double(pct))
                    } label: {
                        Text("\(pct)%")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(Int(sizePct) == pct
                                ? .white
                                : (tradingVM.side == .buy ? .hlGreen : .tradingRed))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                            .background(
                                Int(sizePct) == pct
                                    ? (tradingVM.side == .buy ? Color.hlGreen : Color.tradingRed)
                                    : (tradingVM.side == .buy ? Color.hlGreen : Color.tradingRed).opacity(0.12)
                            )
                            .cornerRadius(4)
                    }
                }
            }
            sizePercentSlider

            // TWAP settings
            if tradingVM.orderType == .twap {
                twapSettings
            }

            // TP/SL toggles (perps only, not for TWAP)
            if !isSpotMarket && tradingVM.orderType != .twap {
                tpSlSection

                // Reduce Only toggle (disabled for spot markets)
                if !isSpotMarket {
                HStack {
                    Text("Reduce Only")
                        .font(.system(size: 11))
                        .foregroundColor(Color(white: 0.4))
                    Spacer()
                    Toggle("", isOn: $tradingVM.reduceOnly)
                        .labelsHidden()
                        .scaleEffect(0.7)
                        .tint(.hlGreen)
                }
                } // end if !isSpotMarket
            }

            // Submit button
            submitButton

            // Status / error feedback
            if let error = tradingVM.errorMessage {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundColor(.tradingRed)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if tradingVM.showSuccess, let result = tradingVM.lastOrderResult {
                Text(result)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.hlGreen)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                            tradingVM.showSuccess = false
                            tradingVM.lastOrderResult = nil
                        }
                    }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    // MARK: - Margin Mode button

    @State private var showMarginModePicker = false
    @State private var isUpdatingMarginMode = false

    private var marginModeButton: some View {
        Button { showMarginModePicker = true } label: {
            Text(tradingVM.isCross ? "Cross" : "Isolated")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.hlGreen)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color(white: 0.09))
                .cornerRadius(8)
        }
        .sheet(isPresented: $showMarginModePicker) {
            marginModeSheet
                .presentationDetents([.height(260)])
                .presentationDragIndicator(.visible)
        }
    }

    private var marginModeSheet: some View {
        VStack(spacing: 16) {
            Text("Margin Mode")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)
                .padding(.top, 8)

            VStack(spacing: 10) {
                marginModeOption(
                    title: "Cross",
                    description: "All cross positions share the same cross margin as collateral.",
                    isSelected: tradingVM.isCross,
                    action: { tradingVM.isCross = true }
                )
                marginModeOption(
                    title: "Isolated",
                    description: "Manage your risk by restricting the amount of margin allocated to each position.",
                    isSelected: !tradingVM.isCross,
                    action: { tradingVM.isCross = false }
                )
            }
            .padding(.horizontal, 16)

            Button {
                isUpdatingMarginMode = true
                Task {
                    let _ = await tradingVM.updateLeverage()
                    await MainActor.run {
                        isUpdatingMarginMode = false
                        showMarginModePicker = false
                    }
                }
            } label: {
                if isUpdatingMarginMode {
                    ProgressView()
                        .tint(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.hlGreen.opacity(0.6))
                        .cornerRadius(10)
                } else {
                    Text("Confirm")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.hlGreen)
                        .cornerRadius(10)
                }
            }
            .disabled(isUpdatingMarginMode)
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 16)
        .background(Color(white: 0.08))
    }

    private func marginModeOption(title: String, description: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: {
            action()
            haptic.impactOccurred()
        }) {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isSelected ? .hlGreen : Color(white: 0.3))
                    .font(.system(size: 20))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                    Text(description)
                        .font(.system(size: 11))
                        .foregroundColor(Color(white: 0.5))
                        .lineLimit(2)
                }
                Spacer()
            }
            .padding(12)
            .background(isSelected ? Color.hlGreen.opacity(0.08) : Color(white: 0.06))
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color.hlGreen.opacity(0.3) : Color(white: 0.12), lineWidth: 1)
            )
        }
    }

    // MARK: - Leverage button

    private var leverageButton: some View {
        Button { showLeveragePicker = true } label: {
            HStack {
                Text("\(Int(tradingVM.leverage))x")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundColor(.hlGreen)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9))
                    .foregroundColor(Color(white: 0.3))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color(white: 0.09))
            .cornerRadius(8)
        }
        .sheet(isPresented: $showLeveragePicker) {
            leveragePickerSheet
                .presentationDetents([.height(280)])
                .presentationDragIndicator(.visible)
                .onAppear { leverageSliderValue = tradingVM.leverage }
        }
    }

    /// Local continuous slider value — snapped to Int only for display/commit
    @State private var leverageSliderValue: Double = 1

    private var leveragePickerSheet: some View {
        VStack(spacing: 16) {
            Text("Leverage")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)
                .padding(.top, 8)

            Text("\(Int(leverageSliderValue))x")
                .font(.system(size: 36, weight: .heavy, design: .monospaced))
                .foregroundColor(.hlGreen)

            Slider(value: $leverageSliderValue, in: 1...Double(maxLeverage))
                .tint(.hlGreen)
                .padding(.horizontal, 24)

            HStack(spacing: 8) {
                let presets = Array(Set([1, 3, 5, 10, 20, maxLeverage].filter { $0 <= maxLeverage })).sorted()
                ForEach(presets, id: \.self) { lev in
                    Button {
                        leverageSliderValue = Double(lev)
                        haptic.impactOccurred()
                    } label: {
                        Text("\(lev)x")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Int(leverageSliderValue) == lev ? .white : Color(white: 0.5))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(Int(leverageSliderValue) == lev ? Color.hlGreen : Color(white: 0.12))
                            .cornerRadius(6)
                    }
                }
            }
            .padding(.horizontal, 16)

            Button {
                tradingVM.leverage = Double(Int(leverageSliderValue))
                showLeveragePicker = false
                // Sync leverage with HL — requires biometric if position exists on this market
                let coinKey = chartVM.selectedSymbol.components(separatedBy: "/").first ?? chartVM.selectedSymbol
                let hasPosition = walletMgr.activePositions.contains(where: { $0.coin == coinKey })
                Task {
                    let _ = await tradingVM.updateLeverage()
                    if hasPosition {
                        // Refresh positions to reflect leverage change
                        walletMgr.refreshMainPositionsNow()
                    }
                }
            } label: {
                Text("Confirm")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.hlGreen)
                    .cornerRadius(10)
            }
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 16)
        .background(Color(white: 0.08))
    }

    // MARK: - Account Mode (Classic / Portfolio Margin)

    @State private var showAccountModePicker = false
    @State private var currentAbstraction: String = "unifiedAccount" // "disabled", "unifiedAccount", "portfolioMargin"
    @State private var selectedAbstraction: String = "unifiedAccount"
    @State private var isUpdatingAccountMode = false
    @State private var accountModeError: String?

    private var accountModeLabel: String {
        walletMgr.isPortfolioMargin ? "PM" : "Classic"
    }

    private var accountModeButton: some View {
        Button {
            selectedAbstraction = currentAbstraction
            accountModeError = nil
            showAccountModePicker = true
        } label: {
            Text(accountModeLabel)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.hlGreen)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color(white: 0.09))
                .cornerRadius(8)
        }
        .sheet(isPresented: $showAccountModePicker) {
            accountModeSheet
                .presentationDetents([.height(340)])
                .presentationDragIndicator(.visible)
        }
        .task(id: walletMgr.connectedWallet?.address) {
            guard let wallet = walletMgr.connectedWallet else { return }
            await walletMgr.fetchAbstractionMode(for: wallet.address)
            await MainActor.run {
                currentAbstraction = walletMgr.isPortfolioMargin ? "portfolioMargin" : "unifiedAccount"
                selectedAbstraction = currentAbstraction
            }
        }
        .onChange(of: walletMgr.isPortfolioMargin) { _, isPM in
            currentAbstraction = isPM ? "portfolioMargin" : "unifiedAccount"
            selectedAbstraction = currentAbstraction
        }
    }

    private var accountModeSheet: some View {
        VStack(spacing: 16) {
            Text("Account Mode")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)
                .padding(.top, 8)

            VStack(spacing: 10) {
                marginModeOption(
                    title: "Classic",
                    description: "Each collateral asset has a separate balance. Margining is only shared across cross margin assets.",
                    isSelected: selectedAbstraction != "portfolioMargin",
                    action: { selectedAbstraction = "unifiedAccount" }
                )
                marginModeOption(
                    title: "Portfolio Margin",
                    description: "All trading is unified across spot and perps. HYPE and BTC can be used directly as collateral for perp positions.",
                    isSelected: selectedAbstraction == "portfolioMargin",
                    action: { selectedAbstraction = "portfolioMargin" }
                )
            }
            .padding(.horizontal, 16)

            if let err = accountModeError {
                Text(err)
                    .font(.system(size: 12))
                    .foregroundColor(.tradingRed)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
            }

            Button {
                guard selectedAbstraction != currentAbstraction else {
                    showAccountModePicker = false
                    return
                }
                isUpdatingAccountMode = true
                accountModeError = nil
                Task {
                    do {
                        let abbrev = selectedAbstraction == "portfolioMargin" ? "p" : "u"
                        let payload = try await TransactionSigner.signAgentSetAbstraction(abstraction: abbrev)
                        let result = try await TransactionSigner.postAction(payload)
                        if let status = result["status"] as? String, status == "err",
                           let errMsg = result["response"] as? String {
                            await MainActor.run {
                                accountModeError = errMsg
                                isUpdatingAccountMode = false
                            }
                            return
                        }
                        await MainActor.run {
                            currentAbstraction = selectedAbstraction
                            isUpdatingAccountMode = false
                            showAccountModePicker = false
                        }
                    } catch {
                        await MainActor.run {
                            accountModeError = error.localizedDescription
                            isUpdatingAccountMode = false
                        }
                    }
                }
            } label: {
                if isUpdatingAccountMode {
                    ProgressView()
                        .tint(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.hlGreen.opacity(0.6))
                        .cornerRadius(10)
                } else {
                    Text("Confirm")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.hlGreen)
                        .cornerRadius(10)
                }
            }
            .disabled(isUpdatingAccountMode)
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 16)
        .background(Color(white: 0.08))
    }

    // MARK: - Order type picker

    private var orderTypePicker: some View {
        Menu {
            Button("Market") { tradingVM.orderType = .market }
            Button("Limit") { tradingVM.orderType = .limit }
            Button("TWAP") { tradingVM.orderType = .twap }
        } label: {
            HStack {
                Text(tradingVM.orderType.rawValue)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.system(size: 10))
                    .foregroundColor(Color(white: 0.4))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color(white: 0.11))
            .cornerRadius(8)
        }
    }

    // MARK: - Side selector

    private var sideSelector: some View {
        HStack(spacing: 0) {
            ForEach(TradingOrderSide.allCases, id: \.self) { s in
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { tradingVM.side = s }
                } label: {
                    Text(s == .buy ? "LONG" : "SHORT")
                        .font(.system(size: 13, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .foregroundColor(tradingVM.side == s ? .white : Color(white: 0.4))
                        .background(
                            tradingVM.side == s
                                ? (s == .buy ? Color.hlGreen : Color.tradingRed)
                                : Color(white: 0.11)
                        )
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Spot side selector (Buy / Sell)

    private var spotSideSelector: some View {
        HStack(spacing: 0) {
            ForEach(TradingOrderSide.allCases, id: \.self) { s in
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { tradingVM.side = s }
                } label: {
                    Text(s == .buy ? "BUY" : "SELL")
                        .font(.system(size: 13, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .foregroundColor(tradingVM.side == s ? .white : Color(white: 0.4))
                        .background(
                            tradingVM.side == s
                                ? (s == .buy ? Color.hlGreen : Color.tradingRed)
                                : Color(white: 0.11)
                        )
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Size input (USD or Token toggle)

    private var sizeInput: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                HStack(spacing: 2) {
                    if !sizeInToken {
                        Text("$")
                            .font(.system(size: 14, weight: .medium, design: .monospaced))
                            .foregroundColor(Color(white: 0.4))
                    }

                    TextField("0.00", text: $tradingVM.sizeUSD)
                        .keyboardType(.decimalPad)
                        .focused($focusedField, equals: .size)
                        .id(TradeField.size)
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundColor(.white)

                    if sizeInToken {
                        Text(chartVM.displayBaseName)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundColor(Color(white: 0.4))
                    }
                }

                Spacer()

                // Toggle stablecoin ↔ Token
                Button {
                    let price = tradingVM.currentPrice
                    guard price > 0 else { sizeInToken.toggle(); return }
                    if let val = Double(tradingVM.sizeUSD.replacingOccurrences(of: ",", with: "")), val > 0 {
                        if sizeInToken {
                            tradingVM.sizeUSD = String(format: "%.2f", val * price)
                        } else {
                            tradingVM.sizeUSD = String(format: "%.4f", val / price)
                        }
                    }
                    sizeInToken.toggle()
                } label: {
                    Text(sizeInToken ? chartVM.displayBaseName : spotQuoteName)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.hlGreen)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(Color.hlGreen.opacity(0.12))
                        .cornerRadius(4)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color(white: 0.11))
            .cornerRadius(8)

            // Show equivalent in the other unit
            if tradingVM.positionSize > 0 || !tradingVM.sizeUSD.isEmpty {
                let equivalent: String = {
                    if sizeInToken {
                        if let tokenAmt = Double(tradingVM.sizeUSD), tradingVM.currentPrice > 0 {
                            return "≈ $\(String(format: "%.2f", tokenAmt * tradingVM.currentPrice))"
                        }
                        return ""
                    } else {
                        if tradingVM.positionSize > 0 {
                            return "≈ \(String(format: "%.4f", tradingVM.positionSize)) \(chartVM.displayBaseName)"
                        }
                        return ""
                    }
                }()
                if !equivalent.isEmpty {
                    Text(equivalent)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Color(white: 0.35))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 4)
                }
            }
        }
        .onChange(of: tradingVM.sizeUSD) { _, newVal in
            syncSliderFromSize(newVal)
        }
    }

    /// Reverse-sync: when user types a size value, update the % slider accordingly.
    private func syncSliderFromSize(_ sizeStr: String) {
        // Clear token override if user is manually editing (not from applySizePct)
        // applySizePct sets the override BEFORE changing sizeUSD, so by the time
        // this fires the override is already set. Manual edits don't set it.
        if tradingVM.spotSellTokenOverride != nil {
            // Check if the displayed value still matches the override
            let overrideTokens = tradingVM.spotSellTokenOverride!
            let displayedTokens: Double
            if sizeInToken {
                displayedTokens = Double(sizeStr.replacingOccurrences(of: ",", with: "")) ?? -1
            } else {
                let usdVal = Double(sizeStr.replacingOccurrences(of: ",", with: "")) ?? -1
                displayedTokens = tradingVM.currentPrice > 0 ? usdVal / tradingVM.currentPrice : -1
            }
            // If user changed the value significantly, clear the override
            if abs(displayedTokens - overrideTokens) / max(overrideTokens, 0.0001) > 0.01 {
                tradingVM.spotSellTokenOverride = nil
            }
        }

        guard let val = Double(sizeStr.replacingOccurrences(of: ",", with: "")), val > 0 else {
            if sizeStr.isEmpty {
                sizePct = 0
                tradingVM.spotSellTokenOverride = nil
            }
            return
        }
        let maxVal: Double
        if isSpotMarket && tradingVM.side == .sell {
            let tokenBal = walletMgr.spotTokenBalances[spotBaseCoin] ?? 0
            guard tokenBal > 0 else { return }
            if sizeInToken {
                maxVal = tokenBal
            } else {
                maxVal = tokenBal * tradingVM.currentPrice
            }
        } else if isSpotMarket {
            if sizeInToken {
                let price = tradingVM.currentPrice
                maxVal = price > 0 ? unifiedUSDCBalance / price : 0
            } else {
                maxVal = unifiedUSDCBalance
            }
        } else {
            maxVal = unifiedUSDCBalance * tradingVM.leverage
        }
        guard maxVal > 0 else { return }
        let pct = min((val / maxVal) * 100, 100)
        sizePct = pct.rounded()
    }

    // MARK: - Limit price input

    private var limitPriceInput: some View {
        HStack {
            TextField("Limit Price", text: $tradingVM.limitPrice)
                .keyboardType(.decimalPad)
                .focused($focusedField, equals: .limitPrice)
                .id(TradeField.limitPrice)
                .font(.system(size: 14, design: .monospaced))
                .foregroundColor(.white)
            Button("Mid") {
                tradingVM.limitPrice = formatPrice(tradingVM.currentPrice)
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(Color(white: 0.4))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(white: 0.11))
        .cornerRadius(8)
    }

    // MARK: - Size % slider

    private var sizePercentSlider: some View {
        VStack(spacing: 2) {
            GeometryReader { geo in
                let w = geo.size.width
                let fraction = CGFloat(sizePct / 100.0)
                let thumbSize: CGFloat = 20
                let trackH: CGFloat = 4
                let accentColor: Color = tradingVM.side == .buy ? .hlGreen : .tradingRed

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color(white: 0.15))
                        .frame(height: trackH)

                    Capsule()
                        .fill(accentColor)
                        .frame(width: max(0, fraction * (w - thumbSize) + thumbSize / 2), height: trackH)

                    Circle()
                        .fill(accentColor)
                        .frame(width: thumbSize, height: thumbSize)
                        .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                        .offset(x: fraction * (w - thumbSize))
                }
                .frame(height: thumbSize)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            let raw = drag.location.x / (w - thumbSize)
                            let clamped = min(max(raw, 0), 1)
                            let newPct = (clamped * 100).rounded()
                            if newPct != sizePct {
                                sizePct = newPct
                                haptic.prepare()
                                haptic.impactOccurred()
                                applySizePct(newPct)
                            }
                        }
                )
            }
            .frame(height: 20)

            HStack {
                Text("0%")
                Spacer()
                Text("\(Int(sizePct))%")
                    .foregroundColor(.white)
                    .fontWeight(.medium)
                Spacer()
                Text("100%")
            }
            .font(.system(size: 9, design: .monospaced))
            .foregroundColor(Color(white: 0.35))
        }
    }

    private func applySizePct(_ pct: Double) {
        let szDec = tradingVM.szDecimals
        if isSpotMarket && tradingVM.side == .sell {
            // Sell spot: use TOTAL token balance (not available) — user expects 100% = all
            let tokenBal = walletMgr.spotTokenBalances[spotBaseCoin] ?? 0
            let raw = tokenBal * pct / 100.0
            let factor = pow(10.0, Double(szDec))
            let tokenAmount = floor(raw * factor) / factor
            // Always store as token amount internally to avoid double conversion precision loss
            tradingVM.spotSellTokenOverride = tokenAmount
            if sizeInToken {
                tradingVM.sizeUSD = tokenAmount > 0 ? formatDecimal(tokenAmount, decimals: szDec) : ""
            } else {
                let usdAmount = tokenAmount * tradingVM.currentPrice
                tradingVM.sizeUSD = usdAmount > 0 ? String(format: "%.2f", usdAmount) : ""
            }
        } else if isSpotMarket {
            tradingVM.spotSellTokenOverride = nil
            let amount = unifiedUSDCBalance * pct / 100.0
            if sizeInToken {
                let price = tradingVM.currentPrice
                let tokenAmt = price > 0 ? amount / price : 0
                tradingVM.sizeUSD = tokenAmt > 0 ? formatDecimal(tokenAmt, decimals: szDec) : ""
            } else {
                tradingVM.sizeUSD = amount > 0 ? String(format: "%.2f", amount) : ""
            }
        } else {
            tradingVM.spotSellTokenOverride = nil
            let base = unifiedUSDCBalance * tradingVM.leverage
            let amount = base * pct / 100.0
            tradingVM.sizeUSD = amount > 0 ? String(format: "%.2f", amount) : ""
        }
    }

    private func formatDecimal(_ value: Double, decimals: Int) -> String {
        String(format: "%.\(decimals)f", value)
    }

    // MARK: - TWAP settings

    @State private var twapHours: String = "0"
    @State private var twapMinutes: String = "0"

    private var twapSettings: some View {
        VStack(spacing: 6) {
            // Running Time label
            Text("Running Time (5m – 24h)")
                .font(.system(size: 11))
                .foregroundColor(Color(white: 0.4))
                .frame(maxWidth: .infinity, alignment: .leading)

            // Hour + Minute input fields side by side
            HStack(spacing: 8) {
                // Hours
                HStack(spacing: 6) {
                    TextField("0", text: $twapHours)
                        .keyboardType(.numberPad)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 28)
                        .focused($focusedField, equals: .twapHours)
                        .id(TradeField.twapHours)
                        .onChange(of: focusedField) { old, new in
                            if new == .twapHours && twapHours == "0" { twapHours = "" }
                            if old == .twapHours && twapHours.isEmpty { twapHours = "0" }
                        }
                        .onChange(of: twapHours) { _ in syncTwapDuration() }
                    Text("Hour(s)")
                        .font(.system(size: 11))
                        .foregroundColor(Color(white: 0.4))
                        .lineLimit(1)
                        .fixedSize()
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color(white: 0.08))
                .cornerRadius(6)

                // Minutes
                HStack(spacing: 6) {
                    TextField("0", text: $twapMinutes)
                        .keyboardType(.numberPad)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 28)
                        .focused($focusedField, equals: .twapMinutes)
                        .id(TradeField.twapMinutes)
                        .onChange(of: focusedField) { old, new in
                            if new == .twapMinutes && twapMinutes == "0" { twapMinutes = "" }
                            if old == .twapMinutes && twapMinutes.isEmpty { twapMinutes = "0" }
                        }
                        .onChange(of: twapMinutes) { _ in syncTwapDuration() }
                    Text("Minute(s)")
                        .font(.system(size: 11))
                        .foregroundColor(Color(white: 0.4))
                        .lineLimit(1)
                        .fixedSize()
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color(white: 0.08))
                .cornerRadius(6)
            }

            // Info text
            let totalMins = computeTwapMinutes()
            Text("Splits your order into sub-orders executed over \(twapDurationLabel(totalMins)). Min 5m, max 24h.")
                .font(.system(size: 9))
                .foregroundColor(Color(white: 0.3))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color(white: 0.07))
        .cornerRadius(8)
    }

    private func computeTwapMinutes() -> Int {
        let h = Int(twapHours) ?? 0
        let m = Int(twapMinutes) ?? 0
        return max(5, min(1440, h * 60 + m))
    }

    private func syncTwapDuration() {
        tradingVM.twapDuration = computeTwapMinutes()
    }

    private func twapDurationLabel(_ mins: Int) -> String {
        let h = mins / 60
        let m = mins % 60
        if h > 0 && m > 0 { return "\(h)h \(m)m" }
        if h > 0 { return "\(h)h" }
        return "\(m)m"
    }

    // MARK: - TP/SL

    private var tpSlSection: some View {
        VStack(spacing: 4) {
            HStack {
                Text("TP/SL")
                    .font(.system(size: 11))
                    .foregroundColor(Color(white: 0.4))
                Spacer()
                Toggle("", isOn: Binding(
                    get: { tradingVM.tpEnabled || tradingVM.slEnabled },
                    set: { val in
                        tradingVM.tpEnabled = val
                        tradingVM.slEnabled = val
                    }
                ))
                .labelsHidden()
                .scaleEffect(0.7)
                .tint(.hlGreen)
            }

            if tradingVM.tpEnabled {
                HStack {
                    Text("TP")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.hlGreen)
                        .frame(width: 20)
                    TextField("Price", text: $tradingVM.tpPrice)
                        .keyboardType(.decimalPad)
                        .focused($focusedField, equals: .tpPrice)
                        .id(TradeField.tpPrice)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color(white: 0.09))
                .cornerRadius(6)
            }

            if tradingVM.slEnabled {
                HStack {
                    Text("SL")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.tradingRed)
                        .frame(width: 20)
                    TextField("Price", text: $tradingVM.slPrice)
                        .keyboardType(.decimalPad)
                        .id(TradeField.slPrice)
                        .focused($focusedField, equals: .slPrice)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color(white: 0.09))
                .cornerRadius(6)
            }
        }
    }

    // MARK: - Submit button

    private var submitButton: some View {
        let isConnected = walletMgr.connectedWallet != nil
        let buttonColor: Color = isConnected
            ? (tradingVM.side == .buy ? .hlGreen : .tradingRed)
            : Color(white: 0.25)
        let canSubmit = isConnected && !tradingVM.sizeUSD.isEmpty && !tradingVM.isSubmitting

        return Button {
            if !isConnected { showWalletConnect = true }
            else {
                Task { await checkSlippageAndSubmit() }
            }
        } label: {
            Group {
                if tradingVM.isSubmitting {
                    HStack(spacing: 6) {
                        ProgressView().tint(.white).scaleEffect(0.8)
                        Text("Submitting…")
                    }
                } else if !isConnected {
                    Text("Connect Wallet")
                } else if tradingVM.sizeUSD.isEmpty {
                    Text("Enter order size")
                } else {
                    Text(orderButtonLabel)
                }
            }
            .font(.system(size: 14, weight: .bold))
            .foregroundColor(canSubmit ? .white : Color(white: 0.5))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(canSubmit ? buttonColor : buttonColor.opacity(0.4))
            .cornerRadius(10)
        }
        .disabled(tradingVM.isSubmitting)
    }

    // MARK: - Bottom Tab Bar

    private var bottomTabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(TradingViewModel.BottomTab.allCases, id: \.self) { tab in
                    let isSelected = tradingVM.bottomTab == tab
                    let count = tabCount(tab)

                    Button {
                        tradingVM.bottomTab = tab
                    } label: {
                        VStack(spacing: 4) {
                            HStack(spacing: 3) {
                                Text(tab.rawValue)
                                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                                    .foregroundColor(isSelected ? .white : Color(white: 0.45))

                                if count > 0 {
                                    Text("(\(count))")
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundColor(isSelected ? .hlGreen : Color(white: 0.35))
                                }
                            }

                            Rectangle()
                                .fill(isSelected ? Color.hlGreen : Color.clear)
                                .frame(height: 2)
                        }
                        .padding(.horizontal, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 4)
        }
    }

    private func tabCount(_ tab: TradingViewModel.BottomTab) -> Int {
        switch tab {
        case .positions: return walletMgr.activePositions.count
        case .predictions: return tradingVM.predictionPositions.count
        case .openOrders: return tradingVM.openOrders.count
        case .options: return tradingVM.optionPositions.count
        default: return 0
        }
    }

    // MARK: - Bottom Tab Content

    @ViewBuilder
    private var bottomTabContent: some View {
        switch tradingVM.bottomTab {
        case .balances:
            bottomBalancesView
        case .positions:
            bottomPositionsView
        case .predictions:
            bottomPredictionsView
        case .openOrders:
            bottomOpenOrdersView
        case .options:
            bottomOptionsView
        case .twap:
            bottomTwapView
        case .tradeHistory:
            bottomTradeHistoryView
        case .fundingHistory:
            bottomFundingHistoryView
        case .orderHistory:
            orderHistoryView
        }
    }

    // MARK: - Balances tab

    /// Unified USDC balance: available USDC that can be used for trading.
    /// In PM mode, use the actual spot USDC available (total - hold), which is exactly what
    /// the Balances tab displays. The previous approach (tokenToAvailableAfterMaintenance / 2)
    /// was a portfolio-level borrowing-capacity estimate that diverged from the per-token view.
    /// In PM, HL distributes the margin hold proportionally across all collateral tokens
    /// (USDC, USDH, etc.), so `spotTokenAvailable["USDC"]` already reflects the true free USDC.
    private var unifiedUSDCBalance: Double {
        if walletMgr.isPortfolioMargin {
            return walletMgr.spotTokenAvailable["USDC"] ?? walletMgr.perpWithdrawable
        }
        return max(walletMgr.perpWithdrawable, walletMgr.spotTokenAvailable["USDC"] ?? 0)
    }

    // PM balance data
    @State private var pmBalances: [PMBalanceEntry] = []
    @State private var pmBalancesLoaded = false
    @State private var pmAvailableToTrade: Double = 0 // tokenToAvailableAfterMaintenance for USDC
    @State private var showRepaySheet = false
    @State private var repayEntry: PMBalanceEntry?

    struct PMBalanceEntry: Identifiable {
        let id = UUID()
        let coin: String
        let tokenIndex: Int
        let ltv: Double
        let borrowCapUsed: Double // percentage
        let netBalance: Double    // in token
        let availableBalance: Double
        let usdcValue: Double
        let isBorrowed: Bool
    }

    private var bottomBalancesView: some View {
        VStack(spacing: 0) {
            if walletMgr.isPortfolioMargin {
                pmBalancesView
            } else {
                classicBalancesView
            }
        }
    }

    /// PM balances polling task — called from body level, not from balances tab
    var pmBalancesTask: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .task(id: "\(walletMgr.connectedWallet?.address ?? "")_\(walletMgr.isPortfolioMargin)") {
                guard walletMgr.isPortfolioMargin else { return }
                while !Task.isCancelled {
                    await loadPMBalances()
                    try? await Task.sleep(nanoseconds: 10_000_000_000)
                }
            }
    }

    // Classic balances (non-PM)
    private var classicBalancesView: some View {
        let entries = classicBalanceEntries

        return VStack(spacing: 0) {
            // Header
            HStack(spacing: 0) {
                Text("Coin").frame(width: 65, alignment: .leading)
                Text("Total Balance").frame(maxWidth: .infinity, alignment: .trailing)
                Text("Available Balance").frame(maxWidth: .infinity, alignment: .trailing)
                Text("USDC Value").frame(width: 80, alignment: .trailing)
            }
            .font(.system(size: 10))
            .foregroundColor(Color(white: 0.45))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            ForEach(entries, id: \.coin) { entry in
                classicBalanceRow(entry)
                    .contentShape(Rectangle())
                    .onTapGesture { openSpotMarket(for: entry.coin) }
                Divider().background(Color(white: 0.1))
            }
        }
    }

    private var classicBalanceEntries: [(coin: String, total: Double, available: Double)] {
        var entries: [(coin: String, total: Double, available: Double)] = []

        // USDC always first
        let usdcTotal = walletMgr.spotTokenBalances["USDC"] ?? unifiedUSDCBalance
        let usdcAvail = walletMgr.spotTokenAvailable["USDC"] ?? unifiedUSDCBalance
        entries.append(("USDC", usdcTotal, usdcAvail))

        // Other spot tokens
        for (coin, total) in walletMgr.spotTokenBalances.sorted(by: { $0.key < $1.key }) {
            if coin == "USDC" { continue }
            let avail = walletMgr.spotTokenAvailable[coin] ?? 0
            entries.append((coin, total, avail))
        }

        // Always show HYPE if not present
        if !entries.contains(where: { $0.coin == "HYPE" }) {
            entries.append(("HYPE", 0, 0))
        }

        return entries
    }

    private func classicBalanceRow(_ entry: (coin: String, total: Double, available: Double)) -> some View {
        let price = tokenPrice(for: entry.coin)
        let usdValue = entry.total * price
        let stables = ["USDC", "USDH", "USDT", "USDE"]
        let isStable = stables.contains(entry.coin)
        let decimals = isStable ? 2 : (entry.coin == "BTC" || entry.coin == "UBTC" ? 5 : 4)

        return HStack(spacing: 0) {
            HStack(spacing: 5) {
                CoinIconView(symbol: entry.coin, hlIconName: entry.coin, iconSize: 16)
                Text(entry.coin)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(isStable ? .white : .hlGreen)
            }
            .frame(width: 65, alignment: .leading)

            Text(formatBalance(entry.total, coin: entry.coin, decimals: decimals))
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(Color(white: 0.6))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .lineLimit(1)

            Text(formatBalance(entry.available, coin: entry.coin, decimals: decimals))
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(Color(white: 0.6))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .lineLimit(1)

            Text(usdValue >= 0.01
                 ? String(format: "$%.2f", usdValue)
                 : "$0.00")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.white)
                .frame(width: 80, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Format balance with consistent width — truncate coin suffix if needed
    private func formatBalance(_ amount: Double, coin: String, decimals: Int) -> String {
        let numStr = String(format: "%.\(decimals)f", amount)
        return "\(numStr) \(coin)"
    }

    /// Open the spot market for a given coin (e.g. "HYPE" → HYPE/USDC spot, "UBTC" → BTC/USDC spot)
    private func openSpotMarket(for coin: String) {
        let stables = ["USDC", "USDH", "USDT", "USDT0", "USDE"]
        guard !stables.contains(coin) else { return }
        // Find the spot market by base name
        if let market = marketsVM.markets.first(where: { $0.isSpot && $0.baseName == coin }) {
            chartVM.changeSymbol(
                market.symbol,
                displayName: market.spotDisplayPairName,
                perpEquivalent: market.perpEquivalent
            )
        }
    }

    private func tokenPrice(for coin: String) -> Double {
        if coin == "USDC" || coin == "USDH" || coin == "USDT0" || coin == "USDT" || coin == "USDE" { return 1.0 }
        // Map wrapped token names to their perp market names
        let spotToPerp: [String: String] = [
            "UBTC": "BTC", "UETH": "ETH", "USOL": "SOL",
            "UENA": "ENA", "stHYPE": "HYPE"
        ]
        let lookupName = spotToPerp[coin] ?? coin
        // Try perp market price first
        if let market = marketsVM.markets.first(where: { $0.asset.name == lookupName && $0.marketType == .perp }) {
            return market.price
        }
        // Try any market with matching name
        if let market = marketsVM.markets.first(where: { $0.asset.name == lookupName }) {
            return market.price
        }
        // Try spot market by base name
        if let market = marketsVM.markets.first(where: { $0.baseName == coin }) {
            return market.price
        }
        return 0
    }

    // PM balances (Portfolio Margin)
    private var pmBalancesView: some View {
        VStack(spacing: 0) {
            if pmBalances.isEmpty {
                if pmBalancesLoaded {
                    emptyTabView("No balances")
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                }
            } else {
                // Column headers
                pmColumnHeaders
                Divider().background(Color(white: 0.15))

                ForEach(pmBalances) { entry in
                    pmBalanceRow(entry)
                    Divider().background(Color(white: 0.08))
                }

                // Repay buttons below
                pmRepayButtons
            }
        }
        .sheet(isPresented: $showRepaySheet) {
            if let entry = repayEntry {
                RepaySheet(
                    debtCoin: entry.coin,
                    debtAmount: abs(entry.netBalance),
                    availableAssets: pmBalances.filter { !$0.isBorrowed && $0.netBalance > 0 }
                )
            }
        }
    }

    private var pmColumnHeaders: some View {
        HStack(spacing: 4) {
            Text("Coin")
                .frame(width: 55, alignment: .leading)
            Text("LTV")
                .frame(width: 32, alignment: .trailing)
            Text("Borrow\nCap Used")
                .frame(width: 40, alignment: .trailing)
                .multilineTextAlignment(.trailing)
            Text("Net Balance")
                .frame(maxWidth: .infinity, alignment: .trailing)
            Text("Available")
                .frame(maxWidth: .infinity, alignment: .trailing)
            Text("Value")
                .frame(width: 58, alignment: .trailing)
        }
        .font(.system(size: 9, weight: .medium))
        .foregroundColor(.gray)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private func pmBalanceRow(_ entry: PMBalanceEntry) -> some View {
        let displayCoin = entry.coin == "UBTC" ? "BTC" : entry.coin
        let iconCoin = entry.coin == "UBTC" ? "BTC" : entry.coin

        return HStack(spacing: 4) {
            HStack(spacing: 4) {
                CoinIconView(symbol: displayCoin, hlIconName: iconCoin, iconSize: 14)
                Text(displayCoin)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white)
            }
            .frame(width: 55, alignment: .leading)

            Text(entry.ltv > 0 ? "\(Int(entry.ltv * 100))%" : "N/A")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(entry.ltv > 0 ? .white : .gray)
                .frame(width: 32, alignment: .trailing)

            Text(entry.borrowCapUsed > 0 ? String(format: "%.2f%%", entry.borrowCapUsed * 100) : "-")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.white)
                .frame(width: 40, alignment: .trailing)

            Text(formatPMBalance(entry.netBalance, coin: entry.coin))
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(entry.netBalance < 0 ? .tradingRed : .white)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .lineLimit(1)

            Text(formatPMBalance(entry.availableBalance, coin: entry.coin))
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .lineLimit(1)

            Text(formatUSDValue(entry.usdcValue))
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(entry.usdcValue < 0 ? .tradingRed : .white)
                .frame(width: 58, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    /// Repay buttons below the balance rows
    private var pmRepayButtons: some View {
        let borrowedCoins = pmBalances.filter { $0.isBorrowed }
        return Group {
            if !borrowedCoins.isEmpty {
                HStack(spacing: 10) {
                    ForEach(borrowedCoins) { entry in
                        Button {
                            repayEntry = entry
                            showRepaySheet = true
                        } label: {
                            Text("Repay \(entry.coin)")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.hlGreen)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.hlGreen.opacity(0.5), lineWidth: 1)
                                )
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
        }
    }

    private func formatPMBalance(_ v: Double, coin: String) -> String {
        if abs(v) < 0.000001 { return "0" }
        let isStable = coin == "USDC" || coin == "USDH" || coin == "USDT0" || coin == "USDE"
        if isStable {
            return String(format: "%.2f", v)
        }
        let lookupCoin = coin == "UBTC" ? "BTC" : coin
        let dec = MarketsViewModel.szDecimalsCache[lookupCoin] ?? MarketsViewModel.szDecimalsCache[coin] ?? 4
        return String(format: "%.\(max(dec, 2))f", v)
    }

    private func formatUSDValue(_ v: Double) -> String {
        if abs(v) < 0.01 { return "$0.00" }
        return String(format: "$%.2f", v)
    }

    private func loadPMBalances() async {
        guard let address = walletMgr.connectedWallet?.address else { return }
        do {
            // Fetch oracle prices
            var oraclePrices: [String: Double] = ["USDC": 1.0, "USDH": 1.0, "USDT0": 1.0, "USDE": 1.0]
            let hlURL = URL(string: "https://api.hyperliquid.xyz/info")!

            var mReq = URLRequest(url: hlURL)
            mReq.httpMethod = "POST"
            mReq.addValue("application/json", forHTTPHeaderField: "Content-Type")
            mReq.httpBody = try JSONSerialization.data(withJSONObject: ["type": "allMids"])
            let (mData, _) = try await URLSession.shared.data(for: mReq)
            if let mids = try? JSONSerialization.jsonObject(with: mData) as? [String: String] {
                for (coin, priceStr) in mids {
                    if let p = Double(priceStr) { oraclePrices[coin] = p }
                }
                if let btcP = oraclePrices["BTC"] { oraclePrices["UBTC"] = btcP }
            }

            // Fetch spotClearinghouseState
            var sReq = URLRequest(url: hlURL)
            sReq.httpMethod = "POST"
            sReq.addValue("application/json", forHTTPHeaderField: "Content-Type")
            sReq.httpBody = try JSONSerialization.data(withJSONObject: [
                "type": "spotClearinghouseState", "user": address
            ])
            let (sData, _) = try await URLSession.shared.data(for: sReq)
            guard let sJson = try JSONSerialization.jsonObject(with: sData) as? [String: Any] else { return }
            let balances = sJson["balances"] as? [[String: Any]] ?? []

            // Parse borrow cap ratios
            var borrowRatios: [Int: Double] = [:]
            if let ratios = sJson["tokenToPortfolioBorrowRatio"] as? [[Any]] {
                for r in ratios {
                    if let tokenIdx = r[0] as? Int, let ratioStr = r[1] as? String {
                        borrowRatios[tokenIdx] = Double(ratioStr) ?? 0
                    }
                }
            }

            var entries: [PMBalanceEntry] = []
            for bal in balances {
                let coin = bal["coin"] as? String ?? ""
                let tokenIdx = bal["token"] as? Int ?? 0
                let total = Double(bal["total"] as? String ?? "0") ?? 0
                let hold = Double(bal["hold"] as? String ?? "0") ?? 0
                let ltv = Double(bal["ltv"] as? String ?? "0") ?? 0
                let borrowed = Double(bal["borrowed"] as? String ?? "0") ?? 0
                let supplied = Double(bal["supplied"] as? String ?? "0") ?? 0

                // Skip zero balance tokens
                guard abs(total) > 0.000001 || supplied > 0 || borrowed > 0 else { continue }

                let isStable = coin == "USDC" || coin == "USDH" || coin == "USDT0" || coin == "USDE"
                let price = oraclePrices[coin] ?? (isStable ? 1.0 : 0)
                let usdcVal = total * price
                // Available Balance = total - hold (matches Hyperliquid's calculation)
                let available = total - hold
                let borrowCap = borrowRatios[tokenIdx] ?? 0

                entries.append(PMBalanceEntry(
                    coin: coin,
                    tokenIndex: tokenIdx,
                    ltv: ltv,
                    borrowCapUsed: borrowCap,
                    netBalance: total,
                    availableBalance: available,
                    usdcValue: usdcVal,
                    isBorrowed: borrowed > 0
                ))
            }

            // Sort: borrowed first, then by absolute USDC value
            entries.sort { abs($0.usdcValue) > abs($1.usdcValue) }

            // Extract "Available to Trade" from tokenToAvailableAfterMaintenance
            var availToTrade: Double = 0
            if let avails = sJson["tokenToAvailableAfterMaintenance"] as? [[Any]] {
                print("[PM-AVAIL] Raw array count: \(avails.count)")
                for item in avails {
                    guard item.count >= 2 else { continue }
                    let tokenIdx: Int
                    if let i = item[0] as? Int { tokenIdx = i }
                    else if let n = item[0] as? NSNumber { tokenIdx = n.intValue }
                    else if let d = item[0] as? Double { tokenIdx = Int(d) }
                    else { print("[PM-AVAIL] Can't parse token idx: \(type(of: item[0])) = \(item[0])"); continue }

                    let amt: Double
                    if let s = item[1] as? String { amt = Double(s) ?? 0 }
                    else if let n = item[1] as? NSNumber { amt = n.doubleValue }
                    else if let d = item[1] as? Double { amt = d }
                    else { continue }

                    print("[PM-AVAIL] token \(tokenIdx): \(String(format: "%.2f", amt))")
                    if tokenIdx == 0 { availToTrade = amt }
                }
            } else {
                print("[PM-AVAIL] tokenToAvailableAfterMaintenance not found or wrong format")
            }
            print("[PM-AVAIL] Final Available to Trade = \(String(format: "%.2f", availToTrade))")

            await MainActor.run {
                pmBalances = entries
                pmBalancesLoaded = true
                pmAvailableToTrade = availToTrade
            }
        } catch {
            await MainActor.run { pmBalancesLoaded = true }
        }
    }

    private func executeRepay(_ entry: PMBalanceEntry) async {
        // Repay = spot transfer (buy back the borrowed token)
        // This requires a spot market order to buy the borrowed amount
        // For now, show that it's not yet implemented
        // TODO: Implement repay via spot market buy
    }

    private func formatBalance(_ v: Double) -> String {
        if v >= 1000 { return String(format: "%.2f", v) }
        if v >= 1    { return String(format: "%.4f", v) }
        return String(format: "%.6f", v)
    }

    // MARK: - Positions tab

    private var bottomPositionsView: some View {
        VStack(spacing: 0) {
            let positions = walletMgr.activePositions
            if positions.isEmpty {
                emptyTabView("No open positions")
            } else {
                ForEach(positions) { pos in
                    Button {
                        selectedPosition = pos
                        showPositionDetail = true
                    } label: {
                        positionRow(pos)
                    }
                    .buttonStyle(.plain)
                    Divider().background(Color(white: 0.1))
                }
            }
        }
        .sheet(isPresented: $showPositionDetail) {
            if let pos = selectedPosition {
                PositionDetailSheet(
                    position: pos,
                    marketsVM: marketsVM,
                    onDismiss: { showPositionDetail = false }
                )
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
        }
    }

    private func positionRow(_ pos: PerpPosition) -> some View {
        VStack(spacing: 4) {
            HStack {
                // Coin + side badge
                Text(pos.coin)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white)
                Text(pos.isLong ? "LONG" : "SHORT")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(pos.isLong ? .hlGreen : .tradingRed)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background((pos.isLong ? Color.hlGreen : Color.tradingRed).opacity(0.15))
                    .cornerRadius(4)
                Text("\(pos.isCross ? "Cross" : "Iso") \(pos.leverage)× - \(pos.formattedMargin) \(walletMgr.isPortfolioMargin ? (pos.isCross ? "(PM)" : "(Isolated)") : "")")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Color(white: 0.4))
                Spacer()
                // PnL
                let pnlPct = pos.entryPrice != 0 ? (pos.unrealizedPnl / (pos.sizeAbs * pos.entryPrice)) * 100 : 0
                VStack(alignment: .trailing, spacing: 1) {
                    Text(String(format: "%+.2f USDC", pos.unrealizedPnl))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(pos.unrealizedPnl >= 0 ? .hlGreen : .tradingRed)
                    Text(String(format: "%+.2f%%", pnlPct))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(pos.unrealizedPnl >= 0 ? .hlGreen : .tradingRed)
                }
            }
            // Row 1: Size (with token), Entry, Mark
            HStack {
                Text("Size")
                    .font(.system(size: 10))
                    .foregroundColor(Color(white: 0.4))
                Text("\(String(format: "%.4f", pos.sizeAbs)) \(pos.coin)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Color(white: 0.6))
                Spacer()
                Text("Entry")
                    .font(.system(size: 10))
                    .foregroundColor(Color(white: 0.4))
                Text(pos.formattedEntry)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Color(white: 0.6))
                Spacer()
                Text("Mark")
                    .font(.system(size: 10))
                    .foregroundColor(Color(white: 0.4))
                Text(pos.formattedMark)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Color(white: 0.6))
            }
            // Row 2: Position Value, Liq
            HStack {
                Text("Position Value")
                    .font(.system(size: 10))
                    .foregroundColor(Color(white: 0.4))
                Text(pos.formattedSizeUSD.replacingOccurrences(of: "+", with: "").replacingOccurrences(of: "-", with: ""))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Color(white: 0.6))
                Spacer()
                if let liq = pos.liquidationPx {
                    Text("Liq")
                        .font(.system(size: 10))
                        .foregroundColor(Color(white: 0.4))
                    Text(pos.formattedLiqPx)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.orange)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    // MARK: - Open Orders tab

    private var bottomOpenOrdersView: some View {
        VStack(spacing: 0) {
            if tradingVM.isLoadingBottom && tradingVM.openOrders.isEmpty {
                ProgressView().tint(Color(white: 0.3))
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else if tradingVM.openOrders.isEmpty {
                emptyTabView("No open orders")
            } else {
                ForEach(tradingVM.openOrders) { order in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                Text(displayCoin(order.coin))
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundColor(.white)
                                Text(order.orderType)
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundColor(Color(white: 0.4))
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(Color(white: 0.12))
                                    .cornerRadius(3)
                            }
                            HStack(spacing: 4) {
                                Text(order.sideLabel)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(order.isBuy ? .hlGreen : .tradingRed)
                                Text("\(order.sz) @ \(order.limitPx)")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(Color(white: 0.5))
                            }
                        }

                        Spacer()

                        VStack(alignment: .trailing, spacing: 2) {
                            Text(order.timeStr)
                                .font(.system(size: 9))
                                .foregroundColor(Color(white: 0.35))

                            // Cancel button
                            Button {
                                Task {
                                    await tradingVM.cancelOrder(order, markets: marketsVM.markets)
                                }
                            } label: {
                                if tradingVM.isCancelling == order.oid {
                                    ProgressView().tint(.tradingRed).scaleEffect(0.6)
                                        .frame(width: 50, height: 24)
                                } else {
                                    Text("Cancel")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundColor(.tradingRed)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Color.tradingRed.opacity(0.12))
                                        .cornerRadius(4)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)

                    Divider().background(Color(white: 0.1))
                }
            }
        }
    }

    // MARK: - Predictions tab

    private var bottomPredictionsView: some View {
        VStack(spacing: 0) {
            if tradingVM.isLoadingBottom && tradingVM.predictionPositions.isEmpty {
                ProgressView().tint(Color(white: 0.3))
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else if tradingVM.predictionPositions.isEmpty {
                emptyTabView("No prediction positions")
            } else {
                ForEach(tradingVM.predictionPositions) { pos in
                    outcomePositionRow(pos)
                    Divider().background(Color(white: 0.1))
                }
            }
        }
    }

    // MARK: - Options tab

    private var bottomOptionsView: some View {
        VStack(spacing: 0) {
            if tradingVM.isLoadingBottom && tradingVM.optionPositions.isEmpty {
                ProgressView().tint(Color(white: 0.3))
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else if tradingVM.optionPositions.isEmpty {
                emptyTabView("No option positions")
            } else {
                ForEach(tradingVM.optionPositions) { pos in
                    outcomePositionRow(pos)
                    Divider().background(Color(white: 0.1))
                }
            }
        }
    }

    private func outcomePositionRow(_ pos: OutcomePosition) -> some View {
        VStack(spacing: 4) {
            HStack {
                // Name + side badge
                Text(pos.displayName)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text(pos.sideName)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(pos.isLong ? .hlGreen : .tradingRed)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background((pos.isLong ? Color.hlGreen : Color.tradingRed).opacity(0.15))
                    .cornerRadius(4)
                Spacer()
                // PnL
                VStack(alignment: .trailing, spacing: 1) {
                    if pos.unrealizedPnl != 0 {
                        Text(String(format: "%+.2f USDC", pos.unrealizedPnl))
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(pos.unrealizedPnl >= 0 ? .hlGreen : .tradingRed)
                    }
                }
            }
            // Row: Size, Entry, Mark
            HStack {
                Text("Size")
                    .font(.system(size: 10))
                    .foregroundColor(Color(white: 0.4))
                Text(String(format: "%.1f", abs(pos.size)))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Color(white: 0.6))
                Spacer()
                Text("Entry")
                    .font(.system(size: 10))
                    .foregroundColor(Color(white: 0.4))
                Text(String(format: "%.1f\u{00A2}", pos.entryPrice * 100))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Color(white: 0.6))
                Spacer()
                Text("Mark")
                    .font(.system(size: 10))
                    .foregroundColor(Color(white: 0.4))
                Text(String(format: "%.1f\u{00A2}", pos.markPrice * 100))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Color(white: 0.6))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    // MARK: - TWAP tab

    private var bottomTwapView: some View {
        VStack(spacing: 0) {
            if tradingVM.isLoadingBottom && tradingVM.activeTwaps.isEmpty {
                ProgressView().tint(Color(white: 0.3))
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else if tradingVM.activeTwaps.isEmpty {
                emptyTabView("No TWAP orders")
            } else {
                ForEach(tradingVM.activeTwaps) { twap in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                Text(displayCoin(twap.coin))
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundColor(.white)
                                Text(twap.sideLabel)
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundColor(twap.isBuy ? .hlGreen : .tradingRed)
                                Text(twap.status.capitalized)
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundColor(twap.isRunning ? .hlGreen : Color(white: 0.4))
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(twap.isRunning ? Color.hlGreen.opacity(0.12) : Color(white: 0.12))
                                    .cornerRadius(3)
                            }
                            HStack(spacing: 4) {
                                Text("\(twap.filledSz)/\(twap.sz)")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(Color(white: 0.5))
                                Text(twap.progress)
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundColor(.hlGreen)
                            }
                        }

                        Spacer()

                        VStack(alignment: .trailing, spacing: 2) {
                            Text(twap.timeStr)
                                .font(.system(size: 9))
                                .foregroundColor(Color(white: 0.35))

                            if twap.isRunning {
                                Button {
                                    Task {
                                        await tradingVM.cancelTwap(twap, markets: marketsVM.markets)
                                    }
                                } label: {
                                    if tradingVM.isCancellingTwap == twap.twapId {
                                        ProgressView().tint(.tradingRed).scaleEffect(0.6)
                                            .frame(width: 50, height: 24)
                                    } else {
                                        Text("Cancel")
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundColor(.tradingRed)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background(Color.tradingRed.opacity(0.12))
                                            .cornerRadius(4)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)

                    Divider().background(Color(white: 0.1))
                }
            }
        }
    }

    // MARK: - Trade History tab

    private var orderHistoryView: some View {
        VStack(spacing: 0) {
            if tradingVM.isLoadingBottom && tradingVM.orderHistory.isEmpty {
                ProgressView().tint(Color(white: 0.3))
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else if tradingVM.orderHistory.isEmpty {
                Text("No order history")
                    .font(.system(size: 12))
                    .foregroundColor(Color(white: 0.3))
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                ForEach(Array(tradingVM.orderHistory.prefix(50).enumerated()), id: \.offset) { _, entry in
                    let order = (entry["order"] as? [String: Any]) ?? entry
                    let rawCoin = (order["coin"] as? String) ?? "?"
                    let coin = displayCoin(rawCoin)
                    let side = (order["side"] as? String) ?? "?"
                    let sz = (order["origSz"] as? String) ?? (order["sz"] as? String) ?? "0"
                    let px = (order["limitPx"] as? String) ?? (order["triggerPx"] as? String) ?? "0"
                    let status = (entry["status"] as? String) ?? (order["orderStatus"] as? String) ?? "?"
                    let orderType = (order["orderType"] as? String) ?? ""
                    let timestamp = (order["timestamp"] as? Double) ?? 0

                    let isCancelled = status.lowercased().contains("cancel")
                    let isFilled = status.lowercased().contains("filled")
                    let isBuy = side == "B"

                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                Text(coin)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(.white)
                                Text(isBuy ? "BUY" : "SELL")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(isBuy ? Color.hlGreen : Color.tradingRed)
                                    .cornerRadius(3)
                                if !orderType.isEmpty {
                                    Text(orderType)
                                        .font(.system(size: 8, weight: .medium))
                                        .foregroundColor(Color(white: 0.5))
                                }
                                if isCancelled {
                                    Text("Cancelled")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundColor(.orange)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .background(Color.orange.opacity(0.15))
                                        .cornerRadius(3)
                                } else if isFilled {
                                    Text("Filled")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundColor(.hlGreen)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .background(Color.hlGreen.opacity(0.15))
                                        .cornerRadius(3)
                                }
                            }
                            if timestamp > 0 {
                                Text(Date(timeIntervalSince1970: timestamp / 1000), style: .relative)
                                    .font(.system(size: 9))
                                    .foregroundColor(Color(white: 0.4))
                            }
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(sz)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.white)
                            Text("@ $\(px)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(Color(white: 0.5))
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    Divider().background(Color(white: 0.1))
                }
            }
        }
    }

    private var bottomTradeHistoryView: some View {
        VStack(spacing: 0) {
            if tradingVM.isLoadingBottom && tradingVM.tradeHistory.isEmpty {
                ProgressView().tint(Color(white: 0.3))
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else if tradingVM.tradeHistory.isEmpty {
                emptyTabView("No trade history")
            } else {
                // Column headers
                HStack(spacing: 0) {
                    Text("Trade")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("Trade Value")
                        .frame(width: 90, alignment: .center)
                    Text("Closed PNL")
                        .frame(width: 85, alignment: .trailing)
                }
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(Color(white: 0.35))
                .padding(.horizontal, 12)
                .padding(.vertical, 4)

                ForEach(tradingVM.tradeHistory) { fill in
                    let pxVal = Double(fill.px) ?? 0
                    let szVal = Double(fill.sz) ?? 0
                    let tradeValue = pxVal * szVal
                    let fee = Double(fill.fee) ?? 0
                    let closedPnl = Double(fill.closedPnl) ?? 0
                    let totalPnl = closedPnl - fee

                    HStack(spacing: 0) {
                        // Left: Coin + details
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                Text(displayCoin(fill.coin))
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(.white)
                                Text(fill.isBuy ? "Buy" : "Sell")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundColor(fill.isBuy ? .hlGreen : .tradingRed)
                            }
                            Text("\(fill.sz) @ $\(fill.px)")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(Color(white: 0.4))
                            Text(fill.timeStr)
                                .font(.system(size: 8))
                                .foregroundColor(Color(white: 0.3))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        // Center: Trade Value
                        Text(String(format: "%.2f USDC", tradeValue))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(Color(white: 0.5))
                            .frame(width: 90, alignment: .center)

                        // Right: Closed PNL + Fee
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(String(format: "%+.2f USDC", totalPnl))
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundColor(totalPnl >= 0 ? .hlGreen : .tradingRed)
                            Text("fee: \(String(format: "%.4f", fee))")
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundColor(Color(white: 0.3))
                        }
                        .frame(width: 85, alignment: .trailing)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)

                    Divider().background(Color(white: 0.1))
                }
            }
        }
    }

    // MARK: - Funding History tab

    private var bottomFundingHistoryView: some View {
        VStack(spacing: 0) {
            if tradingVM.isLoadingBottom && tradingVM.fundingHistory.isEmpty {
                ProgressView().tint(Color(white: 0.3))
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else if tradingVM.fundingHistory.isEmpty {
                emptyTabView("No funding history")
            } else {
                ForEach(tradingVM.fundingHistory) { fund in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(displayCoin(fund.coin))
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.white)
                            Text("Size: \(fund.szi)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(Color(white: 0.4))
                        }

                        Spacer()

                        VStack(alignment: .trailing, spacing: 2) {
                            Text(fund.timeStr)
                                .font(.system(size: 9))
                                .foregroundColor(Color(white: 0.35))
                            let amt = Double(fund.usdc) ?? 0
                            Text(String(format: "%+.4f", amt))
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundColor(amt >= 0 ? .hlGreen : .tradingRed)
                            if let rate = Double(fund.fundingRate) {
                                Text(String(format: "%.6f%%", rate * 100))
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundColor(Color(white: 0.3))
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)

                    Divider().background(Color(white: 0.1))
                }
            }
        }
    }

    // MARK: - Coin display name resolver

    /// Resolve API coin names (e.g. "@107", "BTC", "HYPE/USDC") to display names.
    /// The HL API uses @index for spot pairs where index is the SPOT pair index (not 10000+).
    private func displayCoin(_ apiCoin: String) -> String {
        // Check if it's an @index reference
        if apiCoin.hasPrefix("@"), let idx = Int(apiCoin.dropFirst()) {
            // Try spot market first (index = 10000 + pairIndex)
            if let m = marketsVM.markets.first(where: { $0.index == 10000 + idx }) {
                let base = m.asset.name.components(separatedBy: "/").first ?? m.asset.name
                return base
            }
            // Then try perp / HIP-3 market (exact index)
            if let m = marketsVM.markets.first(where: { $0.index == idx }) {
                return m.displayName
            }
        }
        // Check if it matches a market's asset name directly (perps: "BTC", "ETH")
        if let m = marketsVM.markets.first(where: {
            $0.asset.name == apiCoin && !$0.isSpot
        }) {
            return m.displayName
        }
        // Check spot pairs (e.g. "HYPE/USDC") → return base name
        if apiCoin.contains("/") {
            return apiCoin.components(separatedBy: "/").first ?? apiCoin
        }
        return apiCoin
    }

    // MARK: - Empty state

    private func emptyTabView(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 12))
            .foregroundColor(Color(white: 0.3))
            .frame(maxWidth: .infinity, minHeight: 80)
    }

    // MARK: - Sync market context to TradingViewModel

    private func syncMarketContext() {
        if let m = currentMarket {
            tradingVM.isSpotMarket = m.isSpot
            tradingVM.assetIndex = m.index
            // For spot markets, use the base TOKEN's szDecimals (pair szDecimals is often wrong)
            // Known spot token decimals from HL API
            let spotTokenDecimals: [String: Int] = [
                "UBTC": 5, "HYPE": 2, "USDC": 8, "USDH": 2, "USDT0": 2,
                "USDE": 2, "PURR": 0, "JEFF": 0, "USOL": 5
            ]
            let base = m.baseName
            let sz = spotTokenDecimals[base]
                ?? MarketsViewModel.szDecimalsCache[base]
                ?? MarketsViewModel.szDecimalsCache[m.spotDisplayBaseName]
                ?? (m.asset.szDecimals > 0 ? m.asset.szDecimals : 4)
            tradingVM.szDecimals = sz
            tradingVM.displayCoinName = m.isSpot ? m.spotDisplayBaseName : m.displayName
        }
    }

    // MARK: - Formatters

    private func formatPrice(_ p: Double) -> String {
        if p >= 10_000 { return String(format: "%.1f", p) }
        if p >= 1_000  { return String(format: "%.2f", p) }
        if p >= 1      { return String(format: "%.4f", p) }
        return String(format: "%.6f", p)
    }

    private func formatSize(_ v: Double) -> String {
        if v >= 1_000_000 { return String(format: "%.1fM", v / 1_000_000) }
        if v >= 1_000     { return String(format: "%.1fK", v / 1_000) }
        return String(format: "%.0f", v)
    }

    // MARK: - Keyboard navigation bar

    private var activeFields: [TradeField] {
        var fields: [TradeField] = [.size]
        if tradingVM.orderType == .limit { fields.append(.limitPrice) }
        if tradingVM.tpEnabled { fields.append(.tpPrice) }
        if tradingVM.slEnabled { fields.append(.slPrice) }
        return fields
    }

    private var tradeKeyboardBar: some View {
        let fields = activeFields
        let currentIdx = fields.firstIndex(where: { $0 == focusedField }) ?? 0
        let isFirst = currentIdx == 0
        let isLast = currentIdx == fields.count - 1
        let showArrows = fields.count > 1

        return HStack(spacing: 12) {
            if showArrows {
                Button {
                    if currentIdx > 0 {
                        haptic.prepare()
                        haptic.impactOccurred()
                        focusedField = fields[currentIdx - 1]
                    }
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(isFirst ? Color(white: 0.3) : .white)
                }
                .disabled(isFirst)

                Button {
                    if currentIdx < fields.count - 1 {
                        haptic.prepare()
                        haptic.impactOccurred()
                        focusedField = fields[currentIdx + 1]
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(isLast ? Color(white: 0.3) : .white)
                }
                .disabled(isLast)
            }

            Spacer()

            Button("Done") { focusedField = nil }
                .fontWeight(.semibold)
                .foregroundColor(.hlGreen)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(white: 0.12))
    }

    // MARK: - Slippage check & TWAP

    /// Check slippage (fetching order book if needed) and either show warning or submit
    private func checkSlippageAndSubmit() async {
        guard !hideSlippageWarning else { executeOrder(); return }

        let sz = tradingVM.positionSize
        guard sz > 0 else { executeOrder(); return }

        // Use existing order book or fetch fresh one
        var book = chartVM.orderBook
        if book == nil || book!.asks.isEmpty {
            book = try? await HyperliquidAPI.shared.fetchOrderBook(coin: tradingVM.selectedSymbol)
        }
        guard let ob = book else { executeOrder(); return }

        let isBuy = tradingVM.side == .buy
        let slippage: Double?

        if tradingVM.orderType == .market {
            slippage = ob.estimateSlippage(isBuy: isBuy, sizeTokens: sz)?.slippagePct
        } else if tradingVM.orderType == .limit {
            slippage = ob.checkLimitSlippage(isBuy: isBuy, limitPrice: tradingVM.limitPriceValue, sizeTokens: sz)
        } else {
            slippage = nil
        }

        if let s = slippage, s > 0.05 {
            pendingSlippagePct = s
            let levels = isBuy ? ob.asks : ob.bids
            pendingBookDepthUSD = levels.reduce(0) { $0 + $1.size * $1.price }
            showSlippageWarning = true
        } else {
            executeOrder()
        }
    }

    private var orderButtonLabel: String {
        if isSpotMarket {
            return tradingVM.side == .buy ? "Buy \(chartVM.displayBaseName)" : "Sell \(chartVM.displayBaseName)"
        }
        return tradingVM.side == .buy ? "Long \(chartVM.displayBaseName)" : "Short \(chartVM.displayBaseName)"
    }

    private func executeOrder() {
        Task {
            await tradingVM.submitOrder()
            // Refresh open orders in background (without switching tab)
            try? await Task.sleep(for: .milliseconds(1500))
            await tradingVM.refreshOpenOrdersBackground()
            await tradingVM.fetchBottomTabData()
        }
    }

    /// Switch to TWAP mode with recommended duration and submit
    private func executeTWAP(duration: Int) {
        tradingVM.orderType = .twap
        tradingVM.twapDuration = duration
        Task {
            await tradingVM.submitOrder()
        }
    }
}
