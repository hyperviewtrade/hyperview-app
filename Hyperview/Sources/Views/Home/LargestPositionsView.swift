import SwiftUI

struct LargestPositionsView: View {
    @ObservedObject private var vm = LargestPositionsViewModel.shared
    @ObservedObject private var appState = AppState.shared
    @EnvironmentObject var chartVM: ChartViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Title removed — handled by WhalesContainerView tab picker

            // ── Content ──────────────────────────────────────────
            if vm.isLoading && vm.positions.isEmpty {
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
            } else if let error = vm.errorMsg, vm.positions.isEmpty {
                Spacer()
                errorView(error)
                Spacer()
            } else if vm.positions.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Text("No positions found")
                        .font(.system(size: 14))
                        .foregroundColor(Color(white: 0.5))
                }
                Spacer()
            } else {
                ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        Color.clear.frame(height: 0).id("whalesTop")
                        ForEach(Array(vm.positions.enumerated()), id: \.element.id) { index, position in
                            positionRow(position, rank: index + 1)
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
                    withAnimation { proxy.scrollTo("whalesTop", anchor: .top) }
                }
                }
            }
        }
        .background(Color.hlBackground.ignoresSafeArea())
        .task {
            await vm.load()
        }
    }

    // MARK: - Error View

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Text("Failed to load positions")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(Color(white: 0.5))
            Text(message)
                .font(.system(size: 12))
                .foregroundColor(Color(white: 0.4))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
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

    // MARK: - Position Row

    private func positionRow(_ position: LargestPosition, rank: Int) -> some View {
        NavigationLink {
            WalletDetailView(address: position.userAddress)
                .toolbar(.hidden, for: .tabBar)
        } label: {
            VStack(spacing: 0) {
                // Top row: rank + coin + badge + leverage
                HStack(spacing: 8) {
                    // Rank
                    Text("#\(rank)")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(white: 0.4))
                        .frame(width: 26, alignment: .leading)

                    // Coin icon
                    CoinIconView(symbol: position.coin, hlIconName: position.coin, iconSize: 22)

                    // Coin name (tappable to open chart)
                    Button {
                        let symbol: String
                        if let dex = position.dexName, !dex.isEmpty {
                            symbol = "\(dex):\(position.coin)"
                        } else {
                            symbol = position.coin
                        }
                        AppState.shared.openChart(
                            symbol: symbol,
                            displayName: position.coin,
                            perpEquivalent: nil,
                            chartVM: chartVM
                        )
                    } label: {
                        Text(position.coin)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white)
                    }

                    // LONG/SHORT badge
                    Text(position.isLong ? "LONG" : "SHORT")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(position.isLong ? Color.hlGreen.opacity(0.8) : Color.tradingRed)
                        .cornerRadius(4)

                    // Leverage
                    Text(position.leverage)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Color(white: 0.5))

                    if let dex = position.dexName, !dex.isEmpty {
                        Text(dex)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(Color.hlGreen.opacity(0.7))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.hlGreen.opacity(0.1))
                            .cornerRadius(3)
                    }

                    Spacer()

                    // Notional size
                    Text(position.formattedNotional)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                }

                // Bottom row: address + prices + PnL
                HStack(spacing: 0) {
                    // Address
                    Text(position.displayLabel)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Color(white: 0.4))

                    Spacer()

                    // Entry → Mark
                    Text("Entry \(position.formattedEntryPx)")
                        .font(.system(size: 10))
                        .foregroundColor(Color(white: 0.45))

                    Text("  |  ")
                        .font(.system(size: 10))
                        .foregroundColor(Color(white: 0.25))

                    Text("Mark \(position.formattedMarkPx)")
                        .font(.system(size: 10))
                        .foregroundColor(Color(white: 0.45))

                    Spacer()

                    // Unrealized PnL
                    Text(position.formattedPnl)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(position.unrealizedPnl >= 0 ? Color.hlGreen : Color.tradingRed)
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
