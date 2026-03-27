import SwiftUI
import Combine

struct TWAPView: View {
    @ObservedObject private var vm = TWAPViewModel.shared
    @ObservedObject private var appState = AppState.shared
    @EnvironmentObject var marketsVM: MarketsViewModel
    @State private var progressTick = false  // triggers progress bar redraws
    @State private var showCoinPicker = false

    let progressTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            // ── Header ─────────────────────────────────────────
            HStack {
                Text("Live TWAPs")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.white)

                Spacer()

                // Active label (non-interactive)
                Text("Active")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.black)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.hlGreen)
                    .cornerRadius(8)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 4)

            // ── Buy Pressure Card ─────────────────────────────────
            if vm.orders.contains(where: { $0.isActive && $0.coin == "HYPE" }) {
                buyPressureCard
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }

            // ── Filters: Market type + Coin picker ───────────────
            if !vm.orders.isEmpty {
                HStack(spacing: 8) {
                    // Perp / Spot / All pills
                    ForEach(TWAPMarketFilter.allCases, id: \.self) { filter in
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                vm.marketFilter = filter
                                if filter != .perp { vm.perpSubFilter = .all }
                            }
                        } label: {
                            Text(filter.rawValue)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(vm.marketFilter == filter ? .black : Color(white: 0.5))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(vm.marketFilter == filter ? Color.hlGreen : Color(white: 0.12))
                                .cornerRadius(6)
                        }
                    }

                    Spacer()

                    // Coin picker button → opens sheet
                    Button { showCoinPicker = true } label: {
                        HStack(spacing: 4) {
                            Text(vm.selectedCoin == "All" ? "Coin" : vm.selectedCoin)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(vm.selectedCoin != "All" ? .black : Color(white: 0.5))
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(vm.selectedCoin != "All" ? .black : Color(white: 0.4))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(vm.selectedCoin != "All" ? Color.hlGreen : Color(white: 0.12))
                        .cornerRadius(6)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 4)

                // Perp sub-filter: Crypto vs HIP-3
                if vm.marketFilter == .perp {
                    HStack(spacing: 6) {
                        ForEach(TWAPPerpSubFilter.allCases, id: \.self) { sub in
                            Button {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    vm.perpSubFilter = sub
                                }
                            } label: {
                                Text(sub.rawValue)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(vm.perpSubFilter == sub ? .black : Color(white: 0.45))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(vm.perpSubFilter == sub ? Color.hlGreen.opacity(0.85) : Color(white: 0.1))
                                    .cornerRadius(5)
                            }
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 4)
                }
            }

            // ── Summary bar ────────────────────────────────────
            if !vm.orders.isEmpty {
                HStack(spacing: 16) {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color.hlGreen)
                            .frame(width: 6, height: 6)
                        Text("\(vm.activeBuyCount) Buys")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Color.hlGreen)
                    }

                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color.tradingRed)
                            .frame(width: 6, height: 6)
                        Text("\(vm.activeSellCount) Sells")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Color.tradingRed)
                    }

                    Spacer()

                    Text("\(vm.filteredOrders.count) orders")
                        .font(.system(size: 11))
                        .foregroundColor(Color(white: 0.4))
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 4)

                // Sort pills
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(TWAPSortOption.allCases, id: \.self) { opt in
                            Button {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    vm.sortOption = opt
                                }
                            } label: {
                                Text(opt.rawValue)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(vm.sortOption == opt ? .black : Color(white: 0.45))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(vm.sortOption == opt ? Color.hlGreen : Color(white: 0.1))
                                    .cornerRadius(5)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.bottom, 8)
            }

            // ── Content ────────────────────────────────────────
            if vm.orders.isEmpty && !vm.hasLoaded {
                // Not loaded yet — show loading (never "No TWAP")
                Spacer()
                VStack(spacing: 10) {
                    ProgressView()
                        .tint(Color.hlGreen)
                        .scaleEffect(1.2)
                    if let progress = vm.progressText {
                        Text(progress)
                            .font(.system(size: 12))
                            .foregroundColor(Color(white: 0.45))
                    }
                }
                Spacer()
            } else if let error = vm.errorMsg, vm.orders.isEmpty {
                Spacer()
                errorView(error)
                Spacer()
            } else if vm.filteredOrders.isEmpty && vm.hasLoaded {
                // Loaded successfully but filters produce no results
                Spacer()
                Text(vm.showActiveOnly ? "No active TWAPs" : "No TWAPs found")
                    .font(.system(size: 14))
                    .foregroundColor(Color(white: 0.5))
                Spacer()
            } else {
                ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        Color.clear.frame(height: 0).id("twapTop")
                        ForEach(vm.filteredOrders) { order in
                            twapRow(order)
                                .padding(.horizontal, 14)
                        }
                    }
                    .padding(.top, 4)
                    .padding(.bottom, 20)
                }
                .refreshable {
                    await vm.refresh()
                }
                .onChange(of: appState.homeReselect) { _, _ in
                    withAnimation { proxy.scrollTo("twapTop", anchor: .top) }
                }
                }
            }
        }
        .background(Color.hlBackground.ignoresSafeArea())
        .task { await vm.load() }
        .onDisappear { vm.stopPolling() }
        .onReceive(progressTimer) { _ in
            progressTick.toggle()
        }
        .sheet(isPresented: $showCoinPicker) {
            coinPickerSheet
        }
    }

    // MARK: - Coin Picker Sheet

    /// Sort coins by Open Interest in USD (descending), with "All" first
    private var coinsSortedByOI: [String] {
        let markets = marketsVM.markets
        // OI is in tokens, multiply by price to get USD
        let oiUSDMap: [String: Double] = Dictionary(
            markets.map { ($0.symbol, $0.openInterest * $0.price) },
            uniquingKeysWith: { a, _ in a }
        )
        let sorted = vm.availableCoins.filter { $0 != "All" }.sorted {
            (oiUSDMap[$0] ?? 0) > (oiUSDMap[$1] ?? 0)
        }
        return ["All"] + sorted
    }

    private var coinPickerSheet: some View {
        NavigationStack {
            List(coinsSortedByOI, id: \.self) { coin in
                Button {
                    vm.selectedCoin = coin
                    showCoinPicker = false
                } label: {
                    HStack {
                        if coin != "All" {
                            CoinIconView(symbol: coin, hlIconName: coin, iconSize: 22)
                        }
                        Text(coin)
                            .foregroundColor(.white)
                        Spacer()
                        if coin != "All" {
                            oiLabel(for: coin)
                        }
                        if vm.selectedCoin == coin {
                            Image(systemName: "checkmark")
                                .foregroundColor(.hlGreen)
                        }
                    }
                }
                .listRowBackground(Color(white: 0.1))
            }
            .listStyle(.plain)
            .navigationTitle("Select Coin")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showCoinPicker = false }
                        .foregroundColor(.hlGreen)
                }
            }
            .background(Color.hlBackground)
            .scrollContentBackground(.hidden)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private func oiLabel(for coin: String) -> some View {
        if let market = marketsVM.markets.first(where: { $0.symbol == coin }) {
            let oiUSD = market.openInterest * market.price
            if oiUSD > 0 {
                Text(formatOI(oiUSD))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Color(white: 0.4))
            }
        }
    }

    private func formatOI(_ oi: Double) -> String {
        if oi >= 1_000_000_000 { return String(format: "$%.1fB", oi / 1_000_000_000) }
        if oi >= 1_000_000 { return String(format: "$%.1fM", oi / 1_000_000) }
        if oi >= 1_000 { return String(format: "$%.0fK", oi / 1_000) }
        return String(format: "$%.0f", oi)
    }

    // MARK: - Buy Pressure Card

    /// Compute HYPE buy pressure locally from orders (real-time)
    private func localHypePressure(windowSeconds: Double) -> Double {
        let now = Date()
        var net: Double = 0
        for order in vm.orders where order.isActive && order.coin == "HYPE" {
            guard order.durationMinutes > 0 else { continue }
            let totalSec = Double(order.durationMinutes) * 60
            let elapsed = now.timeIntervalSince(order.timestamp)
            let remaining = max(totalSec - elapsed, 0)
            guard remaining > 0 else { continue }
            let ratePerSec = order.size / totalSec
            let inWindow = min(remaining, windowSeconds)
            let sizeInWindow = ratePerSec * inWindow
            let px = order.markPrice ?? 0
            let usd = px > 0 ? sizeInWindow * px : 0
            net += (order.isBuy ? 1 : -1) * usd
        }
        return net
    }

    private var buyPressureCard: some View {
        let _ = progressTick  // force re-evaluation every second
        let p1h = localHypePressure(windowSeconds: 3600)
        let p24h = localHypePressure(windowSeconds: 86400)

        return VStack(spacing: 10) {
            Text("TWAPs HYPE Buy Pressure")
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(.white)

            HStack {
                Text("Next 1h:")
                    .font(.system(size: 13))
                    .foregroundColor(Color(white: 0.5))
                Spacer()
                Text(formattedPressureUSD(p1h))
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(p1h >= 0 ? .hlGreen : .tradingRed)
            }

            HStack {
                Text("Next 24h:")
                    .font(.system(size: 13))
                    .foregroundColor(Color(white: 0.5))
                Spacer()
                Text(formattedPressureUSD(p24h))
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(p24h >= 0 ? .hlGreen : .tradingRed)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(white: 0.09))
        .cornerRadius(12)
    }

    private func formattedPressureUSD(_ value: Double) -> String {
        let sign = value >= 0 ? "+" : ""
        let absVal = abs(value)
        if absVal >= 1_000_000 {
            return "\(sign)\(formatWithCommas(Int(value)))$"
        }
        return "\(sign)\(formatWithCommas(Int(value)))$"
    }

    private func formatWithCommas(_ n: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        return formatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    // MARK: - Error View

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Text(message)
                .font(.system(size: 13))
                .foregroundColor(Color(white: 0.5))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button {
                Task { await vm.load() }
            } label: {
                Text("Retry")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.black)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(Color.hlGreen)
                    .cornerRadius(8)
            }
        }
    }

    // MARK: - TWAP Row

    private func twapRow(_ order: TWAPOrder) -> some View {
        NavigationLink {
            WalletDetailView(address: order.user)
                .toolbar(.hidden, for: .tabBar)
        } label: {
            VStack(spacing: 0) {
                // Top row: coin + side + size + duration
                HStack(spacing: 8) {
                    // Coin icon
                    CoinIconView(symbol: order.coin, hlIconName: order.coin, iconSize: 22)

                    // Coin name
                    Text(order.coin)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)

                    // BUY/SELL badge
                    Text(order.isBuy ? "BUY" : "SELL")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(order.isBuy ? Color.hlGreen.opacity(0.8) : Color.tradingRed)
                        .cornerRadius(4)

                    // SPOT/PERP badge
                    Text(order.isSpot ? "SPOT" : "PERP")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(order.isSpot ? Color.cyan.opacity(0.8) : Color(white: 0.5))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(order.isSpot ? Color.cyan.opacity(0.1) : Color(white: 0.12))
                        .cornerRadius(3)

                    // Status indicator
                    if order.isActive {
                        Circle()
                            .fill(Color.hlGreen)
                            .frame(width: 6, height: 6)
                    }

                    Spacer()

                    // Size: USD value primary, token size secondary
                    VStack(alignment: .trailing, spacing: 1) {
                        if let totalVal = order.formattedTotalValue {
                            Text(totalVal)
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(.white)
                        }
                        Text("\(order.formattedSize) \(order.coin)")
                            .font(.system(size: 10))
                            .foregroundColor(Color(white: 0.45))
                    }
                }

                // Middle row: progress bar (active orders only)
                if order.isActive {
                    let _ = progressTick  // force re-evaluation on timer
                    let prog = order.progress
                    VStack(spacing: 3) {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                // Background track
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color(white: 0.15))
                                    .frame(height: 6)

                                // Progress fill
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(
                                        LinearGradient(
                                            colors: [Color.hlGreen.opacity(0.7), Color.hlGreen],
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        )
                                    )
                                    .frame(width: max(geo.size.width * prog, 4), height: 6)
                                    .animation(.easeInOut(duration: 1), value: prog)
                            }
                        }
                        .frame(height: 6)

                        HStack {
                            Text(order.formattedDuration)
                                .font(.system(size: 9))
                                .foregroundColor(Color(white: 0.4))
                            Spacer()
                            // Live remaining value in $
                            if let remVal = order.formattedRemainingValue {
                                Text("\(remVal) left")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(order.isBuy ? Color.hlGreen : Color.tradingRed)
                            }
                            Spacer()
                            Text(order.remainingTime)
                                .font(.system(size: 9))
                                .foregroundColor(Color.hlGreen.opacity(0.8))
                            Spacer()
                            Text("\(Int(prog * 100))%")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(Color(white: 0.5))
                        }
                    }
                    .padding(.top, 6)
                }

                // Bottom row: address + flags + time
                HStack(spacing: 0) {
                    // Address
                    Text(order.shortAddress)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Color(white: 0.4))

                    if order.randomize {
                        Text("RNG")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(Color(white: 0.5))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color(white: 0.15))
                            .cornerRadius(3)
                            .padding(.leading, 6)
                    }

                    if order.reduceOnly {
                        Text("RO")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(Color.orange.opacity(0.7))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.1))
                            .cornerRadius(3)
                            .padding(.leading, 4)
                    }

                    Spacer()

                    if !order.isActive {
                        // Show duration for ended orders
                        HStack(spacing: 4) {
                            Image(systemName: "clock")
                                .font(.system(size: 9))
                                .foregroundColor(Color(white: 0.4))
                            Text(order.formattedDuration)
                                .font(.system(size: 10))
                                .foregroundColor(Color(white: 0.45))
                        }
                        .padding(.trailing, 8)
                    }

                    // Time ago
                    Text(order.timeAgo)
                        .font(.system(size: 10))
                        .foregroundColor(Color(white: 0.35))
                }
                .padding(.top, 6)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(white: 0.09))
            .cornerRadius(10)
        }
    }
}
