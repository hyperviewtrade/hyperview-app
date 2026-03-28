import SwiftUI

struct HomeRelativePerformanceCard: View {
    @StateObject private var vm = RelativePerformanceViewModel.shared

    private let timeframes = RelativePerformanceViewModel.Timeframe.allCases

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            Text("$HYPE Relative Performance")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.white)

            // Content
            if vm.isLoading && vm.rows.isEmpty {
                HStack {
                    Spacer()
                    ProgressView().tint(.hlGreen)
                        .padding(.vertical, 30)
                    Spacer()
                }
            } else if vm.rows.isEmpty {
                HStack {
                    Spacer()
                    Text("No data available")
                        .font(.system(size: 12))
                        .foregroundColor(Color(white: 0.4))
                        .padding(.vertical, 20)
                    Spacer()
                }
            } else {
                // Column headers: PAIR | 7D | 30D | 60D | 1Y (tappable for sort)
                HStack(spacing: 0) {
                    Text("PAIR")
                        .frame(width: 90, alignment: .leading)
                        .foregroundColor(Color(white: 0.45))
                    ForEach(timeframes, id: \.self) { tf in
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                vm.toggleSort(tf)
                            }
                        } label: {
                            HStack(spacing: 2) {
                                Text(tf.rawValue)
                                if vm.sortTF == tf {
                                    Image(systemName: vm.sortAscending ? "chevron.up" : "chevron.down")
                                        .font(.system(size: 7, weight: .bold))
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .foregroundColor(vm.sortTF == tf ? .hlGreen : Color(white: 0.45))
                        }
                    }
                }
                .font(.system(size: 10, weight: .semibold))

                // Rows
                VStack(spacing: 0) {
                    ForEach(Array(vm.rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 {
                            Divider().background(Color(white: 0.15))
                        }
                        perfRow(row)
                    }
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(white: 0.11))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color(white: 0.18), lineWidth: 1)
                )
        )
        .task {
            // Cache loads instantly in init — only fetch if stale or empty
            await vm.load()
        }
    }

    // MARK: - Row

    private func perfRow(_ row: RelativePerformanceViewModel.CoinRow) -> some View {
        HStack(spacing: 0) {
            // HYPE/COIN pair with icon
            HStack(spacing: 5) {
                CoinIconView(symbol: row.symbol, hlIconName: row.symbol, iconSize: 16)
                Text("HYPE/\(row.symbol)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(width: 90, alignment: .leading)

            // Values for each timeframe
            ForEach(timeframes, id: \.self) { tf in
                if let rel = row.relativeByTF[tf] {
                    Text(formatPct(rel))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(rel >= 0 ? .hlGreen : .tradingRed)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                } else {
                    Text("—")
                        .font(.system(size: 11))
                        .foregroundColor(Color(white: 0.3))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
        .padding(.vertical, 7)
    }

    // MARK: - Formatting

    private func formatPct(_ value: Double) -> String {
        let pct = value * 100
        let sign = pct >= 0 ? "+" : ""
        return "\(sign)\(String(format: "%.2f", pct))%"
    }
}
