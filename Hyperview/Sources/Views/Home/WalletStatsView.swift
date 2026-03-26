import SwiftUI
import Combine

// MARK: - Model

struct WalletStat: Identifiable {
    var id: String { address }
    let address: String
    let shortAddress: String
    let positionCount: Int
    let openValue: Double
    let sumUpnl: Double
    let bias: String
    let biasRatio: Double
    let avgLeverage: Double
    let closestLiqPct: Double?
}

// MARK: - ViewModel

@MainActor
final class WalletStatsViewModel: ObservableObject {
    @Published var wallets: [WalletStat] = []
    @Published var totalCount: Int = 0
    @Published var isLoading = false
    @Published var errorMsg: String?

    private static let backendBase = "https://hyperview-backend-production-075c.up.railway.app"

    enum SortField: String {
        case upnl, openValue, leverage, liq, positions
    }

    func fetch(sortBy: SortField = .upnl, order: String = "desc",
               minUpnl: Double? = nil, maxUpnl: Double? = nil,
               minOpenValue: Double? = nil, maxOpenValue: Double? = nil) async {
        isLoading = true
        errorMsg = nil

        var comps = URLComponents(string: "\(Self.backendBase)/wallet-stats")!
        var items: [URLQueryItem] = [
            .init(name: "sortBy", value: sortBy.rawValue),
            .init(name: "order", value: order),
            .init(name: "limit", value: "1000"),
        ]
        if let v = minUpnl { items.append(.init(name: "minUpnl", value: String(v))) }
        if let v = maxUpnl { items.append(.init(name: "maxUpnl", value: String(v))) }
        if let v = minOpenValue { items.append(.init(name: "minOpenValue", value: String(v))) }
        if let v = maxOpenValue { items.append(.init(name: "maxOpenValue", value: String(v))) }
        comps.queryItems = items

        guard let url = comps.url else { isLoading = false; return }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            let (data, _) = try await URLSession.shared.data(for: request)

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let walletsArr = json["wallets"] as? [[String: Any]] else {
                errorMsg = "Invalid response"
                isLoading = false
                return
            }

            totalCount = json["count"] as? Int ?? walletsArr.count

            wallets = walletsArr.compactMap { d in
                guard let addr = d["address"] as? String else { return nil }
                return WalletStat(
                    address: addr,
                    shortAddress: d["shortAddress"] as? String ?? "\(addr.prefix(6))…\(addr.suffix(4))",
                    positionCount: d["positionCount"] as? Int ?? 0,
                    openValue: d["openValue"] as? Double ?? 0,
                    sumUpnl: d["sumUpnl"] as? Double ?? 0,
                    bias: d["bias"] as? String ?? "NEUTRAL",
                    biasRatio: d["biasRatio"] as? Double ?? 50,
                    avgLeverage: d["avgLeverage"] as? Double ?? 1,
                    closestLiqPct: d["closestLiqPct"] as? Double
                )
            }
        } catch {
            errorMsg = error.localizedDescription
        }

        isLoading = false
    }
}

// MARK: - View

struct WalletStatsView: View {
    let title: String
    let emoji: String
    let range: String
    let cohortCount: Int?
    let minUpnl: Double?
    let maxUpnl: Double?
    let minOpenValue: Double?
    let maxOpenValue: Double?

    @StateObject private var vm = WalletStatsViewModel()
    @State private var sortField: WalletStatsViewModel.SortField = .upnl
    @State private var sortDesc = true
    @State private var currentPage = 1

    private let pageSize = 50

    private var totalPages: Int {
        max(1, Int(ceil(Double(vm.wallets.count) / Double(pageSize))))
    }

    private var pagedWallets: [WalletStat] {
        let start = (currentPage - 1) * pageSize
        let end = min(start + pageSize, vm.wallets.count)
        guard start < vm.wallets.count else { return [] }
        return Array(vm.wallets[start..<end])
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 6) {
                Text(emoji)
                    .font(.system(size: 20))
                Text(title)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.white)
                Spacer()
                Text(range)
                    .font(.system(size: 12))
                    .foregroundColor(Color(white: 0.4))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Text("\(cohortCount ?? vm.totalCount) wallets — Page \(currentPage)/\(totalPages)")
                .font(.system(size: 12))
                .foregroundColor(Color(white: 0.45))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

