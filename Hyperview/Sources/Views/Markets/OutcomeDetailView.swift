import SwiftUI

/// Detail + trading view for HIP-4 outcome questions.
/// Handles multi-outcome questions (picker), custom side names, and priceBinary options.
/// Three tabs: Trade, Activity (live bets), Order Book.
struct OutcomeDetailView: View {
    let question: OutcomeQuestion
    @Environment(\.dismiss) var dismiss
    @State private var selectedOutcomeIndex = 0
    @State private var selectedSideIndex = 0
    @State private var amount: String = ""
    @State private var showOrderConfirm = false
    @State private var selectedTab: DetailTab = .trade

    // Activity
    @State private var recentTrades: [Trade] = []
    @State private var isLoadingTrades = false

    // Order Book
    @State private var orderBook: OrderBook?
    @State private var isLoadingBook = false

    // Chart
    @State private var candles: [Candle] = []
    @State private var isLoadingCandles = false
    @State private var chartInterval: ChartInterval = .fifteenMin
    @State private var chartDragIndex: Int? = nil

    // Navigation
    @State private var walletAddress: String? = nil

    enum DetailTab: String, CaseIterable {
        case trade    = "Trade"
        case activity = "Activity"
        case book     = "Book"
    }

    private var selectedOutcome: OutcomeMarket {
        question.outcomes.indices.contains(selectedOutcomeIndex)
            ? question.outcomes[selectedOutcomeIndex]
            : question.outcomes[0]
    }

    private var selectedSide: OutcomeSide? {
        selectedOutcome.sides.indices.contains(selectedSideIndex)
            ? selectedOutcome.sides[selectedSideIndex]
            : selectedOutcome.sides.first
    }

    /// The API coin for the currently selected side (e.g. "#10")
    private var selectedApiCoin: String {
        selectedSide?.apiCoin ?? "#\(selectedOutcome.outcomeId * 10)"
    }

    private var sidePrice: Double { selectedSide?.price ?? 0.5 }
    private var amountValue: Double { Double(amount) ?? 0 }
    private var potentialPayout: Double {
        guard sidePrice > 0 else { return 0 }
        return 1.0 / sidePrice
    }
    private var potentialProfit: Double {
        guard amountValue > 0, sidePrice > 0 else { return 0 }
        return amountValue * (potentialPayout - 1)
    }

