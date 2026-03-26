import SwiftUI
import LocalAuthentication

enum EarnAction: String {
    case supply = "Supply"
    case withdraw = "Withdraw"
}

struct SupplyWithdrawSheet: View {
    let action: EarnAction
    let initialTokenName: String
    let initialTokenIndex: Int
    let initialAvailableBalance: Double
    var exactSuppliedString: String? = nil
    var allEarnAssets: [EarnAsset] = []  // All available tokens for picker
    var onSuccess: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var selectedCoin: String = ""
    @State private var selectedTokenIndex: Int = 0
    @State private var amount: String = ""
    @State private var sliderPct: Double = 0
    @State private var displayBalance: Double? = nil
    @State private var isTyping = false

    private var availableBalance: Double {
        if let db = displayBalance { return db }
        // If user changed token, get balance from the earn assets
        if selectedCoin != initialTokenName, let asset = allEarnAssets.first(where: { $0.coin == selectedCoin }) {
            return action == .supply
                ? (WalletManager.shared.spotTokenAvailable[selectedCoin] ?? 0)
                : asset.userSupplied
        }
        return initialAvailableBalance
    }
    @State private var isSubmitting = false
    @State private var resultMessage: String? = nil
    @State private var isError = false
    @FocusState private var amountFocused: Bool

    private var amountValue: Double {
        Double(amount.replacingOccurrences(of: ",", with: ".")) ?? 0
    }

    private var isWithdrawAll: Bool {
        action == .withdraw && sliderPct >= 100
    }

    private var isValid: Bool {
        if isWithdrawAll { return !isSubmitting && availableBalance > 0 }
        return amountValue > 0 && amountValue <= availableBalance && !isSubmitting
    }

    private var displayCoin: String {
        selectedCoin == "UBTC" ? "BTC" : selectedCoin
    }

    // Hardcoded token name → index mapping (never fails)
    private static let tokenIndexMap: [String: Int] = [
        "USDC": 0, "USDH": 360, "UBTC": 197, "HYPE": 150,
        "USDT0": 268, "USDE": 235
    ]

    // In classic mode, only stablecoins can be supplied
    private static let classicSupplyTokens: Set<String> = ["USDC", "USDH"]

    // Tokens shown in the picker (for supply action)
    private var earnEligibleTokens: [(name: String, index: Int)] {
        let isPM = WalletManager.shared.isPortfolioMargin
        let all: [(String, Int)] = isPM
            ? [("USDC", 0), ("USDH", 360), ("UBTC", 197), ("HYPE", 150)]
            : [("USDC", 0), ("USDH", 360)]
        return all
    }