            Divider().background(Color(white: 0.15))

            // Content
            if vm.isLoading && vm.wallets.isEmpty {
                Spacer()
                ProgressView().tint(.hlGreen)
                Spacer()
            } else if let err = vm.errorMsg, vm.wallets.isEmpty {
                Spacer()
                Text(err).font(.system(size: 12)).foregroundColor(.tradingRed)
                Spacer()
            } else {
                // Stats summary card — shown once wallets are loaded
                if !vm.wallets.isEmpty {
                    cohortStatsCard
                        .padding(.horizontal, 14)
                        .padding(.top, 12)
                        .padding(.bottom, 4)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    VStack(spacing: 0) {
                        // Column headers
                        HStack(spacing: 0) {
                            Text("Address")
                                .frame(width: 90, alignment: .leading)

                            sortableHeader("Open Value", field: .openValue, width: 80)
                            sortableHeader("UPNL", field: .upnl, width: 75)
                            Text("Bias")
                                .frame(width: 65, alignment: .center)
                            sortableHeader("Leverage", field: .leverage, width: 65)
                        }
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(Color(white: 0.4))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)

                        Divider().background(Color(white: 0.12))

                        // Rows
                        ScrollView(.vertical, showsIndicators: false) {
                            LazyVStack(spacing: 0) {
                                ForEach(pagedWallets) { wallet in
                                    NavigationLink {
                                        WalletDetailView(address: wallet.address)
                                            .toolbar(.hidden, for: .tabBar)
                                    } label: {
                                        walletRow(wallet)
                                    }
                                    .buttonStyle(.plain)

                                    Divider().background(Color(white: 0.08))
                                }
                            }
                        }
                    }
                }