    @FocusState private var amountFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollViewReader { scrollProxy in
                ScrollView {
                    VStack(spacing: 0) {
                        headerCard
                        if question.isMultiOutcome { outcomePicker }
                        probabilitySection
                        if question.isOption, let pb = selectedOutcome.priceBinary {
                            optionDetails(pb)
                        }

                        // Price chart
                        probabilityChart

                        // Tab picker
                        tabPicker

                        // Tab content
                        switch selectedTab {
                        case .trade:
                            tradingSection
                            marketInfo
                        case .activity:
                            activityContent
                        case .book:
                            orderBookContent
                        }
                    }
                }
                .onChange(of: amountFocused) { _, focused in
                    if focused {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            withAnimation(.easeOut(duration: 0.25)) {
                                scrollProxy.scrollTo("potentialReturn", anchor: .bottom)
                            }
                        }
                    }
                }
            }
            .background(Color.hlBackground)
            .navigationBarTitleDisplayMode(.inline)
            .keyboardDoneBar()
            .navigationDestination(isPresented: Binding(
                get: { walletAddress != nil },
                set: { if !$0 { walletAddress = nil } }
            )) {
                if let addr = walletAddress {
                    WalletDetailView(address: addr)
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(Color(white: 0.5))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                }
                ToolbarItem(placement: .principal) { TestnetBadge() }
            }
        }
        .onAppear { loadCandles() }
        .onChange(of: selectedOutcomeIndex) { _, _ in
            refreshTabData()
            loadCandles()
        }
        .onChange(of: selectedSideIndex) { _, _ in
            refreshTabData()
        }
    }

    private func refreshTabData() {
        switch selectedTab {
        case .activity: loadTrades()
        case .book:     loadOrderBook()
        case .trade:    break
        }
    }

    // MARK: - Tab picker

    private var tabPicker: some View {
        VStack(spacing: 0) {
            Divider().background(Color(white: 0.15))
            HStack(spacing: 0) {
                ForEach(DetailTab.allCases, id: \.self) { tab in
                    Button {
                        withAnimation(.easeInOut(duration: 0.12)) { selectedTab = tab }
                        if tab == .activity && recentTrades.isEmpty { loadTrades() }
                        if tab == .book && orderBook == nil { loadOrderBook() }
                    } label: {
                        Text(tab.rawValue)
                            .font(.system(size: 13, weight: selectedTab == tab ? .bold : .medium))
                            .foregroundColor(selectedTab == tab ? .white : Color(white: 0.45))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .overlay(alignment: .bottom) {
                                if selectedTab == tab {
                                    Rectangle()
                                        .fill(Color.hlGreen)
                                        .frame(height: 2)
                                }
                            }
                    }
                }
            }
            .background(Color(white: 0.07))
        }
    }

    // MARK: - Header

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                if let pb = selectedOutcome.priceBinary {
                    CoinIconView(symbol: pb.underlying, hlIconName: pb.underlying, iconSize: 36)
                } else {
                    ZStack {
                        Circle()
                            .fill(Color.hlGreen.opacity(0.15))
                            .frame(width: 36, height: 36)
                        Image(systemName: question.isMultiOutcome ? "list.bullet" : "chart.pie.fill")
                            .font(.system(size: 18))
                            .foregroundColor(.hlGreen)
                    }
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(question.displayTitle)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundColor(.white)
                    if question.isMultiOutcome {
                        Text("\(question.outcomes.count) outcomes")
                            .font(.system(size: 12))
                            .foregroundColor(Color(white: 0.45))
                    }
                }
            }

            if !question.description.isEmpty && !question.description.contains("class:priceBinary") {
                Text(question.description)
                    .font(.system(size: 12))
                    .foregroundColor(Color(white: 0.45))
                    .padding(.top, 2)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(white: 0.11))
    }

    // MARK: - Outcome picker (for multi-outcome questions)

    private var outcomePicker: some View {
        VStack(spacing: 0) {
            Divider().background(Color(white: 0.12))

            VStack(spacing: 0) {
                ForEach(Array(question.outcomes.enumerated()), id: \.element.id) { index, outcome in
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            selectedOutcomeIndex = index
                            selectedSideIndex = 0
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Circle()
                                .fill(selectedOutcomeIndex == index ? Color.hlGreen : Color(white: 0.15))
                                .frame(width: 8, height: 8)

                            Text(outcome.name)
                                .font(.system(size: 14, weight: selectedOutcomeIndex == index ? .semibold : .regular))
                                .foregroundColor(selectedOutcomeIndex == index ? .white : Color(white: 0.55))

                            Spacer()

                            Text(outcome.probabilityFormatted)
                                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                .foregroundColor(probColor(outcome.side0Price))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                        .background(selectedOutcomeIndex == index
                                    ? Color.hlGreen.opacity(0.06)
                                    : Color.clear)
                    }
                    .buttonStyle(.plain)

                    if index < question.outcomes.count - 1 {
                        Divider().background(Color(white: 0.1)).padding(.leading, 34)
                    }
                }
            }
            .background(Color(white: 0.07))
        }
    }

    // MARK: - Probability (compact, follows selected SIDE)

    private var probabilitySection: some View {
        let displayPrice = sidePrice
        let displayColor = selectedSideIndex == 0 ? probColor(displayPrice) : probColorInverted(displayPrice)

        return VStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(String(format: "%.1f%%", displayPrice * 100))
                    .font(.system(size: 28, weight: .bold, design: .monospaced))
                    .foregroundColor(displayColor)
                    .contentTransition(.numericText())
                    .animation(.easeInOut(duration: 0.2), value: sidePrice)

                Spacer()

                // Side pills inline
                ForEach(selectedOutcome.sides) { side in
                    let isFirst = side.sideIndex == 0
                    let color: Color = isFirst ? .hlGreen : .tradingRed
                    HStack(spacing: 3) {
                        Circle().fill(color).frame(width: 6, height: 6)
                        Text(side.name)
                            .font(.system(size: 11, weight: .medium))
                        Text(String(format: "%.1f\u{00A2}", side.price * 100))
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                    }
                    .foregroundColor(color)
                }
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.tradingRed.opacity(0.3))
                        .frame(height: 8)
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.hlGreen)
                        .frame(width: max(geo.size.width * selectedOutcome.side0Price, 4), height: 8)
                }
            }
            .frame(height: 8)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Probability chart

    private var probabilityChart: some View {
        VStack(spacing: 0) {
            // Drag tooltip
            if let idx = chartDragIndex, candles.indices.contains(idx) {
                let candle = candles[idx]
                HStack(spacing: 8) {
                    Text(chartTimeFormat(candle.openTime))
                        .foregroundColor(Color(white: 0.5))
                    Text(String(format: "%.1f%%", candle.close * 100))
                        .foregroundColor(.white)
                        .fontWeight(.bold)
                }
                .font(.system(size: 11, design: .monospaced))
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(white: 0.08))
            }

            // Interval picker
            HStack(spacing: 0) {
                ForEach([ChartInterval.fiveMin, .fifteenMin, .oneHour, .fourHour, .oneDay], id: \.self) { interval in
                    Button {
                        chartInterval = interval
                        chartDragIndex = nil
                        loadCandles()
                    } label: {
                        Text(interval.displayName)
                            .font(.system(size: 10, weight: chartInterval == interval ? .bold : .medium))
                            .foregroundColor(chartInterval == interval ? .hlGreen : Color(white: 0.4))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                    }
                }
            }
            .padding(.horizontal, 16)

            // Chart area
            if isLoadingCandles && candles.isEmpty {
                ProgressView()
                    .tint(Color(white: 0.3))
                    .frame(height: 120)
                    .frame(maxWidth: .infinity)
            } else if candles.count >= 2 {
                outcomeChart
                    .frame(height: 120)
                    .padding(.horizontal, 16)
                    .clipped()
            } else {
                Text("No chart data")
                    .font(.system(size: 11))
                    .foregroundColor(Color(white: 0.3))
                    .frame(height: 80)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 4)
    }

    private var outcomeChart: some View {
        let closes = candles.map(\.close)
        let minVal = closes.min() ?? 0
        let maxVal = closes.max() ?? 1
        let range  = max(maxVal - minVal, 0.001)
        let isUp   = (closes.last ?? 0) >= (closes.first ?? 0)
        let lineColor: Color = isUp ? .hlGreen : .tradingRed

        return ZStack {
            Canvas { context, size in
                guard closes.count >= 2 else { return }

                let stepX = size.width / CGFloat(closes.count - 1)

                var path = Path()
                for (i, val) in closes.enumerated() {
                    let x = CGFloat(i) * stepX
                    let y = size.height * (1 - CGFloat((val - minVal) / range))
                    if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                    else { path.addLine(to: CGPoint(x: x, y: y)) }
                }

                context.stroke(path, with: .color(lineColor), lineWidth: 1.5)

                var fillPath = path
                fillPath.addLine(to: CGPoint(x: size.width, y: size.height))
                fillPath.addLine(to: CGPoint(x: 0, y: size.height))
                fillPath.closeSubpath()

                context.fill(fillPath, with: .linearGradient(
                    Gradient(colors: [lineColor.opacity(0.2), lineColor.opacity(0.0)]),
                    startPoint: CGPoint(x: size.width / 2, y: 0),
                    endPoint: CGPoint(x: size.width / 2, y: size.height)
                ))

                // Y-axis
                context.draw(Text(String(format: "%.0f%%", maxVal * 100)).font(.system(size: 8)).foregroundColor(Color(white: 0.3)),
                             at: CGPoint(x: size.width - 18, y: 8))
                context.draw(Text(String(format: "%.0f%%", minVal * 100)).font(.system(size: 8)).foregroundColor(Color(white: 0.3)),
                             at: CGPoint(x: size.width - 18, y: size.height - 8))

                // Crosshair
                if let idx = chartDragIndex, idx < closes.count {
                    let x = CGFloat(idx) * stepX
                    let y = size.height * (1 - CGFloat((closes[idx] - minVal) / range))

                    // Vertical line
                    context.stroke(Path { p in
                        p.move(to: CGPoint(x: x, y: 0))
                        p.addLine(to: CGPoint(x: x, y: size.height))
                    }, with: .color(Color(white: 0.3)), style: StrokeStyle(lineWidth: 0.5, dash: [4, 3]))

                    // Dot
                    context.fill(Path(ellipseIn: CGRect(x: x - 4, y: y - 4, width: 8, height: 8)),
                                 with: .color(lineColor))
                    context.stroke(Path(ellipseIn: CGRect(x: x - 4, y: y - 4, width: 8, height: 8)),
                                   with: .color(.black), lineWidth: 1.5)
                }
            }
            .gesture(
                LongPressGesture(minimumDuration: 0.2)
                    .sequenced(before: DragGesture(minimumDistance: 0))
                    .onChanged { value in
                        switch value {
                        case .second(true, let drag):
                            guard let drag, closes.count >= 2 else { return }
                            let stepX = UIScreen.main.bounds.width - 32
                            let idx = Int((drag.location.x / stepX) * CGFloat(closes.count - 1))
                            chartDragIndex = max(0, min(idx, closes.count - 1))
                        default: break
                        }
                    }
                    .onEnded { _ in
                        chartDragIndex = nil
                    }
            )
        }
    }

    private func chartTimeFormat(_ date: Date) -> String {
        let fmt = DateFormatter()
        switch chartInterval {
        case .fiveMin, .fifteenMin, .thirtyMin:
            fmt.dateFormat = "HH:mm"
        case .oneHour, .twoHour, .fourHour:
            fmt.dateFormat = "MMM d HH:mm"
        default:
            fmt.dateFormat = "MMM d"
        }
        return fmt.string(from: date)
    }

    private func loadCandles() {
        isLoadingCandles = true
        let coin = "#\(selectedOutcome.outcomeId * 10)"
        let interval = chartInterval
        Task {
            do {
                let result = try await HyperliquidAPI.shared.fetchOutcomeCandles(
                    coin: coin, interval: interval, limit: 100)
                await MainActor.run {
                    candles = result
                    isLoadingCandles = false
                }
            } catch {
                await MainActor.run { isLoadingCandles = false }
                print("Failed to load outcome candles: \(error)")
            }
        }
    }

    // MARK: - Option details

    private func optionDetails(_ pb: PriceBinaryInfo) -> some View {
        VStack(spacing: 0) {
            Divider().background(Color(white: 0.15))
            HStack(spacing: 0) {
                detailCell("Underlying", pb.underlying)
                detailCell("Strike", pb.formattedStrike)
                detailCell("Expiry", pb.formattedExpiryFull)
                detailCell("Time", pb.timeRemaining)
            }
            .padding(.vertical, 12)
            .background(Color(white: 0.08))
        }
    }

    private func detailCell(_ label: String, _ value: String) -> some View {
        VStack(spacing: 3) {
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(Color(white: 0.4))
            Text(value)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Trading section

    private var tradingSection: some View {
        VStack(spacing: 12) {
            // Side toggle
            HStack(spacing: 0) {
                ForEach(Array(selectedOutcome.sides.enumerated()), id: \.element.id) { index, side in
                    sideTab(side, index: index)
                }
            }
            .background(Color(white: 0.08))
            .cornerRadius(10)
            .padding(.horizontal, 16)
            .padding(.top, 12)

            // Amount input
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Text("$")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(Color(white: 0.3))
                    TextField("0", text: $amount)
                        .font(.system(size: 17, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                        .keyboardType(.decimalPad)
                        .focused($amountFocused)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color(white: 0.08))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(white: 0.18), lineWidth: 1)
                )

                ForEach(["10", "25", "100"], id: \.self) { val in
                    Button { amount = val } label: {
                        Text("$\(val)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(amount == val ? .black : Color(white: 0.45))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 7)
                            .background(amount == val ? Color.hlGreen : Color(white: 0.1))
                            .cornerRadius(6)
                    }
                }
            }
            .padding(.horizontal, 16)

            returnsCard

            // Buy button
            let sideName = selectedSide?.name ?? "Yes"
            let sideColor: Color = selectedSideIndex == 0 ? .hlGreen : .tradingRed
            Button {
                showOrderConfirm = true
            } label: {
                Text("Buy \(sideName)\(amountValue > 0 ? " \u{2014} $\(amount)" : "")")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(sideColor)
                    .cornerRadius(10)
            }
            .padding(.horizontal, 16)
            .disabled(amountValue <= 0)
            .opacity(amountValue > 0 ? 1 : 0.4)

            Text("Testnet only \u{2014} no real funds")
                .font(.system(size: 10))
                .foregroundColor(Color(white: 0.25))
                .padding(.bottom, 6)
        }
        .alert("Confirm Order", isPresented: $showOrderConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("Confirm") { }
        } message: {
            let sideName = selectedSide?.name ?? "Yes"
            Text("Buy \(sideName) for $\(amount) at \(String(format: "%.1f\u{00A2}", sidePrice * 100))\n\nTestnet \u{2014} no real funds.")
        }
    }

    private func sideTab(_ side: OutcomeSide, index: Int) -> some View {
        let isSelected = selectedSideIndex == index
        let color: Color = index == 0 ? .hlGreen : .tradingRed

        return Button {
            withAnimation(.easeInOut(duration: 0.12)) { selectedSideIndex = index }
        } label: {
            HStack(spacing: 5) {
                Text(side.name)
                    .font(.system(size: 14, weight: .bold))
                Text(String(format: "%.0f\u{00A2}", side.price * 100))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
            }
            .foregroundColor(isSelected ? .black : color)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(isSelected ? color : Color.clear)
            .cornerRadius(8)
        }
    }

    // MARK: - Returns card

    private var returnsCard: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Avg price").foregroundColor(Color(white: 0.45))
                Spacer()
                Text(String(format: "%.1f\u{00A2}", sidePrice * 100)).foregroundColor(.white)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 14).padding(.vertical, 8)

            Divider().background(Color(white: 0.12))

            HStack {
                Text("Shares").foregroundColor(Color(white: 0.45))
                Spacer()
                Text(amountValue > 0 ? String(format: "%.1f", amountValue / sidePrice) : "\u{2014}")
                    .foregroundColor(.white)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 14).padding(.vertical, 8)

            Divider().background(Color(white: 0.12))

            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Potential return")
                        .font(.system(size: 12))
                        .foregroundColor(Color(white: 0.45))
                    if amountValue > 0 {
                        Text(String(format: "+%.0f%%", potentialProfit / amountValue * 100))
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.hlGreen)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    if amountValue > 0 {
                        Text(String(format: "$%.2f", amountValue + potentialProfit))
                            .font(.system(size: 26, weight: .bold, design: .monospaced))
                            .foregroundColor(.hlGreen)
                        Text(String(format: "+$%.2f profit", potentialProfit))
                            .font(.system(size: 12))
                            .foregroundColor(Color(white: 0.4))
                    } else {
                        Text("$\u{2014}")
                            .font(.system(size: 26, weight: .bold, design: .monospaced))
                            .foregroundColor(Color(white: 0.25))
                    }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 16)
            .background(Color.hlGreen.opacity(amountValue > 0 ? 0.06 : 0))
            .id("potentialReturn")
        }
        .background(Color(white: 0.07))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(white: 0.13), lineWidth: 1)
        )
        .padding(.horizontal, 16)
    }

    // MARK: - Activity content (inline in ScrollView)

    private var activityContent: some View {
        Group {
            if isLoadingTrades && recentTrades.isEmpty {
                ProgressView()
                    .tint(.white)
                    .padding(.vertical, 40)
                    .frame(maxWidth: .infinity)
            } else if recentTrades.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock")
                        .font(.system(size: 24))
                        .foregroundColor(Color(white: 0.25))
                    Text("No recent activity")
                        .font(.system(size: 13))
                        .foregroundColor(Color(white: 0.4))
                }
                .padding(.vertical, 40)
                .frame(maxWidth: .infinity)
            } else {
                LazyVStack(spacing: 0) {
                    // Column headers
                    HStack(spacing: 0) {
                        Text("Address")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("Side")
                            .frame(width: 30, alignment: .center)
                        Text("Price")
                            .frame(width: 48, alignment: .trailing)
                        Text("Size")
                            .frame(width: 40, alignment: .trailing)
                        Text("Time")
                            .frame(width: 46, alignment: .trailing)
                    }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Color(white: 0.4))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)

                    Divider().background(Color(white: 0.12))

                    ForEach(recentTrades) { trade in
                        tradeRow(trade)
                    }
                }
            }
        }
        .onAppear {
            if recentTrades.isEmpty { loadTrades() }
        }
    }

    private func tradeRow(_ trade: Trade) -> some View {
        let isBuy = trade.isBuy
        let sideName: String = {
            if let sides = question.outcomes[safe: selectedOutcomeIndex]?.sides {
                return isBuy ? (sides.first?.name ?? "Yes") : (sides.count > 1 ? sides[1].name : "No")
            }
            return isBuy ? "Yes" : "No"
        }()
        let color: Color = isBuy ? .hlGreen : .tradingRed
        let addr = tradeAddress(trade)

        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                // Address (clickable, takes remaining space)
                Button {
                    if let full = tradeFullAddress(trade) {
                        walletAddress = full
                    }
                } label: {
                    Text(addr)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(.hlGreen)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)

                // Side — compact pill
                Text(String(sideName.prefix(1)))
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(color)
                    .frame(width: 18, height: 18)
                    .background(color.opacity(0.12))
                    .cornerRadius(3)
                    .frame(width: 30, alignment: .center)

                Text(String(format: "%.1f\u{00A2}", trade.price * 100))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.white)
                    .frame(width: 48, alignment: .trailing)

                Text(String(format: "%.0f", trade.size))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Color(white: 0.6))
                    .frame(width: 40, alignment: .trailing)

                Text(tradeTimeString(trade.tradeTime))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(Color(white: 0.4))
                    .frame(width: 46, alignment: .trailing)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(color.opacity(0.03))

            Divider().background(Color(white: 0.08))
        }
    }

    private func tradeAddress(_ trade: Trade) -> String {
        let h = trade.hash
        if h.count >= 40 {
            let addr = h.suffix(40)
            return "0x\(addr.prefix(6))...\(addr.suffix(4))"
        }
        guard h.count >= 10 else { return h }
        return "\(h.prefix(8))...\(h.suffix(4))"
    }

    private func tradeFullAddress(_ trade: Trade) -> String? {
        let h = trade.hash
        if h.hasPrefix("0x") && h.count == 42 { return h }
        if h.count >= 40 {
            let addr = "0x" + h.suffix(40)
            return addr.count == 42 ? addr : nil
        }
        return nil
    }

    private func tradeTimeString(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "\(Int(interval))s" }
        if interval < 3600 { return "\(Int(interval / 60))m" }
        if interval < 86400 { return "\(Int(interval / 3600))h" }
        let fmt = DateFormatter()
        fmt.dateFormat = "MM/dd"
        return fmt.string(from: date)
    }

    private func loadTrades() {
        guard !isLoadingTrades else { return }
        isLoadingTrades = true
        let coin = selectedApiCoin
        Task {
            do {
                let trades = try await HyperliquidAPI.shared.fetchOutcomeRecentTrades(coin: coin)
                await MainActor.run {
                    recentTrades = trades
                    isLoadingTrades = false
                }
            } catch {
                await MainActor.run { isLoadingTrades = false }
                print("Failed to load outcome trades: \(error)")
            }
        }
    }

    // MARK: - Order Book content (inline in ScrollView)

    private var orderBookContent: some View {
        Group {
            if isLoadingBook && orderBook == nil {
                ProgressView()
                    .tint(.white)
                    .padding(.vertical, 40)
                    .frame(maxWidth: .infinity)
            } else if let book = orderBook {
                VStack(spacing: 0) {
                    // Spread
                    if book.bestBid > 0 && book.bestAsk > 0 {
                        HStack {
                            Text("Spread")
                                .foregroundColor(Color(white: 0.4))
                            Spacer()
                            Text(String(format: "%.2f\u{00A2}", book.spread * 100))
                                .foregroundColor(.white)
                        }
                        .font(.system(size: 11))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color(white: 0.07))
                    }

                    // Column headers
                    HStack(spacing: 0) {
                        Text("Price (\u{00A2})")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("Size")
                            .frame(width: 80, alignment: .trailing)
                        Text("Total")
                            .frame(width: 80, alignment: .trailing)
                    }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Color(white: 0.4))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)

                    Divider().background(Color(white: 0.12))

                    // Asks (reversed, lowest at bottom)
                    let asks = Array(book.asks.prefix(15).reversed())
                    let askCumulative = computeCumulative(asks.reversed())
                    ForEach(Array(asks.enumerated()), id: \.offset) { idx, level in
                        let cumIdx = asks.count - 1 - idx
                        bookLevelRow(level, isBid: false, cumulative: askCumulative[safe: cumIdx] ?? level.size, maxSize: book.maxAskSize)
                    }

                    // Mid price separator
                    HStack {
                        Spacer()
                        Text(String(format: "%.2f\u{00A2}", book.midPrice * 100))
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                        Spacer()
                    }
                    .padding(.vertical, 8)
                    .background(Color(white: 0.08))

                    // Bids
                    let bidLevels = Array(book.bids.prefix(15))
                    let bidCumulative = computeCumulative(bidLevels)
                    ForEach(Array(bidLevels.enumerated()), id: \.offset) { idx, level in
                        bookLevelRow(level, isBid: true, cumulative: bidCumulative[safe: idx] ?? level.size, maxSize: book.maxBidSize)
                    }
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "book.closed")
                        .font(.system(size: 24))
                        .foregroundColor(Color(white: 0.25))
                    Text("No order book data")
                        .font(.system(size: 13))
                        .foregroundColor(Color(white: 0.4))
                }
                .padding(.vertical, 40)
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear {
            if orderBook == nil { loadOrderBook() }
        }
    }

    private func computeCumulative(_ levels: [OrderBookLevel]) -> [Double] {
        var result: [Double] = []
        var sum = 0.0
        for level in levels {
            sum += level.size
            result.append(sum)
        }
        return result
    }

    private func bookLevelRow(_ level: OrderBookLevel, isBid: Bool, cumulative: Double, maxSize: Double) -> some View {
        let color: Color = isBid ? .hlGreen : .tradingRed
        let barWidth = maxSize > 0 ? CGFloat(level.size / maxSize) : 0

        return HStack(spacing: 0) {
            Text(String(format: "%.2f", level.price * 100))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(color)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(String(format: "%.0f", level.size))
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(Color(white: 0.6))
                .frame(width: 80, alignment: .trailing)

            Text(String(format: "%.0f", cumulative))
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(Color(white: 0.4))
                .frame(width: 80, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .background(
            GeometryReader { geo in
                Rectangle()
                    .fill(color.opacity(0.08))
                    .frame(width: geo.size.width * min(barWidth, 1))
                    .frame(maxWidth: .infinity, alignment: isBid ? .leading : .trailing)
            }
        )
    }

    private func loadOrderBook() {
        guard !isLoadingBook else { return }
        isLoadingBook = true
        let coin = selectedApiCoin
        Task {
            do {
                let book = try await HyperliquidAPI.shared.fetchOutcomeOrderBook(coin: coin)
                await MainActor.run {
                    orderBook = book
                    isLoadingBook = false
                }
            } catch {
                await MainActor.run { isLoadingBook = false }
                print("Failed to load outcome order book: \(error)")
            }
        }
    }

    // MARK: - Market info

    private var marketInfo: some View {
        VStack(spacing: 6) {
            Divider().background(Color(white: 0.15))
            VStack(alignment: .leading, spacing: 8) {
                Text("Market Info")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
                infoRow("Type", question.isOption ? "Price Binary (Options)" : "Event Prediction")
                if question.isMultiOutcome {
                    infoRow("Outcomes", question.outcomes.map(\.name).joined(separator: ", "))
                }
                infoRow("Outcome ID", "#\(selectedOutcome.outcomeId)")
                infoRow("Collateral", "USDH")
                infoRow("Leverage", "None (fully collateralized)")
                infoRow("Settlement", "0 or 1 USDH per share")
                if let pb = selectedOutcome.priceBinary {
                    infoRow("Period", pb.period)
                    infoRow("Underlying", pb.underlying)
                }
            }
            .padding(16)
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(Color(white: 0.4))
                .frame(width: 80, alignment: .leading)
            Text(value)
                .font(.system(size: 12))
                .foregroundColor(Color(white: 0.6))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func probColor(_ p: Double) -> Color {
        if p >= 0.7 { return .hlGreen }
        if p <= 0.3 { return .tradingRed }
        return .white
    }

    /// Inverted color for side 1 (No): high price = red (bad for Yes)
    private func probColorInverted(_ p: Double) -> Color {
        if p >= 0.7 { return .tradingRed }
        if p <= 0.3 { return .hlGreen }
        return .white
    }
}

// MARK: - Safe array subscript

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
