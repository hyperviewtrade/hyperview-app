import SwiftUI

// MARK: - WithdrawAssetView
// Destination address + amount input → Face ID → sign → POST

struct WithdrawAssetView: View {
    let asset: WithdrawAssetInfo

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var wallet = WalletManager.shared

    @State private var destinationAddress = ""
    @State private var amount = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var successMessage: String?

    private enum Field: Int, CaseIterable { case address, amount }
    @FocusState private var focusedField: Field?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 20) {

                    // Header
                    Text("Withdraw \(asset.name)")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.top, 20)

                    // Destination address
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Destination Address")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(Color(white: 0.5))

                        TextField("0x...", text: $destinationAddress)
                            .font(.system(size: 14, design: .monospaced))
                            .foregroundColor(.white)
                            .focused($focusedField, equals: .address)
                            .padding(12)
                            .background(Color.hlSurface)
                            .cornerRadius(10)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)

                        // Paste button
                        Button {
                            if let pasted = UIPasteboard.general.string {
                                destinationAddress = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "doc.on.clipboard")
                                Text("Paste")
                            }
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.hlGreen)
                        }
                    }
                    .padding(.horizontal, 14)

                    // Amount
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Amount")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(Color(white: 0.5))
                            Spacer()
                            Button("Max") {
                                if asset.name == "USDC" {
                                    let max = wallet.accountValue - 1 // leave $1 for fee
                                    amount = max > 0 ? String(format: "%.2f", max) : "0"
                                }
                            }
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.hlGreen)
                        }

                        HStack {
                            TextField("0.00", text: $amount)
                                .font(.system(size: 20, weight: .bold))
                                .foregroundColor(.white)
                                .keyboardType(.decimalPad)
                                .focused($focusedField, equals: .amount)
                            Text(asset.name)
                                .font(.system(size: 16, weight: .medium))
                                .foregroundColor(Color(white: 0.5))
                        }
                        .padding(12)
                        .background(Color.hlSurface)
                        .cornerRadius(10)
                    }
                    .padding(.horizontal, 14)

                    // Info cards
                    VStack(spacing: 1) {
                        infoRow(label: "Network", value: asset.network)
                        infoRow(label: "Fee", value: asset.fee)
                        infoRow(label: "Minimum", value: "\(asset.minWithdraw) \(asset.name)")
                        infoRow(label: "Estimated Time", value: asset.estimatedTime)
                    }
                    .cornerRadius(12)
                    .padding(.horizontal, 14)

                    // Error / Success
                    if let error = errorMessage {
                        Text(error)
                            .font(.system(size: 13))
                            .foregroundColor(.red)
                            .padding(.horizontal, 14)
                    }
                    if let success = successMessage {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.hlGreen)
                            Text(success)
                                .foregroundColor(.hlGreen)
                        }
                        .font(.system(size: 14, weight: .medium))
                        .padding(.horizontal, 14)
                    }
                }
            }

            // Confirm button
            Button {
                Task { await submitWithdraw() }
            } label: {
                HStack(spacing: 8) {
                    if isSubmitting {
                        ProgressView().tint(.black)
                    }
                    Text(wallet.biometricEnabled ? "Confirm with Face ID" : "Confirm Withdraw")
                        .font(.system(size: 16, weight: .bold))
                }
                .foregroundColor(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(canSubmit ? Color.hlGreen : Color.gray)
                .cornerRadius(14)
            }
            .disabled(!canSubmit || isSubmitting)
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
        }
        .background(Color.hlBackground.ignoresSafeArea())
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if focusedField != nil {
                withdrawKeyboardBar
            }
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Validation

    private var canSubmit: Bool {
        !destinationAddress.isEmpty &&
        destinationAddress.count >= 10 &&
        (Double(amount) ?? 0) > 0 &&
        !isSubmitting &&
        successMessage == nil
    }

    // MARK: - Submit

    private func submitWithdraw() async {
        isSubmitting = true
        errorMessage = nil
        successMessage = nil

        do {
            let payload: [String: Any]

            switch asset.method {
            case .withdraw3:
                // USDC withdraw via EIP-712 signed withdraw3
                payload = try await TransactionSigner.signWithdraw3(
                    destination: destinationAddress,
                    amount: amount
                )

            case .unitBridge(let chain):
                // For BTC/ETH/SOL: get intermediate HL address from UNIT,
                // then spotSend to that address
                let intermediateAddr = try await HyperliquidAPI.shared
                    .generateWithdrawAddress(dstChain: chain, asset: asset.name.lowercased(),
                                              dstAddress: destinationAddress)
                payload = try await TransactionSigner.signSpotSend(
                    destination: intermediateAddr,
                    token: asset.name,
                    amount: amount
                )
            }

            let response = try await TransactionSigner.postAction(payload)
            if let status = response["status"] as? String, status == "ok" {
                successMessage = "Withdrawal submitted!"
            } else if let error = response["error"] as? String {
                errorMessage = error
            } else {
                successMessage = "Withdrawal submitted!"
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        isSubmitting = false
    }

    // MARK: - Keyboard bar (chevrons + Done)

    private var withdrawKeyboardBar: some View {
        HStack(spacing: 12) {
            Button {
                focusedField = focusedField.flatMap { Field(rawValue: $0.rawValue - 1) }
            } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(focusedField == .address ? Color(white: 0.3) : .white)
            }
            .disabled(focusedField == .address)

            Button {
                focusedField = focusedField.flatMap { Field(rawValue: $0.rawValue + 1) }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(focusedField == .amount ? Color(white: 0.3) : .white)
            }
            .disabled(focusedField == .amount)

            Spacer()

            Button("Done") {
                focusedField = nil
            }
            .fontWeight(.semibold)
            .foregroundColor(.hlGreen)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(white: 0.12))
    }

    // MARK: - Info row

    private func infoRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
                .foregroundColor(Color(white: 0.5))
            Spacer()
            Text(value)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.hlCardBackground)
    }
}