                // Pagination bar
                if totalPages > 1 {
                    paginationBar
                }
            }
        }
        .background(Color.hlBackground.ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await vm.fetch(
                sortBy: sortField,
                order: sortDesc ? "desc" : "asc",
                minUpnl: minUpnl,
                maxUpnl: maxUpnl,
                minOpenValue: minOpenValue,
                maxOpenValue: maxOpenValue
            )
        }
    }

    // MARK: - Cohort Stats Card

    private var cohortStatsCard: some View {
        let wallets = vm.wallets
        let total = wallets.count
        guard total > 0 else { return AnyView(EmptyView()) }

        let longCount    = wallets.filter { $0.bias == "LONG" }.count
        let shortCount   = wallets.filter { $0.bias == "SHORT" }.count
        let neutralCount = total - longCount - shortCount
        let longPct      = Double(longCount)   / Double(total)
        let shortPct     = Double(shortCount)  / Double(total)
        let neutralPct   = Double(neutralCount) / Double(total)

        let inProfitCount = wallets.filter { $0.sumUpnl > 0 }.count
        let inProfitPct   = Double(inProfitCount) / Double(total) * 100
        let avgLev        = wallets.map(\.avgLeverage).reduce(0, +) / Double(total)
        let totalExposure = wallets.map(\.openValue).reduce(0, +)

        // Leverage buckets for mini bar chart
        let buckets: [(label: String, count: Int, color: Color)] = [
            ("1–2×",  wallets.filter { $0.avgLeverage < 2 }.count,                     Color(white: 0.55)),
            ("2–5×",  wallets.filter { $0.avgLeverage >= 2  && $0.avgLeverage < 5  }.count, Color.hlGreen.opacity(0.7)),
            ("5–10×", wallets.filter { $0.avgLeverage >= 5  && $0.avgLeverage < 10 }.count, Color.yellow.opacity(0.8)),
            ("10–20×",wallets.filter { $0.avgLeverage >= 10 && $0.avgLeverage < 20 }.count, Color.orange),
            ("20×+",  wallets.filter { $0.avgLeverage >= 20 }.count,                   Color.tradingRed),
        ]
        let maxBucket = Double(buckets.map(\.count).max() ?? 1)

        return AnyView(
            VStack(spacing: 14) {

                // ── Bias Distribution Bar ────────────────────────────────
                VStack(spacing: 7) {
                    HStack {
                        Text("BIAS DISTRIBUTION")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(Color(white: 0.4))
                            .tracking(1)
                        Spacer()
                    }

                    GeometryReader { geo in
                        HStack(spacing: 2) {
                            if longPct > 0 {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.hlGreen)
                                    .frame(width: max(geo.size.width * CGFloat(longPct) - 2, 0))
                            }
                            if neutralPct > 0 {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color(white: 0.35))
                                    .frame(width: max(geo.size.width * CGFloat(neutralPct) - 2, 0))
                            }
                            if shortPct > 0 {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.tradingRed)
                            }
                        }
                    }
                    .frame(height: 12)

                    HStack {
                        colorDotLabel(String(format: "%.0f%% Long", longPct * 100), color: .hlGreen, weight: .semibold)
                        Spacer()
                        colorDotLabel(String(format: "%.0f%% Neutral", neutralPct * 100), color: Color(white: 0.4), weight: .regular)
                        Spacer()
                        colorDotLabel(String(format: "%.0f%% Short", shortPct * 100), color: .tradingRed, weight: .semibold)
                    }
                }

                Divider().background(Color(white: 0.15))

                // ── Key Metrics Row ──────────────────────────────────────
                HStack(spacing: 0) {
                    cohortMetric(
                        label: "IN PROFIT",
                        value: String(format: "%.1f%%", inProfitPct),
                        color: inProfitPct >= 50 ? .hlGreen : .tradingRed
                    )
                    Rectangle().fill(Color(white: 0.15)).frame(width: 1, height: 40)
                    cohortMetric(
                        label: "AVG LEVERAGE",
                        value: String(format: "%.1f×", avgLev),
                        color: avgLev >= 10 ? .tradingRed : avgLev >= 5 ? .orange : .white
                    )
                    Rectangle().fill(Color(white: 0.15)).frame(width: 1, height: 40)
                    cohortMetric(
                        label: "TOTAL EXPOSURE",
                        value: formatCompact(totalExposure),
                        color: .white
                    )
                }

                Divider().background(Color(white: 0.15))

                // ── Leverage Distribution Mini Chart ─────────────────────
                VStack(spacing: 7) {
                    HStack {
                        Text("LEVERAGE DISTRIBUTION")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(Color(white: 0.4))
                            .tracking(1)
                        Spacer()
                    }

                    HStack(alignment: .bottom, spacing: 6) {
                        ForEach(buckets, id: \.label) { bucket in
                            VStack(spacing: 4) {
                                Text("\(bucket.count)")
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundColor(Color(white: 0.5))

                                RoundedRectangle(cornerRadius: 3)
                                    .fill(bucket.color)
                                    .frame(
                                        height: maxBucket > 0
                                            ? max(CGFloat(bucket.count) / CGFloat(maxBucket) * 52, bucket.count > 0 ? 4 : 0)
                                            : 0
                                    )

                                Text(bucket.label)
                                    .font(.system(size: 9))
                                    .foregroundColor(Color(white: 0.4))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .frame(height: 80)
                }
            }
            .padding(14)
            .background(Color(white: 0.09))
            .cornerRadius(12)
        )
    }

    private func cohortMetric(label: String, value: String, color: Color) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 17, weight: .bold, design: .monospaced))
                .foregroundColor(color)
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(Color(white: 0.4))
                .tracking(0.5)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Sortable Header

    private func sortableHeader(_ label: String, field: WalletStatsViewModel.SortField, width: CGFloat) -> some View {
        Button {
            if sortField == field {
                sortDesc.toggle()
            } else {
                sortField = field
                sortDesc = true
            }
            Task {
                await vm.fetch(
                    sortBy: sortField,
                    order: sortDesc ? "desc" : "asc",
                    minUpnl: minUpnl,
                    maxUpnl: maxUpnl,
                    minOpenValue: minOpenValue,
                    maxOpenValue: maxOpenValue
                )
            }
        } label: {
            HStack(spacing: 2) {
                Text(label)
                if sortField == field {
                    Image(systemName: sortDesc ? "chevron.down" : "chevron.up")
                        .font(.system(size: 6, weight: .bold))
                }
            }
            .frame(width: width, alignment: .trailing)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Wallet Row

    private func walletRow(_ w: WalletStat) -> some View {
        HStack(spacing: 0) {
            Text(w.shortAddress)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(.hlGreen)
                .frame(width: 90, alignment: .leading)

            Text(formatCompact(w.openValue))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.white)
                .frame(width: 80, alignment: .trailing)

            Text(formatPnl(w.sumUpnl))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(w.sumUpnl >= 0 ? .hlGreen : .tradingRed)
                .frame(width: 75, alignment: .trailing)

            HStack(spacing: 3) {
                Circle()
                    .fill(w.bias == "LONG" ? Color.hlGreen : w.bias == "SHORT" ? Color.tradingRed : Color.gray)
                    .frame(width: 6, height: 6)
                Text(w.bias == "LONG" ? "Long" : w.bias == "SHORT" ? "Short" : "Neutral")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(w.bias == "LONG" ? .hlGreen : w.bias == "SHORT" ? .tradingRed : .gray)
            }
            .frame(width: 65, alignment: .center)

            Text(String(format: "%.1f×", w.avgLeverage))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.white)
                .frame(width: 65, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Pagination Bar

    private var paginationBar: some View {
        HStack(spacing: 6) {
            // Previous
            Button {
                if currentPage > 1 { currentPage -= 1 }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(currentPage > 1 ? .hlGreen : Color(white: 0.25))
            }
            .disabled(currentPage <= 1)

            // Page buttons
            let pages = visiblePages()
            ForEach(pages, id: \.self) { page in
                if page == -1 {
                    Text("…")
                        .font(.system(size: 11))
                        .foregroundColor(Color(white: 0.3))
                        .frame(width: 24, height: 28)
                } else {
                    Button {
                        currentPage = page
                    } label: {
                        Text("\(page)")
                            .font(.system(size: 12, weight: page == currentPage ? .bold : .regular))
                            .foregroundColor(page == currentPage ? .black : .white)
                            .frame(width: 28, height: 28)
                            .background(page == currentPage ? Color.hlGreen : Color(white: 0.15))
                            .cornerRadius(6)
                    }
                }
            }

            // Next
            Button {
                if currentPage < totalPages { currentPage += 1 }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(currentPage < totalPages ? .hlGreen : Color(white: 0.25))
            }
            .disabled(currentPage >= totalPages)
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
    }

    /// Returns page numbers to show: [1, 2, ..., current-1, current, current+1, ..., last]
    private func visiblePages() -> [Int] {
        if totalPages <= 7 {
            return Array(1...totalPages)
        }
        var pages: [Int] = []
        pages.append(1)
        if currentPage > 3 { pages.append(-1) } // ellipsis
        for p in max(2, currentPage - 1)...min(totalPages - 1, currentPage + 1) {
            if !pages.contains(p) { pages.append(p) }
        }
        if currentPage < totalPages - 2 { pages.append(-1) } // ellipsis
        if !pages.contains(totalPages) { pages.append(totalPages) }
        return pages
    }

    // MARK: - Formatters

    private func formatCompact(_ v: Double) -> String {
        if abs(v) >= 1_000_000_000 { return String(format: "$%.2fB", v / 1_000_000_000) }
        if abs(v) >= 1_000_000 { return String(format: "$%.1fM", v / 1_000_000) }
        if abs(v) >= 1_000 { return String(format: "$%.1fK", v / 1_000) }
        return String(format: "$%.0f", v)
    }

    private func formatPnl(_ v: Double) -> String {
        let sign = v >= 0 ? "+" : ""
        if abs(v) >= 1_000_000 { return String(format: "%@$%.1fM", sign, v / 1_000_000) }
        if abs(v) >= 1_000 { return String(format: "%@$%.1fK", sign, v / 1_000) }
        return String(format: "%@$%.0f", sign, v)
    }
}

// MARK: - ColorDotLabelStyle

@ViewBuilder
private func colorDotLabel(_ text: String, color: Color, weight: Font.Weight = .regular) -> some View {
    HStack(spacing: 5) {
        Circle().fill(color).frame(width: 7, height: 7)
        Text(text)
            .font(.system(size: 11, weight: weight))
            .foregroundColor(weight == .regular ? Color(white: 0.5) : color)
    }
}
