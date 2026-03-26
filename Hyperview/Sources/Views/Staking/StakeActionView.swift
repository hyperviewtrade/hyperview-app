import SwiftUI

struct StakeActionView: View {
    let validator: ValidatorInfo
    @EnvironmentObject var vm: StakingViewModel
    let walletAddress: String

    @ObservedObject private var wallet = WalletManager.shared
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isAmountFocused: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {

                // ── Validator info header ─────────────────────────────
                validatorHeader

                // ── Stake / Unstake toggle ────────────────────────────
                stakeToggle

                // ── Amount field ──────────────────────────────────────
                amountField

                // ── Info rows ─────────────────────────────────────────
                infoSection

                // ── Submit button ─────────────────────────────────────
                submitButton

                // ── Result / Error ────────────────────────────────────
                if let result = vm.txResult {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                        Text(result)
                    }
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.hlGreen)
                }

                if let error = vm.txError {
                    Text(error)
                        .font(.system(size: 13))
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 10)
                }
            }
            .padding(16)
            .padding(.bottom, 40)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color.hlBackground.ignoresSafeArea())
        .navigationTitle(vm.isUndelegate ? "Unstake HYPE" : "Stake HYPE")
        .navigationBarTitleDisplayMode(.inline)
        .keyboardDoneBar()
        .onAppear {
            vm.selectedValidator = validator
            vm.txResult = nil
            vm.txError = nil
        }
    }

    // MARK: - Validator header

    private var validatorHeader: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "person.badge.shield.checkmark.fill")
                    .font(.system(size: 24))
                    .foregroundColor(.hlGreen)

                VStack(alignment: .leading, spacing: 2) {
                    Text(validator.name)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white)
                    Text(shortAddr(validator.address))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Color(white: 0.4))
                }

                Spacer()

                // Status badge
                Text(validator.isActive ? "Active" : (validator.isJailed ? "Jailed" : "Inactive"))
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(validator.isActive ? .hlGreen : .red)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background((validator.isActive ? Color.hlGreen : Color.red).opacity(0.15))
                    .cornerRadius(6)
            }

            HStack(spacing: 0) {
                infoCell(label: "Commission", value: String(format: "%.1f%%", validator.commission * 100))
                infoCell(label: "Uptime", value: String(format: "%.1f%%", validator.uptimePercent))
                infoCell(label: "Est. APR", value: String(format: "%.1f%%", validator.estimatedAPR))
                infoCell(label: "Stake", value: formatStake(validator.stake))
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(white: 0.11))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color(white: 0.18), lineWidth: 1)
                )
        )
    }

    private func infoCell(label: String, value: String) -> some View {
        VStack(spacing: 3) {
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(Color(white: 0.45))
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(.white)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Stake / Unstake toggle

    private var stakeToggle: some View {
        HStack(spacing: 0) {
            toggleButton(title: "Stake", isActive: !vm.isUndelegate) {
                vm.isUndelegate = false
            }
            toggleButton(title: "Unstake", isActive: vm.isUndelegate) {
                vm.isUndelegate = true
            }
        }
        .background(Color(white: 0.11))
        .cornerRadius(10)
    }

    private func toggleButton(title: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(isActive ? .black : Color(white: 0.5))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(isActive ? Color.hlGreen : Color.clear)
                .cornerRadius(10)
        }
    }

    // MARK: - Amount field

    private var amountField: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Amount (HYPE)")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Color(white: 0.5))

                Spacer()

                Button {
                    if vm.isUndelegate {
                        // Max = delegated amount for this validator
                        if let del = vm.delegations.first(where: {
                            $0.validator.lowercased() == validator.address.lowercased()
                        }) {
                            vm.stakeAmount = String(format: "%.2f", del.amount)
                        }
                    } else {
                        vm.stakeAmount = String(format: "%.2f", vm.undelegated)
                    }
                } label: {
                    Text("Max")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.hlGreen)
                }
            }

            HStack(spacing: 8) {
                TextField("0.00", text: $vm.stakeAmount)
                    .font(.system(size: 22, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                    .keyboardType(.decimalPad)
                    .focused($isAmountFocused)

                Text("HYPE")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Color(white: 0.4))
            }
            .padding(14)
            .background(Color(white: 0.08))
            .cornerRadius(10)
        }
    }

    // MARK: - Info section

    private var infoSection: some View {
        VStack(spacing: 1) {
            infoRow(label: "Network", value: "Hyperliquid L1")
            if vm.isUndelegate {
                infoRow(label: "Lock Period", value: "~1 day")
            } else {
                infoRow(label: "Lock Period", value: "Until undelegated")
            }
            infoRow(label: "Available",
                    value: vm.isUndelegate
                        ? String(format: "%.2f HYPE", delegatedToValidator)
                        : String(format: "%.2f HYPE", vm.undelegated))
        }
        .background(Color(white: 0.09))
        .cornerRadius(12)
    }

    private var delegatedToValidator: Double {
        vm.delegations
            .first(where: { $0.validator.lowercased() == validator.address.lowercased() })?
            .amount ?? 0
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
                .foregroundColor(Color(white: 0.5))
            Spacer()
            Text(value)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundColor(.white)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: - Submit button

    private var canSubmit: Bool {
        guard !vm.isSubmitting,
              let amount = Double(vm.stakeAmount), amount > 0
        else { return false }
        if vm.isUndelegate {
            return amount <= delegatedToValidator
        }
        return amount <= vm.undelegated
    }

    private var submitButton: some View {
        Button {
            isAmountFocused = false
            Task {
                await vm.submitStake(address: walletAddress)
            }
        } label: {
            HStack(spacing: 8) {
                if vm.isSubmitting {
                    ProgressView()
                        .tint(.black)
                        .scaleEffect(0.8)
                } else {
                    Image(systemName: wallet.biometricEnabled ? "faceid" : "lock.fill")
                }
                Text(vm.isUndelegate ? "Confirm Unstake" : "Confirm Stake")
                    .font(.system(size: 15, weight: .bold))
            }
            .foregroundColor(.black)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(canSubmit ? Color.hlGreen : Color(white: 0.2))
            .cornerRadius(12)
        }
        .disabled(!canSubmit)
    }

    // MARK: - Helpers

    private func shortAddr(_ addr: String) -> String {
        guard addr.count > 10 else { return addr }
        return "\(addr.prefix(6))...\(addr.suffix(4))"
    }

    private func formatStake(_ value: Double) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", value / 1_000_000) }
        if value >= 1_000     { return String(format: "%.1fK", value / 1_000) }
        return String(format: "%.0f", value)
    }
}
