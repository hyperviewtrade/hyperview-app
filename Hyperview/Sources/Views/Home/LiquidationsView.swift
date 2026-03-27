import SwiftUI

struct LiquidationsView: View {
    @ObservedObject private var vm = LiquidationsViewModel.shared
    @State private var showFilters = true
    @ObservedObject private var appState = AppState.shared

    @FocusState private var maxSizeFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // ── Filter bar ─────────────────────────────────────
            filterBar
                .padding(.horizontal, 14)
                .padding(.vertical, 8)

            // ── List ────────────────────────────────────────────
            if vm.liquidations.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Text("💥")
                        .font(.system(size: 40))
                    Text("No liquidations yet")
                        .font(.system(size: 14))
                        .foregroundColor(Color(white: 0.5))
                    Text("Tracking in real-time…")
                        .font(.system(size: 12))
                        .foregroundColor(Color(white: 0.35))
                }
                Spacer()
            } else {
                ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        Color.clear.frame(height: 0).id("liqTop")
                        ForEach(vm.liquidations) { liq in
                            NavigationLink {
                                WalletDetailView(address: liq.address)
                                    .toolbar(.hidden, for: .tabBar)
                            } label: {
                                liquidationRow(liq)
                            }
                            .padding(.horizontal, 14)
                            // Auto-load more when approaching the bottom (infinite scroll)
                            .onAppear {
                                if liq.id == vm.liquidations.last?.id, vm.hasMore, !vm.isLoadingMore {
                                    Task { await vm.loadMore() }
                                }
                            }
                        }

                        // Load More indicator / manual button
                        if vm.hasMore {
                            if vm.isLoadingMore {
                                HStack {
                                    Spacer()
                                    ProgressView().tint(.white)
                                    Text("Loading…")
                                        .font(.system(size: 12))
                                        .foregroundColor(Color(white: 0.4))
                                    Spacer()
                                }
                                .padding(.vertical, 12)
                            } else {
                                Button {
                                    Task { await vm.loadMore() }
                                } label: {
                                    HStack {
                                        Spacer()
                                        Text("Load More (\(vm.liquidations.count) of \(vm.totalFiltered))")
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundColor(.hlGreen)
                                        Spacer()
                                    }
                                    .padding(.vertical, 12)
                                    .background(Color(white: 0.09))
                                    .cornerRadius(10)
                                    .padding(.horizontal, 14)
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        // Bottom status
                        if !vm.hasMore && vm.liquidations.count > 0 {
                            Text("\(vm.liquidations.count) liquidations loaded")
                                .font(.system(size: 11))
                                .foregroundColor(Color(white: 0.3))
                                .padding(.vertical, 8)
                        }
                    }
                    .padding(.top, 4)
                    .padding(.bottom, 20)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: appState.homeReselect) { _, _ in
                    withAnimation { proxy.scrollTo("liqTop", anchor: .top) }
                }
                }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    maxSizeFieldFocused = false
                }
                .fontWeight(.semibold)
                .foregroundColor(.hlGreen)
            }
        }
        .sheet(isPresented: $vm.showNotificationSettings) {
            LiquidationNotificationSettingsView(vm: vm)
        }
        .sheet(isPresented: $vm.showMarketPicker) {
            LiquidationMarketPickerView(vm: vm)
        }
        .onAppear {
            vm.startPolling()
        }
        .onDisappear {
            vm.stopPolling()
        }
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                // Market picker
                Button { vm.showMarketPicker = true } label: {
                    HStack(spacing: 6) {
                        if vm.selectedCoins.count == 1, let coin = vm.selectedCoins.first {
                            CoinIconView(symbol: coin.components(separatedBy: ":").last ?? coin,
                                         hlIconName: coin,
                                         iconSize: 18)
                        }
                        Text(vm.selectedCoinsLabel)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(vm.selectedCoins.isEmpty ? .white : .hlGreen)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(Color(white: 0.5))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(white: 0.13))
                    .cornerRadius(8)
                }

                // Side filter
                Menu {
                    Button("All") { vm.selectedSide = "All"; Task { await vm.fetch() } }
                    Button("Long") { vm.selectedSide = "Long"; Task { await vm.fetch() } }
                    Button("Short") { vm.selectedSide = "Short"; Task { await vm.fetch() } }
                } label: {
                    HStack(spacing: 4) {
                        Text(vm.selectedSide == "All" ? "Side" : vm.selectedSide)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(vm.selectedSide == "All" ? .white : (vm.selectedSide == "Long" ? .tradingRed : .hlGreen))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(Color(white: 0.5))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(white: 0.13))
                    .cornerRadius(8)
                }

                // Size filters toggle
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showFilters.toggle()
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(hasActiveFilters ? .hlGreen : .white)
                        .padding(8)
                        .background(Color(white: 0.13))
                        .cornerRadius(8)
                }

                Spacer()

                // Notification settings
                Button {
                    vm.showNotificationSettings = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: vm.notificationRules.isEmpty ? "bell" : "bell.fill")
                            .font(.system(size: 13, weight: .semibold))
                        if !vm.notificationRules.isEmpty {
                            Text("\(vm.notificationRules.count)")
                                .font(.system(size: 10, weight: .bold))
                        }
                    }
                    .foregroundColor(vm.notificationRules.isEmpty ? Color(white: 0.5) : .hlGreen)
                    .padding(8)
                    .background(Color(white: 0.13))
                    .cornerRadius(8)
                }
            }

            // Size filter (collapsible)
            if showFilters {
                HStack(spacing: 8) {
                    // Min size is server-enforced — show as label
                    Text(">= $1,000")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Color(white: 0.45))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Color(white: 0.09))
                        .cornerRadius(8)

                    sizeField("Max $", text: $vm.maxSize)
                        .focused($maxSizeFieldFocused)

                    Button("Apply") {
                        maxSizeFieldFocused = false
                        Task { await vm.fetch() }
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.black)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.hlGreen)
                    .cornerRadius(8)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var hasActiveFilters: Bool {
        !vm.maxSize.isEmpty
    }

    private func sizeField(_ placeholder: String, text: Binding<String>) -> some View {
        ZStack(alignment: .trailing) {
            TextField(placeholder, text: text)
                .font(.system(size: 13))
                .foregroundColor(.white)
                .keyboardType(.numberPad)
                .padding(.horizontal, 10)
                .padding(.trailing, text.wrappedValue.isEmpty ? 10 : 28)
                .padding(.vertical, 8)
                .background(Color(white: 0.11))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(white: 0.2), lineWidth: 1)
                )
                .onChange(of: text.wrappedValue) { _, newValue in
                    let formatted = formatIntegerWithCommas(newValue)
                    if formatted != newValue { text.wrappedValue = formatted }
                }

            if !text.wrappedValue.isEmpty {
                Button {
                    text.wrappedValue = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(Color(white: 0.4))
                }
                .padding(.trailing, 8)
            }
        }
    }

    // MARK: - Liquidation Row

    private func liquidationRow(_ liq: LiquidationItem) -> some View {
        VStack(spacing: 0) {
            // Top row: coin + side + leverage + size
            HStack(spacing: 10) {
                // Side indicator
                Circle()
                    .fill(liq.isLong ? Color.tradingRed : Color.hlGreen)
                    .frame(width: 8, height: 8)

                // Coin icon
                CoinIconView(symbol: liq.coin, hlIconName: liq.coin, iconSize: 22)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(liq.coin)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white)
                        Text(liq.side)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(liq.isLong ? .tradingRed : .hlGreen)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background((liq.isLong ? Color.tradingRed : Color.hlGreen).opacity(0.15))
                            .cornerRadius(4)
                        if let lev = liq.leverage, lev > 1 {
                            Text("\(lev)x")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(Color(white: 0.5))
                        }
                    }
                    Text(liq.shortAddress)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Color(white: 0.4))
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(liq.formattedSize)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.tradingRed)
                    Text(liq.relativeTime)
                        .font(.system(size: 10))
                        .foregroundColor(Color(white: 0.4))
                }
            }

            // Bottom row: entry price → liq price
            if liq.price > 0 {
                HStack(spacing: 0) {
                    if let entry = liq.formattedEntryPrice {
                        Text("Entry ")
                            .font(.system(size: 10))
                            .foregroundColor(Color(white: 0.35))
                        Text(entry)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(Color(white: 0.5))

                        Text("  →  ")
                            .font(.system(size: 10))
                            .foregroundColor(Color(white: 0.25))
                    }

                    Text("Liq ")
                        .font(.system(size: 10))
                        .foregroundColor(Color(white: 0.35))
                    Text(liq.formattedPrice)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.tradingRed)

                    Spacer()
                }
                .padding(.top, 5)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(white: 0.09))
        .cornerRadius(10)
    }
}
