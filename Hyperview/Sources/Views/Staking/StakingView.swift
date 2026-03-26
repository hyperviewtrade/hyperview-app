import SwiftUI

struct StakingView: View {
    @StateObject private var vm = StakingViewModel()
    @ObservedObject private var wallet = WalletManager.shared
    @State private var tab: StakingTab = .validators
    @Namespace private var tabIndicator

    enum StakingTab: String, CaseIterable {
        case validators = "Validators"
        case rewards    = "Rewards"
        case actions    = "Actions"
    }

    private var address: String {
        wallet.connectedWallet?.address ?? ""
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── Tab bar ──────────────────────────────────────
            tabBar
            Divider().background(Color.hlSurface)

            // ── Content ──────────────────────────────────────
            tabContent
        }
        .background(Color.hlBackground.ignoresSafeArea())
        .navigationTitle("Staking")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard !address.isEmpty else { return }
            await vm.loadAll(address: address)
        }
    }

    // MARK: - Tab bar

    private var tabBar: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(StakingTab.allCases, id: \.self) { t in
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
                                        .matchedGeometryEffect(id: "stakingTabIndicator", in: tabIndicator)
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
        case .validators: validatorsTab
        case .rewards:    rewardsTab
        case .actions:    actionsTab
        }
    }

    // MARK: - Validators Tab

    private var validatorsTab: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Summary card
                summaryCard

                // Loading
                if vm.isLoading && vm.validators.isEmpty {
                    ProgressView().tint(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                } else if vm.validators.isEmpty {
                    emptyState(icon: "person.3.fill", message: "No validators found")
                } else {
                    // Validator list
                    LazyVStack(spacing: 8) {
                        ForEach(vm.validators) { validator in
                            if wallet.isLocalWallet {
                                NavigationLink {
                                    StakeActionView(
                                        validator: validator,
                                        walletAddress: address
                                    )
                                    .environmentObject(vm)
                                } label: {
                                    validatorRow(validator)
                                }
                            } else {
                                validatorRow(validator)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 20)
        }
        .refreshable {
            await vm.refresh(address: address)
        }
    }

    // MARK: - Summary card

    private var summaryCard: some View {
        VStack(spacing: 1) {
            stakingStat(label: "Delegated", value: String(format: "%.2f HYPE", vm.delegated),
                        color: .hlGreen)
            stakingStat(label: "Undelegated", value: String(format: "%.2f HYPE", vm.undelegated),
                        color: .white)
            stakingStat(label: "Pending Withdrawal", value: String(format: "%.2f HYPE", vm.pendingWithdrawal),
                        color: .orange)
            stakingStat(label: "Total Rewards", value: String(format: "%.4f HYPE", vm.totalRewards),
                        color: .hlGreen)
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(white: 0.09))
        )
    }

    private func stakingStat(label: String, value: String, color: Color) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 14))
                .foregroundColor(Color(white: 0.5))
            Spacer()
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundColor(color)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: - Validator row

    private func validatorRow(_ v: ValidatorInfo) -> some View {
        HStack(spacing: 12) {
            // Icon
            Image(systemName: v.isJailed ? "exclamationmark.shield.fill" : "person.badge.shield.checkmark.fill")
                .font(.system(size: 16))
                .foregroundColor(v.isJailed ? .red : .hlGreen)
                .frame(width: 32, height: 32)
                .background((v.isJailed ? Color.red : Color.hlGreen).opacity(0.12))
                .cornerRadius(8)

            // Info
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(v.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)

                    if v.isActive {
                        Circle()
                            .fill(Color.hlGreen)
                            .frame(width: 6, height: 6)
                    }
                }

                HStack(spacing: 8) {
                    Text(String(format: "%.1f%%", v.stakePercentage))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Color(white: 0.45))
                    Text("Fee \(String(format: "%.1f%%", v.commission * 100))")
                        .font(.system(size: 11))
                        .foregroundColor(Color(white: 0.45))
                    Text("Up \(String(format: "%.0f%%", v.uptimePercent))")
                        .font(.system(size: 11))
                        .foregroundColor(v.uptimePercent >= 95 ? .hlGreen : .orange)
                }
            }

            Spacer()

            // Stake amount & APR
            VStack(alignment: .trailing, spacing: 3) {
                Text(formatStake(v.stake))
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white)
                Text(String(format: "~%.1f%% APR", v.estimatedAPR))
                    .font(.system(size: 11))
                    .foregroundColor(.hlGreen)
            }

            if wallet.isLocalWallet {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color(white: 0.25))
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(white: 0.09))
        )
    }

    // MARK: - Rewards Tab

    private var rewardsTab: some View {
        ScrollView {
            VStack(spacing: 12) {
                // Total rewards header
                HStack {
                    Text("Total Rewards")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(Color(white: 0.5))
                    Spacer()
                    Text(String(format: "+%.4f HYPE", vm.totalRewards))
                        .font(.system(size: 16, weight: .bold, design: .monospaced))
                        .foregroundColor(.hlGreen)
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(white: 0.09))
                )

                if vm.isLoading && vm.rewardHistory.isEmpty {
                    ProgressView().tint(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                } else if vm.rewardHistory.isEmpty {
                    emptyState(icon: "gift.fill", message: "No rewards yet")
                } else {
                    LazyVStack(spacing: 6) {
                        ForEach(vm.rewardHistory) { reward in
                            rewardRow(reward)
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 20)
        }
        .refreshable {
            await vm.refresh(address: address)
        }
    }

    private func rewardRow(_ r: StakingReward) -> some View {
        HStack(spacing: 10) {
            // Source badge
            Text(r.source.capitalized)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(r.source == "delegation" ? .hlGreen : .orange)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background((r.source == "delegation" ? Color.hlGreen : Color.orange).opacity(0.15))
                .cornerRadius(4)

            Text(formatDate(r.time))
                .font(.system(size: 12))
                .foregroundColor(Color(white: 0.45))

            Spacer()

            Text(String(format: "+%.4f", r.amount))
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundColor(.hlGreen)

            Text("HYPE")
                .font(.system(size: 11))
                .foregroundColor(Color(white: 0.4))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(white: 0.07))
        .cornerRadius(8)
    }

    // MARK: - Actions Tab

    private var actionsTab: some View {
        ScrollView {
            VStack(spacing: 12) {
                if vm.isLoading && vm.actionHistory.isEmpty {
                    ProgressView().tint(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                } else if vm.actionHistory.isEmpty {
                    emptyState(icon: "clock.arrow.circlepath", message: "No staking actions")
                } else {
                    LazyVStack(spacing: 6) {
                        ForEach(vm.actionHistory) { action in
                            actionRow(action)
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 20)
        }
        .refreshable {
            await vm.refresh(address: address)
        }
    }

    private func actionRow(_ a: StakingAction) -> some View {
        HStack(spacing: 10) {
            // Action badge
            Text(a.actionType.rawValue)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(a.actionType == .delegate ? .hlGreen : .orange)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background((a.actionType == .delegate ? Color.hlGreen : Color.orange).opacity(0.15))
                .cornerRadius(4)

            VStack(alignment: .leading, spacing: 2) {
                Text(a.validatorName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text(formatDate(a.time))
                    .font(.system(size: 11))
                    .foregroundColor(Color(white: 0.4))
            }

            Spacer()

            Text(String(format: "%.2f HYPE", a.amount))
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundColor(a.actionType == .delegate ? .hlGreen : .orange)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(white: 0.07))
        .cornerRadius(8)
    }

    // MARK: - Helpers

    private func emptyState(icon: String, message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 36))
                .foregroundColor(Color(white: 0.25))
            Text(message)
                .font(.system(size: 14))
                .foregroundColor(Color(white: 0.4))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    private func formatStake(_ value: Double) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", value / 1_000_000) }
        if value >= 1_000     { return String(format: "%.0fK", value / 1_000) }
        return String(format: "%.0f", value)
    }

    private func formatDate(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d, HH:mm"
        return fmt.string(from: date)
    }
}
