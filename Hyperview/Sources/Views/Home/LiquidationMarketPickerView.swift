import SwiftUI

struct LiquidationMarketPickerView: View {
    @ObservedObject var vm: LiquidationsViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
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
                .padding(.vertical, 8)

                // Selected coins chips (if any)
                if !vm.selectedCoins.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(Array(vm.selectedCoins).sorted(), id: \.self) { coin in
                                HStack(spacing: 4) {
                                    CoinIconView(symbol: iconName(for: coin), hlIconName: coin, iconSize: 16)
                                    Text(coin)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(.white)
                                    Button {
                                        vm.toggleCoin(coin)
                                    } label: {
                                        Image(systemName: "xmark")
                                            .font(.system(size: 8, weight: .bold))
                                            .foregroundColor(Color(white: 0.5))
                                    }
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(Color.hlGreen.opacity(0.15))
                                .cornerRadius(14)
                            }
                        }
                        .padding(.horizontal, 14)
                    }
                    .padding(.bottom, 6)
                }

                // Market list
                ScrollView {
                    LazyVStack(spacing: 0) {
                        // "All" option
                        Button {
                            vm.selectAllMarkets()
                        } label: {
                            HStack(spacing: 10) {
                                ZStack {
                                    Circle().fill(Color(white: 0.2))
                                    Image(systemName: "globe")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundColor(.white)
                                }
                                .frame(width: 28, height: 28)

                                Text("All Markets")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(.white)

                                Spacer()

                                if vm.selectedCoins.isEmpty {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 18))
                                        .foregroundColor(.hlGreen)
                                } else {
                                    Circle()
                                        .stroke(Color(white: 0.3), lineWidth: 1.5)
                                        .frame(width: 18, height: 18)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                        }
                        Divider().background(Color(white: 0.12)).padding(.leading, 54)

                        // Coin list — multi-select
                        ForEach(filteredMarkets, id: \.self) { coin in
                            Button {
                                vm.toggleCoin(coin)
                            } label: {
                                HStack(spacing: 10) {
                                    CoinIconView(
                                        symbol: iconName(for: coin),
                                        hlIconName: coin,
                                        iconSize: 28
                                    )

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

                                    if vm.selectedCoins.contains(coin) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.system(size: 18))
                                            .foregroundColor(.hlGreen)
                                    } else {
                                        Circle()
                                            .stroke(Color(white: 0.3), lineWidth: 1.5)
                                            .frame(width: 18, height: 18)
                                    }
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                            }
                            Divider().background(Color(white: 0.12)).padding(.leading, 54)
                        }
                    }
                }
            }
            .background(Color(white: 0.06))
            .keyboardDoneBar()
            .navigationTitle("Markets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundColor(.hlGreen)
                }
            }
        }
    }

    private var filteredMarkets: [String] {
        let markets = vm.allPerps
        if searchText.isEmpty { return markets }
        return markets.filter { $0.localizedCaseInsensitiveContains(searchText) }
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
