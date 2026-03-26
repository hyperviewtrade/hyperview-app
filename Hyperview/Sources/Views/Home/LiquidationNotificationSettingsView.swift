import SwiftUI

struct LiquidationNotificationSettingsView: View {
    @ObservedObject var vm: LiquidationsViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var searchText = ""
    @State private var selectedMarket: String?
    @State private var minSizeInput = ""
    @State private var selectedDirection: LiqDirection = .both
    @FocusState private var isSearchFocused: Bool
    @FocusState private var isAmountFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // ── Active rules (scrollable, capped height) ─
                if !vm.notificationRules.isEmpty && selectedMarket == nil {
                    ScrollView {
                        activeRulesSection
                    }
                    .frame(maxHeight: 220)
                }

                Divider().background(Color(white: 0.2))

                // ── Add new rule ──────────────────────────────
                if let market = selectedMarket {
                    minSizeInputSection(market: market)
                } else {
                    marketSearchSection
                }
            }
            .background(Color(white: 0.06))
            .navigationTitle("Notifications")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundColor(.hlGreen)
                }
            }
        }
    }

    // MARK: - Active Rules

    private var activeRulesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ACTIVE ALERTS")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(Color(white: 0.4))
                .padding(.horizontal, 16)
                .padding(.top, 14)

            ForEach(vm.notificationRules) { rule in
                HStack(spacing: 10) {
                    CoinIconView(symbol: iconName(for: rule.coin), hlIconName: rule.coin, iconSize: 22)

                    Text(rule.coin)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)

                    Text("≥ \(rule.formattedMinSize)")
                        .font(.system(size: 13))
                        .foregroundColor(Color(white: 0.5))

                    Text(rule.direction.label)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(rule.direction == .long ? .hlGreen : (rule.direction == .short ? .tradingRed : .white))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background((rule.direction == .long ? Color.hlGreen : (rule.direction == .short ? Color.tradingRed : Color.white)).opacity(0.15))
                        .cornerRadius(4)

                    Spacer()

                    Button {
                        withAnimation { vm.removeRule(rule) }
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 13))
                            .foregroundColor(.tradingRed)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color(white: 0.1))
                .cornerRadius(10)
                .padding(.horizontal, 14)
            }

            Spacer().frame(height: 10)
        }
    }

    // MARK: - Market Search

    private var marketSearchSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ADD ALERT")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(Color(white: 0.4))
                .padding(.horizontal, 16)
                .padding(.top, 14)

            // Search bar
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14))
                    .foregroundColor(Color(white: 0.4))
                TextField("Search market…", text: $searchText)
                    .font(.system(size: 14))
                    .foregroundColor(.white)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.characters)
                    .focused($isSearchFocused)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                        isSearchFocused = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundColor(Color(white: 0.4))
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(white: 0.11))
            .cornerRadius(10)
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded { isSearchFocused = true })
            .padding(.horizontal, 14)

            // Market list (sorted by volume)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filteredMarkets, id: \.self) { coin in
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                selectedMarket = coin
                                minSizeInput = ""
                            }
                        } label: {
                            HStack(spacing: 10) {
                                CoinIconView(symbol: iconName(for: coin), hlIconName: coin, iconSize: 28)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(coin)
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundColor(.white)
                                    if let vol = vm.perpVolumes[coin], vol > 0 {
                                        Text("Vol: \(formatVolume(vol))")
                                            .font(.system(size: 11))
                                            .foregroundColor(Color(white: 0.4))
                                    }
                                }

                                Spacer()

                                if hasRuleForCoin(coin) {
                                    Image(systemName: "bell.fill")
                                        .font(.system(size: 11))
                                        .foregroundColor(.hlGreen)
                                }
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(Color(white: 0.3))
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                        }
                        Divider().background(Color(white: 0.12)).padding(.leading, 54)
                    }
                }
            }
        }
    }

    // MARK: - Min Size Input

    private func minSizeInputSection(market: String) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 16) {
                    Spacer().frame(height: 40)

                    CoinIconView(symbol: iconName(for: market), hlIconName: market, iconSize: 48)

                    Text(market)
                        .font(.system(size: 28, weight: .bold))
                        .foregroundColor(.white)

                    Text("Minimum liquidation size to notify")
                        .font(.system(size: 14))
                        .foregroundColor(Color(white: 0.5))

                    // Amount input
                    HStack(spacing: 4) {
                        Text("$")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundColor(.white)
                        TextField("50,000", text: $minSizeInput)
                            .font(.system(size: 22, weight: .bold))
                            .foregroundColor(.white)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.center)
                            .focused($isAmountFocused)
                            .onChange(of: minSizeInput) { _, newValue in
                                let formatted = formatIntegerWithCommas(newValue)
                                if formatted != newValue { minSizeInput = formatted }
                            }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                    .background(Color(white: 0.11))
                    .cornerRadius(12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color(white: 0.2), lineWidth: 1)
                    )
                    .padding(.horizontal, 40)
                    .id("amountField")

                    // Quick select buttons
                    HStack(spacing: 8) {
                        quickAmountButton("$50K", value: 50_000)
                        quickAmountButton("$100K", value: 100_000)
                        quickAmountButton("$300K", value: 300_000)
                        quickAmountButton("$500K", value: 500_000)
                        quickAmountButton("$1M", value: 1_000_000)
                    }
                    .id("quickButtons")

                    // Direction picker
                    VStack(spacing: 6) {
                        Text("Direction")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Color(white: 0.5))

                        HStack(spacing: 0) {
                            ForEach(LiqDirection.allCases, id: \.self) { dir in
                                Button {
                                    selectedDirection = dir
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: dir.icon)
                                            .font(.system(size: 11))
                                        Text(dir.label)
                                            .font(.system(size: 13, weight: .semibold))
                                    }
                                    .foregroundColor(selectedDirection == dir ? .black : Color(white: 0.5))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 9)
                                    .background(selectedDirection == dir ? Color.hlGreen : Color.clear)
                                    .cornerRadius(8)
                                }
                            }
                        }
                        .background(Color(white: 0.11))
                        .cornerRadius(8)
                    }
                    .padding(.horizontal, 40)

                    // Confirm button
                    Button {
                        if let size = Double(stripCommas(minSizeInput)), size > 0 {
                            vm.addRule(coin: market, minSize: size, direction: selectedDirection)
                            withAnimation(.easeInOut(duration: 0.2)) {
                                selectedMarket = nil
                                searchText = ""
                                selectedDirection = .both
                            }
                        }
                    } label: {
                        Text("Add Alert")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.hlGreen)
                            .cornerRadius(12)
                    }
                    .padding(.horizontal, 40)
                    .opacity(isValidAmount ? 1 : 0.4)
                    .disabled(!isValidAmount)

                    // Back button
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            selectedMarket = nil
                        }
                    } label: {
                        Text("Back to markets")
                            .font(.system(size: 13))
                            .foregroundColor(Color(white: 0.5))
                    }

                    Spacer().frame(height: 40)
                }
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if isAmountFocused {
                    HStack {
                        Spacer()
                        Button("Done") {
                            isAmountFocused = false
                        }
                        .fontWeight(.semibold)
                        .foregroundColor(.hlGreen)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color(white: 0.12))
                }
            }
            .onChange(of: isAmountFocused) { _, focused in
                if focused {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        proxy.scrollTo("quickButtons", anchor: .bottom)
                    }
                }
            }
        }
    }

    private func quickAmountButton(_ label: String, value: Double) -> some View {
        Button {
            minSizeInput = formatIntegerWithCommas(String(format: "%.0f", value))
        } label: {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color(white: 0.13))
                .cornerRadius(8)
        }
    }

    // MARK: - Helpers

    private var filteredMarkets: [String] {
        let markets = vm.allPerps.isEmpty ? vm.availableCoins.filter { $0 != "All" } : vm.allPerps
        if searchText.isEmpty { return markets }
        return markets.filter { $0.localizedCaseInsensitiveContains(searchText) }
    }

    private func hasRuleForCoin(_ coin: String) -> Bool {
        vm.notificationRules.contains { $0.coin == coin }
    }

    private var isValidAmount: Bool {
        guard let v = Double(stripCommas(minSizeInput)) else { return false }
        return v > 0
    }

    /// Extract icon name: "dexName:COIN" → "COIN", plain "BTC" → "BTC"
    private func iconName(for coin: String) -> String {
        coin.components(separatedBy: ":").last ?? coin
    }

    private func formatVolume(_ v: Double) -> String {
        if v >= 1_000_000_000 { return String(format: "$%.1fB", v / 1_000_000_000) }
        if v >= 1_000_000     { return String(format: "$%.1fM", v / 1_000_000) }
        if v >= 1_000         { return String(format: "$%.0fK", v / 1_000) }
        return String(format: "$%.0f", v)
    }

}