    // Token szDecimals for borrowLend amount formatting
    // Use weiDecimals (not szDecimals) — borrowLend accepts full precision
    private var tokenSzDecimals: Int {
        switch selectedCoin {
        case "USDC": return 8
        case "USDH": return 8
        case "UBTC": return 8
        case "HYPE": return 8
        default: return 8
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Description
                    Text(action == .supply
                         ? "Supply \(displayCoin) to earn interest on your idle assets."
                         : "Withdraw \(displayCoin) from the lending pool.")
                        .font(.system(size: 13))
                        .foregroundColor(Color(white: 0.5))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)

                    // Token picker
                    if action == .supply {
                        HStack {
                            Text("Token")
                                .font(.system(size: 13))
                                .foregroundColor(Color(white: 0.5))
                            Spacer()
                            Picker("Token", selection: $selectedCoin) {
                                ForEach(earnEligibleTokens, id: \.name) { token in
                                    Text(token.name == "UBTC" ? "BTC" : token.name)
                                        .tag(token.name)
                                }
                            }
                            .pickerStyle(.menu)
                            .tint(.hlGreen)
                        }
                        .padding(.horizontal, 16)
                        .onChange(of: selectedCoin) { _, newCoin in
                            selectedTokenIndex = Self.tokenIndexMap[newCoin] ?? 0
                            displayBalance = nil
                            amount = ""
                            sliderPct = 0
                        }
                    }

                    // Slider
                    VStack(spacing: 10) {
                        HStack {
                            Slider(value: $sliderPct, in: 0...100, step: 1)
                                .tint(.hlGreen)
                            Text("\(Int(sliderPct))%")
                                .font(.system(size: 14, weight: .bold, design: .monospaced))
                                .foregroundColor(.white)
                                .frame(width: 50)
                        }

                        // Quick buttons
                        HStack(spacing: 8) {
                            ForEach([25, 50, 75, 100], id: \.self) { pct in
                                Button {
                                    sliderPct = Double(pct)
                                    updateAmountFromSlider()
                                } label: {
                                    Text("\(pct)%")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundColor(Int(sliderPct) == pct ? .white : .hlGreen)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 8)
                                        .background(
                                            RoundedRectangle(cornerRadius: 8)
                                                .fill(Int(sliderPct) == pct ? Color.hlGreen : Color.hlGreen.opacity(0.15))
                                        )
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)

                    // Amount input
                    HStack {
                        TextField("Amount", text: $amount)
                            .keyboardType(.decimalPad)
                            .font(.system(size: 18, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                            .focused($amountFocused)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)

                        Text(displayCoin)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(Color(white: 0.5))
                    }
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color(white: 0.2), lineWidth: 1)
                    )
                    .padding(.horizontal, 16)

                    // Available balance
                    HStack {
                        Text("Available Balance")
                            .font(.system(size: 12))
                            .foregroundColor(Color(white: 0.45))
                        Spacer()
                        Text("\(formatAmount(availableBalance)) \(displayCoin)")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundColor(.hlGreen)
                    }
                    .padding(.horizontal, 16)

                    // Result message
                    if let msg = resultMessage {
                        Text(msg)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(isError ? .tradingRed : .hlGreen)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 16)
                    }

                    // Submit button
                    Button {
                        Task { await submit() }
                    } label: {
                        HStack {
                            if isSubmitting {
                                ProgressView().tint(.white)
                            }
                            Text(action.rawValue)
                                .font(.system(size: 16, weight: .bold))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(isValid ? Color.hlGreen : Color.hlGreen.opacity(0.3))
                        )
                    }
                    .disabled(!isValid)
                    .padding(.horizontal, 16)
                }
                .padding(.vertical, 20)
            }
            .background(Color.hlBackground.ignoresSafeArea())
            .navigationTitle(action.rawValue)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                if selectedCoin.isEmpty {
                    selectedCoin = initialTokenName
                    selectedTokenIndex = initialTokenIndex
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white)
                    }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { amountFocused = false }
                        .fontWeight(.semibold)
                        .foregroundColor(.hlGreen)
                }
            }
            .onChange(of: sliderPct) { _, _ in
                updateAmountFromSlider()
            }
        }
    }

    private func updateAmountFromSlider() {
        isTyping = false
        if sliderPct >= 100 {
            if action == .withdraw, let exact = exactSuppliedString, !exact.isEmpty {
                // Use exact full-precision supplied amount from API
                amount = exact
            } else {
                amount = String(format: "%.8f", availableBalance)
            }
        } else {
            let val = availableBalance * sliderPct / 100
            if val > 0 {
                amount = formatAmount(val)
            } else {
                amount = ""
            }
        }
    }

    private func formatAmount(_ v: Double) -> String {
        let stables = ["USDC", "USDH", "USDT0", "USDE"]
        if stables.contains(selectedCoin) {
            return String(format: "%.2f", v)
        }
        if selectedCoin == "UBTC" {
            return String(format: "%.5f", v)
        }
        return String(format: "%.4f", v)
    }

    private func submit() async {
        guard isValid else { return }

        // Face ID
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            await MainActor.run {
                resultMessage = "Biometric authentication not available"
                isError = true
            }
            return
        }

        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: "\(action.rawValue) \(amount) \(displayCoin)"
            )
            guard success else { return }
        } catch {
            await MainActor.run {
                resultMessage = "Authentication cancelled"
                isError = true
            }
            return
        }

        await MainActor.run { isSubmitting = true; resultMessage = nil; isError = false }

        do {
            var cleanAmount = amount.replacingOccurrences(of: ",", with: ".")
            // Round to token's szDecimals to avoid "invalid amount" errors
            if let val = Double(cleanAmount) {
                if isWithdrawAll {
                    // Add 1% buffer for real-time interest accumulation
                    cleanAmount = String(format: "%.\(tokenSzDecimals)f", val * 1.01)
                } else {
                    cleanAmount = String(format: "%.\(tokenSzDecimals)f", val)
                }
            }
            let payload = try await TransactionSigner.signBorrowLend(
                operation: action == .supply ? "supply" : "withdraw",
                token: selectedTokenIndex,
                amount: cleanAmount
            )

            print("[EARN] \(action.rawValue) amount='\(cleanAmount)' coin=\(displayCoin) token=\(selectedTokenIndex) raw_input='\(amount)'")

            let result = try await TransactionSigner.postAction(payload)
            #if DEBUG
            print("[EARN] Result: \(result)")
            #endif

            if let status = result["status"] as? String {
                if status == "ok" {
                    await MainActor.run {
                        resultMessage = "\(action.rawValue) successful!"
                        isError = false
                        isSubmitting = false
                        // Update balance instantly
                        let amt = amountValue
                        if action == .supply {
                            displayBalance = max(0, availableBalance - amt)
                        } else {
                            displayBalance = max(0, availableBalance - amt)
                        }
                    }
                    // Auto-dismiss after 1.5s, then refresh after 2s delay for API propagation
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    await MainActor.run { dismiss() }
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    await MainActor.run { onSuccess?() }
                    return
                } else if status == "err", let errMsg = result["response"] as? String {
                    await MainActor.run {
                        resultMessage = errMsg
                        isError = true
                    }
                }
            }
        } catch {
            await MainActor.run {
                resultMessage = error.localizedDescription
                isError = true
            }
        }

        await MainActor.run { isSubmitting = false }
    }
}
