import SwiftUI

struct UnstakingView: View {
    @StateObject private var vm = UnstakingViewModel()
    @State private var tab: UnstakingTab = .queue
    @Namespace private var tabIndicator

    enum UnstakingTab: String, CaseIterable {
        case queue    = "Unstaking Queue"
        case upcoming = "Upcoming"
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider().background(Color.hlSurface)
            tabContent
        }
        .background(Color.hlBackground.ignoresSafeArea())
        .navigationTitle("Unstaking")
        .navigationBarTitleDisplayMode(.inline)
        .keyboardDoneBar()
        .task { await vm.loadAll() }
    }

    // MARK: - Tab bar

    private var tabBar: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(UnstakingTab.allCases, id: \.self) { t in
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) { tab = t }
                        } label: {
                            VStack(spacing: 4) {
                                Text(t.rawValue)
                                    .font(.system(size: 13, weight: tab == t ? .semibold : .regular))
                                    .foregroundColor(tab == t ? .white : Color(white: 0.5))
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 10)
                                if tab == t {
                                    Rectangle()
                                        .fill(Color.hlGreen)
                                        .frame(height: 2)
                                        .matchedGeometryEffect(id: "unstakingTabIndicator", in: tabIndicator)
                                } else {
                                    Rectangle()
                                        .fill(Color.clear)
                                        .frame(height: 2)
                                }
                            }
                        }
                        .id(t)
                    }
                }
            }
            .onChange(of: tab) { _, newTab in
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(newTab, anchor: .center)
                }
            }
        }
        .background(Color.hlBackground)
    }

    // MARK: - Tab content

    @ViewBuilder
    private var tabContent: some View {
        switch tab {
        case .queue:    queueTab
        case .upcoming: upcomingTab
        }
    }

    // MARK: - Queue Tab

    private var queueTab: some View {
        ScrollView {
            VStack(spacing: 16) {
                if vm.isLoading && vm.queueEntries.isEmpty {
                    ProgressView().tint(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                } else {
                    // Stats grid
                    statsSection

                    // Bar chart
                    UnstakingBarChart(bars: vm.dailyBars)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 20)
        }
        .refreshable { await vm.refresh() }
    }

    // MARK: - Stats section

    private var statsSection: some View {
        VStack(spacing: 12) {
            // Finishing in...
            VStack(alignment: .leading, spacing: 8) {
                Text("Finishing in")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color(white: 0.5))

                HStack(spacing: 8) {
                    statCell(label: "1h", value: formatHYPE(vm.unstakingNext1h), color: .orange)
                    statCell(label: "24h", value: formatHYPE(vm.unstakingNext24h), color: .orange)
                    statCell(label: "7d", value: formatHYPE(vm.unstakingNext7d), color: .orange)
                }
            }

            // Finished in past...
            VStack(alignment: .leading, spacing: 8) {
                Text("Finished in past")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color(white: 0.5))

                HStack(spacing: 8) {
                    statCell(label: "1h", value: formatHYPE(vm.finishedPast1h), color: .hlGreen)
                    statCell(label: "24h", value: formatHYPE(vm.finishedPast24h), color: .hlGreen)
                    statCell(label: "7d", value: formatHYPE(vm.finishedPast7d), color: .hlGreen)
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(white: 0.09))
        )
    }

    private func statCell(label: String, value: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Color(white: 0.45))
            Text(value)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color(white: 0.07))
        .cornerRadius(8)
    }

    // MARK: - Upcoming Tab

    private var upcomingTab: some View {
        VStack(spacing: 0) {
            // Filter / sort bar
            filterBar

            if vm.isLoading && vm.upcomingFiltered.isEmpty {
                Spacer()
                ProgressView().tint(.white)
                Spacer()
            } else if vm.upcomingFiltered.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "clock.fill")
                        .font(.system(size: 36))
                        .foregroundColor(Color(white: 0.25))
                    Text("No upcoming unstaking")
                        .font(.system(size: 14))
                        .foregroundColor(Color(white: 0.4))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Table header
                tableHeader

                // List
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(vm.upcomingFiltered) { entry in
                            unstakingRow(entry)
                        }
                    }
                    .padding(.bottom, 20)
                }
                .refreshable { await vm.refresh() }
            }
        }
    }

    // MARK: - Filter bar

    private var filterBar: some View {
        HStack(spacing: 10) {
            // Min amount
            HStack(spacing: 4) {
                Text("Min")
                    .font(.system(size: 11))
                    .foregroundColor(Color(white: 0.4))
                    .fixedSize()
                TextField("0", text: $vm.minAmountFilter)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.white)
                    .keyboardType(.numberPad)
                    .lineLimit(1)
                    .onChange(of: vm.minAmountFilter) { _, newValue in
                        let formatted = formatIntegerWithCommas(newValue)
                        if formatted != newValue { vm.minAmountFilter = formatted }
                    }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color(white: 0.1))
            .cornerRadius(6)
            .frame(maxWidth: .infinity)

            // Max amount
            HStack(spacing: 4) {
                Text("Max")
                    .font(.system(size: 11))
                    .foregroundColor(Color(white: 0.4))
                    .fixedSize()
                TextField("∞", text: $vm.maxAmountFilter)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.white)
                    .keyboardType(.numberPad)
                    .lineLimit(1)
                    .onChange(of: vm.maxAmountFilter) { _, newValue in
                        let formatted = formatIntegerWithCommas(newValue)
                        if formatted != newValue { vm.maxAmountFilter = formatted }
                    }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color(white: 0.1))
            .cornerRadius(6)
            .frame(maxWidth: .infinity)

            Spacer()

            Button {
                vm.applySortAndFilter()
            } label: {
                Text("Apply")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.black)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.hlGreen)
                    .cornerRadius(6)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Table header

    private var tableHeader: some View {
        HStack(spacing: 0) {
            // Time sort
            Button { vm.toggleSort(field: .time) } label: {
                HStack(spacing: 3) {
                    Text("Time")
                        .font(.system(size: 11, weight: .semibold))
                    if vm.sortField == .time {
                        Image(systemName: vm.sortDirection == .asc ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                    }
                }
                .foregroundColor(vm.sortField == .time ? .hlGreen : Color(white: 0.5))
            }
            .frame(width: 90, alignment: .leading)

            Text("Address")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Color(white: 0.5))
                .frame(maxWidth: .infinity, alignment: .leading)

            // Amount sort
            Button { vm.toggleSort(field: .amount) } label: {
                HStack(spacing: 3) {
                    Text("Amount")
                        .font(.system(size: 11, weight: .semibold))
                    if vm.sortField == .amount {
                        Image(systemName: vm.sortDirection == .asc ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                    }
                }
                .foregroundColor(vm.sortField == .amount ? .hlGreen : Color(white: 0.5))
            }
            .frame(width: 90, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(white: 0.06))
    }

    // MARK: - Unstaking row

    private func unstakingRow(_ entry: UnstakingQueueEntry) -> some View {
        HStack(spacing: 0) {
            // Countdown
            Text(countdown(to: entry.time))
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.orange)
                .frame(width: 90, alignment: .leading)

            // Address (tappable → WalletDetailView)
            NavigationLink {
                WalletDetailView(address: entry.userAddress)
                    .toolbar(.hidden, for: .tabBar)
            } label: {
                Text(shortAddr(entry.userAddress))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.hlGreen)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Amount
            Text(formatHYPEShort(entry.amountHYPE))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(.white)
                .frame(width: 90, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - Helpers

    private func countdown(to date: Date) -> String {
        let diff = date.timeIntervalSince(Date())
        if diff <= 0 { return "Done" }
        let h = Int(diff) / 3600
        let m = (Int(diff) % 3600) / 60
        if h > 24 {
            let d = h / 24
            return "\(d)d \(h % 24)h"
        }
        return "\(h)h \(m)m"
    }

    private func shortAddr(_ addr: String) -> String {
        guard addr.count > 10 else { return addr }
        return "\(addr.prefix(6))...\(addr.suffix(4))"
    }

    private func formatHYPE(_ value: Double) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", value / 1_000_000) }
        if value >= 1_000     { return String(format: "%.0fK", value / 1_000) }
        return String(format: "%.0f", value)
    }

    private func formatHYPEShort(_ value: Double) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", value / 1_000_000) }
        if value >= 1_000     { return String(format: "%.1fK", value / 1_000) }
        return String(format: "%.1f", value)
    }
}
