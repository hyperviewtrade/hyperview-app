import SwiftUI

// MARK: - Transfer Modes

enum TransferMode: String, CaseIterable {
    case coreToEVM   = "Core → EVM"
    case evmToCore   = "EVM → Core"
    case subAccount  = "Sub-Accounts"
}

// MARK: - Spot token for Core→EVM

private struct SpotToken: Identifiable {
    let id = UUID()
    let coin: String        // raw API coin name ("USOL", "HYPE", etc.)
    let displayCoin: String // human-readable name ("SOL", "HYPE", etc.)
    let token: String       // token identifier for API calls
    let tokenIndex: Int     // index in tokens array for bridge address
    let balance: Double     // total balance (for display)
    let available: Double   // available balance = total - hold (for Max / transfer / spend)
    var szDecimals: Int = 8    // TRADING precision: max decimal places for spot orders (from spotMeta)
    var evmDecimals: Int = 18  // EVM decimals for this token (weiDecimals + evm_extra_wei_decimals)

    /// TRANSFER precision: Hyperliquid transfers (spotSend / sendAsset) accept at least 8 decimals,
    /// which is independent of the trading szDecimals. Confirmed empirically (e.g. 0.01090404 HYPE works).
    static let transferDecimals = 8

    /// Mapping of wrapped spot names → display names (same as Market.swift)
    static let displayNameMap: [String: String] = [
        "UBTC": "BTC", "UETH": "ETH", "USOL": "SOL",
        "UFART": "FARTCOIN", "UPUMP": "PUMP", "HPENGU": "PENGU",
        "UBONK": "BONK", "UENA": "ENA", "UMON": "MON",
        "UZEC": "ZEC", "MMOVE": "MOVE", "UDZ": "DZ",
        "XAUT0": "XAUT", "USDT0": "USDT",
    ]

    static func displayName(for coin: String) -> String {
        displayNameMap[coin] ?? coin
    }
}

// MARK: - Sub-account cache (persist across Transfer opens)

private final class SubAccountCache {
    static let shared = SubAccountCache()
    private(set) var entries: [SubAccountEntry] = []
    private var masterAddress: String?

    func get(for master: String) -> [SubAccountEntry]? {
        guard master == masterAddress, !entries.isEmpty else { return nil }
        return entries
    }

    func save(_ entries: [SubAccountEntry], for master: String) {
        self.entries = entries
        self.masterAddress = master
    }
}

// MARK: - SpotMeta Cache (avoid re-fetching 448 tokens every time)

private final class SpotMetaCache {
    static let shared = SpotMetaCache()
    private var data: CachedMeta?
    private let ttl: TimeInterval = 300 // 5 min

    struct CachedMeta {
        let tokenIdMap: [Int: String]
        let evmContractMap: [Int: String]
        let evmDecimalsMap: [Int: Int]
        let szDecimalsMap: [Int: Int]
        let tokenNameByIndex: [Int: String]
        let timestamp: Date
    }

    func get() -> CachedMeta? {
        guard let d = data, Date().timeIntervalSince(d.timestamp) < ttl else { return nil }
        return d
    }

    func save(tokenIdMap: [Int: String], evmContractMap: [Int: String],
              evmDecimalsMap: [Int: Int], szDecimalsMap: [Int: Int], tokenNameByIndex: [Int: String]) {
        data = CachedMeta(tokenIdMap: tokenIdMap, evmContractMap: evmContractMap,
                          evmDecimalsMap: evmDecimalsMap, szDecimalsMap: szDecimalsMap,
                          tokenNameByIndex: tokenNameByIndex, timestamp: Date())
    }
}

// MARK: - Sub-account entry (master or sub)

private struct SubAccountEntry: Identifiable {
    let id = UUID()
    let name: String
    let address: String
    let isMaster: Bool
}

// MARK: - TransferView

struct TransferView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var wallet = WalletManager.shared

    @State private var mode: TransferMode = .coreToEVM
    @State private var amount = ""
    @State private var isSubmitting = false
    @State private var resultMessage: String?
    @State private var isSuccess = false

    // Core → EVM: token picker
    @State private var spotTokens: [SpotToken] = []
    @State private var selectedToken: SpotToken?
    @State private var showTokenPicker = false

    // EVM → Core: tokens on HyperEVM
    @State private var evmTokens: [SpotToken] = []
    @State private var selectedEVMToken: SpotToken?
    @State private var showEVMTokenPicker = false
    @State private var didLoadTokens = false
    @State private var debugInfo = ""

    // Sub-account spot transfer
    @State private var subAccounts: [SubAccountEntry] = []  // includes master
    @State private var sourceAccount: SubAccountEntry?
    @State private var destAccount: SubAccountEntry?
    @State private var showSourcePicker = false
    @State private var showDestPicker = false
    @State private var subSpotTokens: [SpotToken] = []       // tokens for selected source
    @State private var selectedSubToken: SpotToken?
    @State private var showSubTokenPicker = false
    @State private var isLoadingSubs = false
    @FocusState private var amountFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Mode picker
                    Picker("Transfer", selection: $mode) {
                        ForEach(TransferMode.allCases, id: \.self) { m in
                            Text(m.rawValue).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)
                    .onChange(of: mode) { _, _ in
                        amount = ""
                        resultMessage = nil
                        if mode == .subAccount {
                            Task { await fetchSubAccounts() }
                        } else {
                            Task { await fetchBalances() }
                        }
                    }

                    if mode == .subAccount {
                        subAccountContent
                    } else {
                        bridgeContent
                    }

                    // Result message
                    if let msg = resultMessage {
                        HStack(spacing: 8) {
                            Image(systemName: isSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundColor(isSuccess ? .hlGreen : .tradingRed)
                            Text(msg)
                                .font(.system(size: 13))
                                .foregroundColor(isSuccess ? .hlGreen : .tradingRed)
                        }
                        .padding(.horizontal, 16)
                    }

                    // Submit button
                    Button {
                        Task { await submitTransfer() }
                    } label: {
                        HStack(spacing: 8) {
                            if isSubmitting {
                                ProgressView().tint(.black)
                            }
                            Image(systemName: wallet.biometricEnabled ? "faceid" : "arrow.left.arrow.right")
                                .font(.system(size: 14))
                            Text(wallet.biometricEnabled ? "Confirm with Face ID" : "Confirm Transfer")
                        }
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(canSubmit ? Color.hlGreen : Color.hlGreen.opacity(0.3))
                        .cornerRadius(12)
                    }
                    .disabled(!canSubmit)
                    .padding(.horizontal, 16)

                    // Explain why button is disabled
                    if let reason = disabledReason {
                        Text(reason)
                            .font(.system(size: 12))
                            .foregroundColor(.tradingRed)
                            .padding(.horizontal, 16)
                    }

                    // Debug info (temporary)
                    if !debugInfo.isEmpty {
                        Text(debugInfo)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(Color(white: 0.4))
                            .padding(.horizontal, 16)
                            .padding(.top, 8)
                    }

                    Spacer()
                }
                .padding(.top, 10)
            }
            .background(Color.hlBackground.ignoresSafeArea())
            .keyboardDoneBar()
            .navigationTitle("Transfer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundColor(.hlGreen)
                }
            }
            .sheet(isPresented: $showTokenPicker) {
                tokenPickerSheet(tokens: spotTokens, selected: selectedToken?.coin) { t in
                    selectedToken = t
                    showTokenPicker = false
                }
            }
            .sheet(isPresented: $showEVMTokenPicker) {
                tokenPickerSheet(tokens: evmTokens, selected: selectedEVMToken?.coin) { t in
                    selectedEVMToken = t
                    showEVMTokenPicker = false
                }
            }
            .sheet(isPresented: $showSubTokenPicker) {
                tokenPickerSheet(tokens: subSpotTokens, selected: selectedSubToken?.coin) { t in
                    selectedSubToken = t
                    showSubTokenPicker = false
                }
            }
            .sheet(isPresented: $showSourcePicker) {
                accountPickerSheet(title: "Source Account", selected: sourceAccount?.address) { acc in
                    // If user selected the current destination, swap them
                    if acc.address == destAccount?.address {
                        destAccount = sourceAccount
                    }
                    sourceAccount = acc
                    showSourcePicker = false
                    selectedSubToken = nil
                    subSpotTokens = []
                    Task { await fetchSubSpotBalances(for: acc.address) }
                }
            }
            .sheet(isPresented: $showDestPicker) {
                accountPickerSheet(title: "Destination Account", selected: destAccount?.address) { acc in
                    // If user selected the current source, swap them
                    if acc.address == sourceAccount?.address {
                        sourceAccount = destAccount
                        // Re-fetch tokens for the new source
                        selectedSubToken = nil
                        subSpotTokens = []
                        if let newSrc = sourceAccount {
                            Task { await fetchSubSpotBalances(for: newSrc.address) }
                        }
                    }
                    destAccount = acc
                    showDestPicker = false
                }
            }
            .task {
                // Pre-populate from WalletManager's cached spot balances for instant first token
                prefillFromCachedBalances()
                // Prefetch sub-accounts in background so they're ready when user switches to Sub-Accounts tab
                Task { await fetchSubAccounts() }
                await fetchBalances()
            }
        }
    }

    // MARK: - Token picker sheet

    /// Stablecoins treated as $1.00 face value
    private static let stablecoins: Set<String> = ["USDC", "USDH", "USDT", "USDT0", "USDE"]

    /// Estimate USD value for a spot token using WebSocket mid prices
    private func tokenUSDValue(_ t: SpotToken) -> Double {
        if Self.stablecoins.contains(t.coin) || Self.stablecoins.contains(t.displayCoin) {
            return t.balance  // stables = face value
        }
        let prices = WebSocketManager.shared.latestMidPrices
        // Try display name first (e.g. "BTC"), then raw coin name (e.g. "UBTC")
        let price = prices[t.displayCoin] ?? prices[t.coin] ?? 0
        return t.balance * price
    }

    /// USD value using available balance (for "available" displays)
    private func tokenAvailableUSDValue(_ t: SpotToken) -> Double {
        if Self.stablecoins.contains(t.coin) || Self.stablecoins.contains(t.displayCoin) {
            return t.available
        }
        let prices = WebSocketManager.shared.latestMidPrices
        let price = prices[t.displayCoin] ?? prices[t.coin] ?? 0
        return t.available * price
    }

    private func tokenPickerSheet(tokens: [SpotToken], selected: String?, onSelect: @escaping (SpotToken) -> Void) -> some View {
        let sorted = tokens.sorted { tokenUSDValue($0) > tokenUSDValue($1) }
        return NavigationStack {
            List {
                if sorted.isEmpty {
                    Text("No tokens found")
                        .foregroundColor(Color(white: 0.5))
                        .listRowBackground(Color.hlBackground)
                } else {
                    ForEach(sorted) { t in
                        Button {
                            onSelect(t)
                        } label: {
                            HStack(spacing: 12) {
                                CoinIconView(symbol: t.displayCoin, hlIconName: t.displayCoin, iconSize: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(t.displayCoin)
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundColor(.white)
                                    Text("\(formatTokenAmount(t.available, maxDecimals: displayDecimals(for: t))) \(t.displayCoin)")
                                        .font(.system(size: 11))
                                        .foregroundColor(Color(white: 0.4))
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    let usd = tokenUSDValue(t)
                                    if usd > 0 {
                                        Text(formatUSD(usd))
                                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                                            .foregroundColor(.white)
                                    }
                                    if selected == t.coin {
                                        Image(systemName: "checkmark")
                                            .foregroundColor(.hlGreen)
                                    }
                                }
                            }
                        }
                        .listRowBackground(Color(white: 0.09))
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.hlBackground)
            .navigationTitle("Select Token")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        showTokenPicker = false
                        showEVMTokenPicker = false
                        showSubTokenPicker = false
                    }
                    .foregroundColor(.hlGreen)
                }
            }
        }
    }

    // MARK: - Account picker sheet (sub-account mode)

    private func accountPickerSheet(title: String, selected: String?, onSelect: @escaping (SubAccountEntry) -> Void) -> some View {
        NavigationStack {
            List {
                if subAccounts.isEmpty {
                    Text(isLoadingSubs ? "Loading..." : "No accounts found")
                        .foregroundColor(Color(white: 0.5))
                        .listRowBackground(Color.hlBackground)
                } else {
                    ForEach(subAccounts) { acc in
                        Button {
                            onSelect(acc)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(acc.name)
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundColor(.white)
                                    Text(String(acc.address.prefix(10)) + "..." + String(acc.address.suffix(6)))
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(Color(white: 0.4))
                                }
                                Spacer()
                                if selected == acc.address {
                                    Image(systemName: "checkmark").foregroundColor(.hlGreen)
                                }
                            }
                        }
                        .listRowBackground(Color(white: 0.09))
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.hlBackground)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        showSourcePicker = false
                        showDestPicker = false
                    }
                    .foregroundColor(.hlGreen)
                }
            }
        }
    }

    // MARK: - Bridge content (Core ↔ EVM)

    private var bridgeContent: some View {
        Group {
            // Token picker
            tokenPickerButton

            // Info card
            VStack(spacing: 12) {
                infoRow(label: "From", value: fromLabel)
                Divider().background(Color(white: 0.15))
                infoRow(label: "To", value: toLabel)
                Divider().background(Color(white: 0.15))
                infoRow(label: "Available", value: availableBalanceFormatted)
            }
            .padding(14)
            .background(Color(white: 0.09))
            .cornerRadius(12)
            .padding(.horizontal, 16)

            // Amount input
            amountInput

            // Info text
            if mode == .coreToEVM {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle").foregroundColor(.hlGreen)
                    Text("Transfers tokens from Hypercore to your HyperEVM address. ~2s settlement. HYPE arrives as native gas token.")
                        .font(.system(size: 12)).foregroundColor(Color(white: 0.5))
                }
                .padding(.horizontal, 20)
            }
            if mode == .evmToCore {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle").foregroundColor(.hlGreen)
                    Text("Transfers HYPE from HyperEVM back to Hypercore. Useful after CEX deposits that arrive on EVM.")
                        .font(.system(size: 12)).foregroundColor(Color(white: 0.5))
                }
                .padding(.horizontal, 20)
            }
        }
    }

    // MARK: - Sub-account content

    private var subAccountContent: some View {
        Group {
            // Source account picker
            accountPickerRow(label: "From", account: sourceAccount) { showSourcePicker = true }

            // Destination account picker
            accountPickerRow(label: "To", account: destAccount) { showDestPicker = true }

            // Token picker (only after source is selected)
            if sourceAccount != nil {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Token")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Color(white: 0.5))
                    Button { showSubTokenPicker = true } label: {
                        HStack(spacing: 10) {
                            if let t = selectedSubToken {
                                CoinIconView(symbol: t.displayCoin, hlIconName: t.displayCoin, iconSize: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(t.displayCoin)
                                        .font(.system(size: 15, weight: .bold))
                                        .foregroundColor(.white)
                                    // Show NET balance + NET USD value (main token display)
                                    let netUSD = tokenUSDValue(t)
                                    if netUSD > 0 {
                                        Text("\(formatTokenAmount(t.balance, maxDecimals: displayDecimals(for: t))) \(t.displayCoin) (~\(formatUSD(netUSD)))")
                                            .font(.system(size: 11))
                                            .foregroundColor(Color(white: 0.4))
                                    } else {
                                        Text("\(formatTokenAmount(t.balance, maxDecimals: displayDecimals(for: t))) \(t.displayCoin)")
                                            .font(.system(size: 11))
                                            .foregroundColor(Color(white: 0.4))
                                    }
                                }
                            } else if subSpotTokens.isEmpty {
                                ProgressView().tint(Color(white: 0.5))
                                Text("Loading tokens...")
                                    .font(.system(size: 15)).foregroundColor(Color(white: 0.5))
                            } else {
                                Image(systemName: "plus.circle").foregroundColor(.hlGreen)
                                Text("Select token")
                                    .font(.system(size: 15)).foregroundColor(Color(white: 0.5))
                            }
                            Spacer()
                            Image(systemName: "chevron.down")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(Color(white: 0.4))
                        }
                        .padding(14)
                        .background(Color(white: 0.09))
                        .cornerRadius(12)
                    }
                }
                .padding(.horizontal, 16)
            }

            // Available balance info (same concept as Core→EVM / EVM→Core)
            if let t = selectedSubToken {
                HStack {
                    Text("Available")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Color(white: 0.5))
                    Spacer()
                    let amt = formatTokenAmount(t.available, maxDecimals: displayDecimals(for: t))
                    let usd = tokenAvailableUSDValue(t)
                    if usd > 0 {
                        Text("\(amt) \(t.displayCoin) (~\(formatUSD(usd)))")
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .foregroundColor(.white)
                    } else {
                        Text("\(amt) \(t.displayCoin)")
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .foregroundColor(.white)
                    }
                }
                .padding(.horizontal, 16)
            }

            // Amount input
            amountInput

            HStack(spacing: 8) {
                Image(systemName: "info.circle").foregroundColor(.hlGreen)
                Text("Transfers a spot token between your sub-accounts on Hypercore via spotSend.")
                    .font(.system(size: 12)).foregroundColor(Color(white: 0.5))
            }
            .padding(.horizontal, 20)
        }
    }

    private func accountPickerRow(label: String, account: SubAccountEntry?, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Color(white: 0.5))
            Button(action: action) {
                HStack {
                    if let acc = account {
                        Text(acc.name)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.white)
                        Text(String(acc.address.prefix(8)) + "...")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(Color(white: 0.4))
                    } else {
                        Text("Select account")
                            .font(.system(size: 15))
                            .foregroundColor(Color(white: 0.5))
                    }
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(Color(white: 0.4))
                }
                .padding(14)
                .background(Color(white: 0.09))
                .cornerRadius(12)
            }
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Shared amount input

    /// Live USD equivalent for the current input amount
    private var inputUSDValue: Double {
        guard let val = Double(stripCommas(amount)), val > 0 else { return 0 }
        let tok: SpotToken?
        switch mode {
        case .coreToEVM:  tok = selectedToken
        case .evmToCore:  tok = selectedEVMToken
        case .subAccount: tok = selectedSubToken
        }
        guard let t = tok else { return 0 }
        if t.displayCoin == "USDC" || t.displayCoin == "USDT" { return val }
        let prices = WebSocketManager.shared.latestMidPrices
        let price = prices[t.displayCoin] ?? prices[t.coin] ?? 0
        return val * price
    }

    private var amountInput: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(amountLabel)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Color(white: 0.5))

            HStack(spacing: 10) {
                TextField("0.00", text: $amount)
                    .keyboardType(.decimalPad)
                    .focused($amountFocused)
                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                    .toolbar {
                        ToolbarItemGroup(placement: .keyboard) {
                            Spacer()
                            Button("Done") { amountFocused = false }
                                .foregroundColor(.hlGreen)
                        }
                    }
                    .onChange(of: amount) { oldValue, newValue in
                        guard formatDecimalWithCommas(newValue) != newValue else { return }
                        let formatted = formatDecimalOnChange(oldValue: oldValue, newValue: newValue)
                        if formatted != newValue { amount = formatted }
                    }

                Button("Max") {
                    let avail = availableBalance
                    // Use transfer precision (8 dec), not trading precision (szDecimals)
                    if avail > 0 { amount = safeMaxAmount(avail, decimals: SpotToken.transferDecimals) }
                }
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.hlGreen)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.hlGreen.opacity(0.12))
                .cornerRadius(8)
            }
            .padding(14)
            .background(Color(white: 0.09))
            .cornerRadius(12)

            // Live USD equivalent
            if inputUSDValue > 0 {
                Text("~\(formatUSD(inputUSDValue))")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color(white: 0.45))
                    .padding(.leading, 4)
            }
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Token Picker Button

    private var tokenPickerButton: some View {
        let tokens = mode == .coreToEVM ? spotTokens : evmTokens
        let selected = mode == .coreToEVM ? selectedToken : selectedEVMToken
        return VStack(alignment: .leading, spacing: 8) {
            Text("Token")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Color(white: 0.5))

            Button {
                if mode == .coreToEVM { showTokenPicker = true }
                else { showEVMTokenPicker = true }
            } label: {
                HStack(spacing: 10) {
                    if let t = selected {
                        CoinIconView(symbol: t.displayCoin, hlIconName: t.displayCoin, iconSize: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t.displayCoin)
                                .font(.system(size: 15, weight: .bold))
                                .foregroundColor(.white)
                            // Show NET balance + NET USD value (main token display)
                            let netUSD = tokenUSDValue(t)
                            if netUSD > 0 {
                                Text("\(formatTokenAmount(t.balance, maxDecimals: displayDecimals(for: t))) \(t.displayCoin) (~\(formatUSD(netUSD)))")
                                    .font(.system(size: 11))
                                    .foregroundColor(Color(white: 0.4))
                            } else {
                                Text("\(formatTokenAmount(t.balance, maxDecimals: displayDecimals(for: t))) \(t.displayCoin)")
                                    .font(.system(size: 11))
                                    .foregroundColor(Color(white: 0.4))
                            }
                        }
                    } else if tokens.isEmpty && !didLoadTokens {
                        ProgressView().tint(Color(white: 0.5))
                        Text("Loading tokens...")
                            .font(.system(size: 15))
                            .foregroundColor(Color(white: 0.5))
                    } else if tokens.isEmpty {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundColor(.yellow)
                        Text("No tokens found")
                            .font(.system(size: 15))
                            .foregroundColor(Color(white: 0.5))
                    } else {
                        Image(systemName: "plus.circle")
                            .foregroundColor(.hlGreen)
                        Text("Select token")
                            .font(.system(size: 15))
                            .foregroundColor(Color(white: 0.5))
                    }
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(Color(white: 0.4))
                }
                .padding(14)
                .background(Color(white: 0.09))
                .cornerRadius(12)
            }
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Computed

    private var fromLabel: String {
        switch mode {
        case .coreToEVM:   return "Hypercore"
        case .evmToCore:   return "HyperEVM"
        case .subAccount:  return sourceAccount?.name ?? "Select source"
        }
    }

    private var toLabel: String {
        switch mode {
        case .coreToEVM:   return "HyperEVM"
        case .evmToCore:   return "Hypercore"
        case .subAccount:  return destAccount?.name ?? "Select destination"
        }
    }

    private var availableBalance: Double {
        switch mode {
        case .coreToEVM:   return selectedToken?.available ?? 0
        case .evmToCore:   return selectedEVMToken?.available ?? 0
        case .subAccount:  return selectedSubToken?.available ?? 0
        }
    }

    private var availableBalanceFormatted: String {
        let t: SpotToken?
        switch mode {
        case .coreToEVM:  t = selectedToken
        case .evmToCore:  t = selectedEVMToken
        case .subAccount: t = selectedSubToken
        }
        guard let tok = t else { return "Select a token" }
        let amt = formatTokenAmount(tok.available, maxDecimals: displayDecimals(for: tok))
        let usd = tokenAvailableUSDValue(tok)
        if usd > 0 {
            return "\(amt) \(tok.displayCoin) (~\(formatUSD(usd)))"
        }
        return "\(amt) \(tok.displayCoin)"
    }

    /// Format a USD value as "$X.XX" or "$X,XXX.XX"
    private func formatUSD(_ value: Double) -> String {
        if value >= 1000 {
            let formatter = NumberFormatter()
            formatter.numberStyle = .currency
            formatter.currencyCode = "USD"
            formatter.maximumFractionDigits = 2
            return formatter.string(from: NSNumber(value: value)) ?? String(format: "$%.2f", value)
        }
        return String(format: "$%.2f", value)
    }

    /// Display decimals: enough precision to show meaningful balance (never truncate to zero).
    /// szDecimals is for API order sizing — display needs more precision for small balances.
    private func displayDecimals(for token: SpotToken) -> Int {
        // For display, use at least szDecimals but up to 8 to show small balances
        return max(token.szDecimals, 8)
    }

    /// Safe max amount: floor to szDecimals precision (never rounds up past available).
    /// If flooring to szDecimals yields 0 but balance > 0, return the raw balance string.
    private func safeMaxAmount(_ value: Double, decimals: Int) -> String {
        guard value > 0 else { return "0" }
        let factor = pow(10.0, Double(decimals))
        let floored = floor(value * factor) / factor
        if floored > 0 {
            return formatTokenAmount(floored, maxDecimals: decimals)
        }
        // Balance is smaller than 1 unit at szDecimals precision — show full precision
        // Use up to 8 decimals to avoid returning 0
        let extFactor = pow(10.0, 8.0)
        let extFloored = floor(value * extFactor) / extFactor
        if extFloored > 0 {
            return formatTokenAmount(extFloored, maxDecimals: 8)
        }
        // Ultra-small: just format raw value
        return formatTokenAmount(value, maxDecimals: 8)
    }

    /// Format token amount with correct decimal precision, strip trailing zeros.
    /// NEVER returns "0" or "0.00..." if value > 0 — shows at least 1 significant digit.
    private func formatTokenAmount(_ value: Double, maxDecimals: Int = 8) -> String {
        guard value != 0 else { return "0" }
        let s = String(format: "%.\(maxDecimals)f", value)
        if s.contains(".") {
            var trimmed = s
            while trimmed.hasSuffix("0") { trimmed.removeLast() }
            if trimmed.hasSuffix(".") { trimmed.removeLast() }
            // Safety: if trimming produced "0" but value > 0, show more precision
            if trimmed == "0" && value > 0 {
                return String(format: "%.8f", value).replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
            }
            return trimmed
        }
        return s
    }

    /// Truncate a decimal string to at most N decimal places (no rounding, just cut).
    /// Safety: if truncation would yield 0 but original > 0, return the original value
    /// so that a positive balance is never silently zeroed out.
    private func truncateDecimals(_ value: String, maxDecimals: Int) -> String {
        guard let dotIdx = value.firstIndex(of: ".") else { return value }
        let afterDot = value[value.index(after: dotIdx)...]
        if afterDot.count <= maxDecimals { return value }
        if maxDecimals == 0 {
            // Just the integer part
            let intPart = String(value[value.startIndex..<dotIdx])
            // Safety: if integer part is "0" but original > 0, return original
            if let orig = Double(value), orig > 0, (Double(intPart) ?? 0) == 0 {
                return value
            }
            return intPart
        }
        let endIdx = value.index(dotIdx, offsetBy: maxDecimals + 1)
        let truncated = String(value[value.startIndex..<endIdx])
        // Safety: never truncate a positive value to zero
        if let orig = Double(value), orig > 0, let trunc = Double(truncated), trunc == 0 {
            return value // preserve original precision — let the API validate
        }
        return truncated
    }

    private var amountLabel: String {
        if mode == .coreToEVM, let t = selectedToken { return "Amount (\(t.displayCoin))" }
        if mode == .evmToCore, let t = selectedEVMToken { return "Amount (\(t.displayCoin))" }
        if mode == .subAccount, let t = selectedSubToken { return "Amount (\(t.displayCoin))" }
        return "Amount"
    }

    private var canSubmit: Bool {
        guard !isSubmitting else { return false }
        guard let val = Double(stripCommas(amount)), val > 0 else { return false }
        if mode == .subAccount {
            guard selectedSubToken != nil,
                  sourceAccount != nil,
                  destAccount != nil,
                  sourceAccount?.address != destAccount?.address else { return false }
            return val <= availableBalance
        }
        let selected = mode == .coreToEVM ? selectedToken : selectedEVMToken
        guard selected != nil else { return false }
        return val <= availableBalance
    }

    private var disabledReason: String? {
        guard !isSubmitting else { return nil }
        if mode == .subAccount {
            if sourceAccount == nil { return "Select a source account" }
            if destAccount == nil { return "Select a destination account" }
            if sourceAccount?.address == destAccount?.address { return "Source and destination must be different" }
            if selectedSubToken == nil { return "Select a token" }
            guard !amount.isEmpty else { return nil }
            guard let val = Double(stripCommas(amount)), val > 0 else { return "Enter a valid amount" }
            if val > availableBalance {
                return "Insufficient balance (max: \(String(format: "%g", availableBalance)))"
            }
            return nil
        }
        guard !amount.isEmpty else { return nil }
        let selected = mode == .coreToEVM ? selectedToken : selectedEVMToken
        if selected == nil { return "Select a token" }
        guard let val = Double(stripCommas(amount)), val > 0 else { return "Enter a valid amount" }
        if val > availableBalance {
            return "Insufficient balance (max: \(String(format: "%g", availableBalance)))"
        }
        return nil
    }

    // MARK: - Balance fetch

    /// Pre-populate token list from WalletManager's already-loaded spot balances.
    /// This gives an instant first token when opening Transfer, before the full fetch completes.
    private func prefillFromCachedBalances() {
        guard spotTokens.isEmpty else { return } // don't overwrite if already loaded
        let wm = WalletManager.shared
        var prefilled: [SpotToken] = []
        for (coin, total) in wm.spotTokenBalances where total > 0 {
            let avail = wm.spotTokenAvailable[coin] ?? total
            let display = SpotToken.displayName(for: coin)
            // Use basic defaults — full metadata (tokenId, szDecimals, evmContract) will come from fetchBalances
            prefilled.append(SpotToken(coin: coin, displayCoin: display, token: coin,
                                       tokenIndex: -1, balance: total, available: avail, szDecimals: 8))
        }
        if !prefilled.isEmpty {
            // Sort by USD value descending — highest value token first
            spotTokens = prefilled.sorted { tokenUSDValue($0) > tokenUSDValue($1) }
            selectedToken = spotTokens.first
            didLoadTokens = true
            print("[TRANSFER] Pre-filled \(prefilled.count) tokens from WalletManager cache")
        }
    }

    /// Direct POST to Hyperliquid API (bypasses HyperliquidAPI.shared to avoid potential issues)
    private func hlPost(_ body: [String: Any]) async throws -> Data {
        let url = URL(string: "https://api.hyperliquid.xyz/info")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 15
        let (data, _) = try await URLSession.shared.data(for: req)
        return data
    }

    private func fetchBalances() async {
        guard let address = wallet.connectedWallet?.address else {
            print("[TRANSFER] No wallet address")
            debugInfo = "ERROR: No wallet address"
            didLoadTokens = true
            return
        }
        debugInfo = "Fetching for \(String(address.prefix(10)))..."

        // ── 1. Spot metadata (token IDs + EVM contracts) — cached in memory ──
        var tokenIdMap: [Int: String] = [:]
        var evmContractMap: [Int: String] = [:]      // idx → contract address
        var evmDecimalsMap: [Int: Int] = [:]          // idx → EVM decimals
        var szDecimalsMap: [Int: Int] = [:]            // idx → max decimal places for API
        var tokenNameByIndex: [Int: String] = [:]

        // Use cached metadata if available (< 5 min old)
        if let cached = SpotMetaCache.shared.get() {
            tokenIdMap = cached.tokenIdMap
            evmContractMap = cached.evmContractMap
            evmDecimalsMap = cached.evmDecimalsMap
            szDecimalsMap = cached.szDecimalsMap
            tokenNameByIndex = cached.tokenNameByIndex
            print("[TRANSFER] Using cached spotMeta (\(tokenIdMap.count) IDs)")
        } else {
        do {
            let data = try await hlPost(["type": "spotMetaAndAssetCtxs"])
            if let root = try? JSONSerialization.jsonObject(with: data) as? [Any],
               let metaDict = root.first as? [String: Any],
               let tokensRaw = metaDict["tokens"] as? [[String: Any]] {
                for (pos, t) in tokensRaw.enumerated() {
                    guard let name = t["name"] as? String else { continue }
                    tokenNameByIndex[pos] = name
                    if let tokenId = t["tokenId"] as? String {
                        tokenIdMap[pos] = "\(name):\(tokenId)"
                    }
                    // szDecimals — max decimal places the API accepts
                    let sz = (t["szDecimals"] as? Int) ?? (t["szDecimals"] as? NSNumber)?.intValue ?? 8
                    szDecimalsMap[pos] = sz
                    // EVM contract + decimals
                    let weiDecimals = (t["weiDecimals"] as? Int) ?? (t["weiDecimals"] as? NSNumber)?.intValue ?? 18
                    if let evmObj = t["evmContract"] as? [String: Any],
                       let addr = evmObj["address"] as? String {
                        evmContractMap[pos] = addr
                        let extraWei = (evmObj["evm_extra_wei_decimals"] as? Int)
                            ?? (evmObj["evm_extra_wei_decimals"] as? NSNumber)?.intValue
                            ?? (Int(evmObj["evm_extra_wei_decimals"] as? String ?? "") ?? 0)
                        evmDecimalsMap[pos] = weiDecimals + extraWei
                    } else if let addr = t["evmContract"] as? String, addr.hasPrefix("0x") {
                        evmContractMap[pos] = addr
                        evmDecimalsMap[pos] = weiDecimals
                    }
                }
                print("[TRANSFER] spotMeta: \(tokensRaw.count) tokens, \(tokenIdMap.count) IDs, \(evmContractMap.count) EVM contracts")
                // Log first 5 tokens for debug
                for i in 0..<min(5, tokensRaw.count) {
                    print("[TRANSFER]   token[\(i)]: \(tokensRaw[i])")
                }
                // Cache for next time
                SpotMetaCache.shared.save(tokenIdMap: tokenIdMap, evmContractMap: evmContractMap,
                                           evmDecimalsMap: evmDecimalsMap, szDecimalsMap: szDecimalsMap,
                                           tokenNameByIndex: tokenNameByIndex)
            }
        } catch {
            debugInfo += "\nMeta: \(error.localizedDescription)"
            print("[TRANSFER] spotMeta failed: \(error)")
        }
        } // end else (no cache)

        // ── 2. Spot balances (HyperCore) ──
        do {
            let data = try await hlPost(["type": "spotClearinghouseState", "user": address])
            let raw = String(data: data, encoding: .utf8) ?? "nil"
            print("[TRANSFER] spotState raw (first 500): \(String(raw.prefix(500)))")

            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let balances = json["balances"] as? [[String: Any]] {

                var tokens: [SpotToken] = []
                for b in balances {
                    guard let coin = b["coin"] as? String,
                          let totStr = b["total"] as? String,
                          let total = Double(totStr), total > 0
                    else { continue }


                    let tokenIdx: Int
                    if let idx = b["token"] as? Int {
                        tokenIdx = idx
                    } else if let n = b["token"] as? NSNumber {
                        tokenIdx = n.intValue
                    } else {
                        tokenIdx = -1
                    }

                    let rawTokenId = tokenIdMap[tokenIdx] ?? ""
                    // spotSend API requires "COIN:TOKEN_ID" format
                    // rawTokenId may already be "COIN:0xhex" — don't double-prefix
                    let tokenForAPI: String
                    if rawTokenId.isEmpty {
                        tokenForAPI = coin
                    } else if rawTokenId.contains(":") {
                        tokenForAPI = rawTokenId  // already "COIN:0xhex"
                    } else {
                        tokenForAPI = "\(coin):\(rawTokenId)"
                    }
                    let hold = Double(b["hold"] as? String ?? "0") ?? 0
                    let avail = max(0, total - hold)
                    let display = SpotToken.displayName(for: coin)
                    let sz = szDecimalsMap[tokenIdx] ?? 8
                    tokens.append(SpotToken(coin: coin, displayCoin: display, token: tokenForAPI, tokenIndex: tokenIdx, balance: total, available: avail, szDecimals: sz))
                    print("[TRANSFER] Core: \(display) (\(coin)) = \(total), avail=\(avail), hold=\(hold), idx=\(tokenIdx), szDec=\(sz)")
                }
                spotTokens = tokens.sorted { tokenUSDValue($0) > tokenUSDValue($1) }
                // Always re-select the highest USD value token when fresh data arrives
                // (prefill may have picked wrong token due to missing prices)
                selectedToken = spotTokens.first
                print("[TRANSFER] Found \(spotTokens.count) Core tokens")
            }
        } catch {
            debugInfo += "\nSpot: \(error.localizedDescription)"
            print("[TRANSFER] spot balances failed: \(error)")
        }

        // Core tokens are ready — unblock UI immediately so the token picker is usable.
        // EVM balances load below and update evmTokens when done (only needed for EVM→Core mode).
        didLoadTokens = true

        // ── 3. EVM balances ──
        var evmList: [SpotToken] = []

        // Native HYPE
        do {
            let bal = try await HyperEVMRPC.shared.getBalance(address: address)
            print("[TRANSFER] EVM native HYPE: \(bal)")
            if bal > 0.0001 {
                // HYPE szDecimals = 2 on Hyperliquid, look up from meta or default to 2
                let hypeSzDec = tokenNameByIndex.first(where: { $0.value == "HYPE" }).flatMap { szDecimalsMap[$0.key] } ?? 2
                evmList.append(SpotToken(coin: "HYPE", displayCoin: "HYPE", token: "HYPE", tokenIndex: -1, balance: bal, available: bal, szDecimals: hypeSzDec))
            }
        } catch {
            debugInfo += "\nEVM: \(error.localizedDescription)"
            print("[TRANSFER] EVM HYPE failed: \(error)")
        }

        // ERC20 tokens — check tokens the user has on Core + major tokens + always check USDC
        // Known override contracts: some tokens (notably USDC) have spotMeta evmContract
        // pointing to a deprecated proxy. These are the actual working ERC20 addresses on HyperEVM.
        let knownEVMContracts: [String: (address: String, decimals: Int)] = [
            "USDC": ("0xb88339cb7199b77e23db6e890353e22632ba630f", 6),  // Circle native USDC
        ]

        let coreTokenIndices = Set(spotTokens.map { $0.tokenIndex })
        let majorTokenNames: Set<String> = ["USDC", "PURR", "HYPE", "HFUN", "JEFF", "UBTC", "UETH", "USOL",
                                             "UFART", "UPUMP", "HPENGU", "UBONK", "UENA", "USDT0", "USDH", "USDE"]
        let tokensToCheck = evmContractMap.filter { idx, _ in
            coreTokenIndices.contains(idx) ||
            (tokenNameByIndex[idx].map { majorTokenNames.contains($0) } ?? false)
        }

        // Also ensure known tokens are always checked even if not in evmContractMap
        // Check by token NAME (not contract address) to avoid duplicates when we override the contract
        let namesAlreadyInCheck = Set(tokensToCheck.keys.compactMap { tokenNameByIndex[$0] })
        var extraTokensToCheck: [(name: String, contract: String, decimals: Int, idx: Int)] = []
        for (name, info) in knownEVMContracts {
            if !namesAlreadyInCheck.contains(name) {
                // Find the token index for this name
                let idx = tokenNameByIndex.first(where: { $0.value == name })?.key ?? -1
                extraTokensToCheck.append((name: name, contract: info.address, decimals: info.decimals, idx: idx))
                print("[TRANSFER] Adding known override for \(name) → \(info.address) (not in spotMeta filter)")
            }
        }

        // Log which tokens we're checking
        for (idx, contract) in tokensToCheck {
            let name = tokenNameByIndex[idx] ?? "?"
            let override = knownEVMContracts[name]
            if let ov = override {
                print("[TRANSFER] Will check EVM[\(idx)] \(name) → \(ov.address) (override, spotMeta was \(contract))")
            } else {
                print("[TRANSFER] Will check EVM[\(idx)] \(name) → \(contract)")
            }
        }
        print("[TRANSFER] Checking \(tokensToCheck.count)+\(extraTokensToCheck.count) EVM tokens (of \(evmContractMap.count) total, coreTokens=\(coreTokenIndices.count))")

        // Check in parallel for speed
        await withTaskGroup(of: SpotToken?.self) { group in
            for (idx, contract) in tokensToCheck {
                guard let name = tokenNameByIndex[idx] else { continue }
                // Use known override contract if available (e.g. Circle USDC instead of broken spotMeta proxy)
                let actualContract: String
                let decimals: Int
                if let override = knownEVMContracts[name] {
                    actualContract = override.address
                    decimals = override.decimals
                } else {
                    actualContract = contract
                    decimals = evmDecimalsMap[idx] ?? 18
                }
                let capturedIdx = idx
                let sz = szDecimalsMap[idx] ?? 8
                group.addTask {
                    guard let bal = try? await HyperEVMRPC.shared.getERC20Balance(
                        address: address, tokenContract: actualContract, decimals: decimals),
                          bal > 0.0001 else { return nil }
                    let display = SpotToken.displayName(for: name)
                    return SpotToken(coin: name, displayCoin: display, token: actualContract,
                                     tokenIndex: capturedIdx, balance: bal, available: bal, szDecimals: sz, evmDecimals: decimals)
                }
            }
            // Also check extra known tokens not in the filter
            for extra in extraTokensToCheck {
                let sz = szDecimalsMap[extra.idx] ?? 8
                group.addTask {
                    guard let bal = try? await HyperEVMRPC.shared.getERC20Balance(
                        address: address, tokenContract: extra.contract, decimals: extra.decimals),
                          bal > 0.0001 else { return nil }
                    let display = SpotToken.displayName(for: extra.name)
                    return SpotToken(coin: extra.name, displayCoin: display, token: extra.contract,
                                     tokenIndex: extra.idx, balance: bal, available: bal, szDecimals: sz, evmDecimals: extra.decimals)
                }
            }
            for await result in group {
                if let token = result {
                    evmList.append(token)
                    print("[TRANSFER] EVM ERC20 \(token.displayCoin): \(token.balance) (contract: \(token.token))")
                }
            }
        }

        evmTokens = evmList.sorted { tokenUSDValue($0) > tokenUSDValue($1) }
        if let sel = selectedEVMToken, let updated = evmTokens.first(where: { $0.coin == sel.coin }) {
            selectedEVMToken = updated
        } else {
            selectedEVMToken = evmTokens.first
        }
        print("[TRANSFER] Found \(evmTokens.count) EVM tokens")

        debugInfo += "\nCore: \(spotTokens.count) tokens, EVM: \(evmTokens.count) tokens"
        debugInfo += "\nMeta: \(tokenIdMap.count) IDs, \(evmContractMap.count) EVM contracts"
    }

    /// Compute the HyperEVM bridge system address for a token.
    /// HYPE → 0x2222...2222
    /// Others → 0x20 + zeros + token_index_big_endian (20 bytes total)
    private func bridgeAddress(for token: SpotToken) -> String {
        if token.coin == "HYPE" {
            return "0x2222222222222222222222222222222222222222"
        }
        // For USDC and other tokens with known indices
        if token.tokenIndex >= 0 {
            let hex = String(token.tokenIndex, radix: 16)
            let padded = String(repeating: "0", count: max(0, 38 - hex.count)) + hex
            return "0x20" + padded
        }
        // Fallback: USDC bridge address (index 0)
        return "0x2000000000000000000000000000000000000000"
    }

    // MARK: - Submit

    private func submitTransfer() async {
        isSubmitting = true
        resultMessage = nil

        do {
            let rawAmount = stripCommas(amount)
            let payload: [String: Any]

            switch mode {
            case .coreToEVM:
                guard let token = selectedToken else { throw SignerError.signingFailed("No token selected") }
                let bridge = bridgeAddress(for: token)
                // Transfer precision (8 dec) is independent of trading precision (szDecimals)
                let cleanAmount = truncateDecimals(rawAmount, maxDecimals: SpotToken.transferDecimals)
                guard let amtVal = Double(cleanAmount), amtVal > 0 else {
                    throw SignerError.signingFailed("Amount must be greater than zero")
                }
                print("[TRANSFER] Core→EVM: dest=\(bridge) token=\(token.token) amount=\(cleanAmount) coin=\(token.coin) idx=\(token.tokenIndex)")
                payload = try await TransactionSigner.signSpotSend(
                    destination: bridge,
                    token: token.token,
                    amount: cleanAmount
                )
                print("[TRANSFER] Payload action: \(payload["action"] ?? "nil")")
            case .evmToCore:
                guard let evmToken = selectedEVMToken else {
                    throw SignerError.signingFailed("No token selected")
                }
                guard await WalletManager.shared.authenticateForTransaction(),
                      let pk = WalletManager.shared.loadPrivateKey(),
                      let addr = wallet.connectedWallet?.address else {
                    throw SignerError.signingFailed("Authentication failed")
                }
                // Truncate to EVM-appropriate decimals
                let cleanAmount = truncateDecimals(rawAmount, maxDecimals: evmToken.evmDecimals)
                guard let amountDouble = Double(cleanAmount), amountDouble > 0 else {
                    throw SignerError.signingFailed("Invalid amount")
                }

                let txHash: String
                if evmToken.coin == "HYPE" {
                    // Native HYPE → send value to 0x2222...
                    txHash = try await HyperEVMRPC.shared.transferHYPEToCore(
                        amountHYPE: amountDouble, walletAddress: addr, privateKey: pk
                    )
                } else if evmToken.coin == "USDC" {
                    // USDC uses approve + deposit on CoreDepositWallet (not simple transfer)
                    txHash = try await HyperEVMRPC.shared.transferUSDCToCore(
                        amount: amountDouble, walletAddress: addr, privateKey: pk, toSpot: true
                    )
                } else {
                    // Other ERC20s → call transfer(systemAddress, amount) on the contract
                    let systemAddr = bridgeAddress(for: evmToken)
                    txHash = try await HyperEVMRPC.shared.transferERC20ToCore(
                        tokenContract: evmToken.token,
                        amount: amountDouble,
                        systemAddress: systemAddr,
                        walletAddress: addr,
                        privateKey: pk,
                        decimals: evmToken.evmDecimals
                    )
                }
                isSuccess = true
                resultMessage = "Transfer sent! Tx: \(String(txHash.prefix(18)))..."
                amount = ""
                isSubmitting = false
                // Multiple retries: EVM↔Core bridge can take a few seconds
                Task { await refreshWithRetries() }
                return

            case .subAccount:
                guard let token = selectedSubToken else { throw SignerError.signingFailed("No token selected") }
                guard let src = sourceAccount, let dst = destAccount else {
                    throw SignerError.signingFailed("Select source and destination accounts")
                }
                guard src.address != dst.address else {
                    throw SignerError.signingFailed("Source and destination must be different")
                }
                // Transfer precision (8 dec) is independent of trading precision (szDecimals)
                let cleanAmount = truncateDecimals(rawAmount, maxDecimals: SpotToken.transferDecimals)
                guard let amtVal = Double(cleanAmount), amtVal > 0 else {
                    throw SignerError.signingFailed("Amount must be greater than zero")
                }

                // sendAsset: works in all account modes (classic, unified, PM).
                // fromSubAccount = source sub-account address, or "" for master.
                // destination = target address (master or sub-account).
                let fromSub = src.isMaster ? "" : src.address
                print("[TRANSFER] sendAsset: from=\(src.name)(\(fromSub.isEmpty ? "master" : String(fromSub.prefix(10)))) → dest=\(dst.name)(\(String(dst.address.prefix(10)))) token=\(token.token) amount=\(cleanAmount)")
                payload = try await TransactionSigner.signSendAsset(
                    destination: dst.address,
                    token: token.token,
                    amount: cleanAmount,
                    fromSubAccount: fromSub
                )
            }

            let response = try await TransactionSigner.postAction(payload)
            print("[TRANSFER] API response: \(response)")
            if mode == .subAccount {
                print("[TRANSFER] ━━━ API RESPONSE DEBUG ━━━")
                print("[TRANSFER] status: \(response["status"] ?? "nil")")
                print("[TRANSFER] response: \(response["response"] ?? "nil")")
                print("[TRANSFER] error: \(response["error"] ?? "nil")")
                print("[TRANSFER] full: \(response)")
                print("[TRANSFER] ━━�� END API RESPONSE DEBUG ━━━")
            }

            if let status = response["status"] as? String, status == "ok" {
                isSuccess = true
                resultMessage = "Transfer successful!"
                amount = ""

                // Fire-and-forget refresh — don't block the UI
                // Immediate refresh so Home/Wallet/Trade see updated balance
                Task { await WalletManager.shared.refreshAccountState() }

                // Delayed follow-up refresh for chain settlement
                Task {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    await WalletManager.shared.refreshAccountState()
                }

                if mode == .subAccount, let src = sourceAccount {
                    // Also refresh the sub-account token list shown in Transfer
                    Task {
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        await fetchSubSpotBalances(for: src.address)
                    }
                } else {
                    Task { await refreshWithRetries() }
                }
            } else {
                isSuccess = false
                if let err = response["response"] as? String {
                    resultMessage = err
                } else if let err = response["error"] as? String {
                    resultMessage = err
                } else {
                    resultMessage = "Transfer failed: \(response)"
                }
            }
        } catch {
            isSuccess = false
            resultMessage = error.localizedDescription
            if mode == .subAccount {
                print("[TRANSFER] ━━━ EXCEPTION DEBUG ━━━")
                print("[TRANSFER] error type: \(type(of: error))")
                print("[TRANSFER] error: \(error)")
                print("[TRANSFER] localizedDescription: \(error.localizedDescription)")
                print("[TRANSFER] ━━━ END EXCEPTION DEBUG ━━━")
            }
        }

        isSubmitting = false
    }

    /// Refresh balances multiple times with increasing delays to catch bridge settlement.
    private func refreshWithRetries() async {
        // Retry at 2s, 5s, 10s — bridges can take a few seconds
        for delay in [2.0, 5.0, 10.0] {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            await fetchBalances()
            // Also refresh global state so Trade / Home / Wallet update
            await WalletManager.shared.refreshAccountState()
        }
    }

    // MARK: - Sub-account fetch

    /// Resolve the master wallet address (derived from private key).
    /// When inside a sub-account, connectedWallet.address is the sub-account — not the master.
    private var masterWalletAddress: String? {
        guard let keyData = WalletManager.shared.loadPrivateKey(),
              let derived = WalletManager.deriveAddress(from: keyData) else {
            return wallet.connectedWallet?.address  // fallback
        }
        return derived
    }

    private func fetchSubAccounts() async {
        guard let masterAddr = masterWalletAddress else { return }
        isLoadingSubs = true

        // Instantly show cached sub-accounts while fetching fresh data
        if let cached = SubAccountCache.shared.get(for: masterAddr), subAccounts.isEmpty {
            subAccounts = cached
            if sourceAccount == nil {
                let currentAddr = wallet.connectedWallet?.address.lowercased()
                sourceAccount = cached.first(where: { $0.address.lowercased() == currentAddr }) ?? cached.first
            }
            // Auto-select destination if not set
            if destAccount == nil, let src = sourceAccount {
                destAccount = subAccounts.first(where: { $0.address != src.address })
            }
            // Start loading source tokens immediately from cache
            if let src = sourceAccount {
                Task { await fetchSubSpotBalances(for: src.address) }
            }
        }

        defer { isLoadingSubs = false }

        do {
            let data = try await hlPost(["type": "subAccounts", "user": masterAddr])
            guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                print("[TRANSFER] subAccounts: unexpected response")
                return
            }

            var entries: [SubAccountEntry] = []
            // Always include master as first entry
            entries.append(SubAccountEntry(name: "Master", address: masterAddr, isMaster: true))

            for item in arr {
                guard let name = item["name"] as? String,
                      let subAddr = item["subAccountUser"] as? String else { continue }
                entries.append(SubAccountEntry(name: name, address: subAddr, isMaster: false))
            }

            subAccounts = entries
            SubAccountCache.shared.save(entries, for: masterAddr)
            print("[TRANSFER] Found \(entries.count) accounts (\(entries.count - 1) subs)")

            // Auto-select: pre-select the currently active account as source
            if sourceAccount == nil {
                let currentAddr = wallet.connectedWallet?.address.lowercased()
                sourceAccount = entries.first(where: { $0.address.lowercased() == currentAddr }) ?? entries.first
            }
            // Auto-select destination if not set
            if destAccount == nil, let src = sourceAccount {
                destAccount = entries.first(where: { $0.address != src.address })
            }
            // Fetch balances for source
            if let src = sourceAccount, subSpotTokens.isEmpty {
                await fetchSubSpotBalances(for: src.address)
            }
        } catch {
            print("[TRANSFER] fetchSubAccounts failed: \(error)")
        }
    }

    private func fetchSubSpotBalances(for accountAddress: String) async {
        subSpotTokens = []
        selectedSubToken = nil

        // Ensure spotMeta is cached
        var tokenIdMap: [Int: String] = [:]
        var szDecimalsMap: [Int: Int] = [:]
        var tokenNameByIndex: [Int: String] = [:]

        if let cached = SpotMetaCache.shared.get() {
            tokenIdMap = cached.tokenIdMap
            szDecimalsMap = cached.szDecimalsMap
            tokenNameByIndex = cached.tokenNameByIndex
        } else {
            // Fetch spotMeta
            do {
                let data = try await hlPost(["type": "spotMetaAndAssetCtxs"])
                if let root = try? JSONSerialization.jsonObject(with: data) as? [Any],
                   let metaDict = root.first as? [String: Any],
                   let tokensRaw = metaDict["tokens"] as? [[String: Any]] {
                    var evmContractMap: [Int: String] = [:]
                    var evmDecimalsMap: [Int: Int] = [:]
                    for (pos, t) in tokensRaw.enumerated() {
                        guard let name = t["name"] as? String else { continue }
                        tokenNameByIndex[pos] = name
                        if let tokenId = t["tokenId"] as? String {
                            tokenIdMap[pos] = "\(name):\(tokenId)"
                        }
                        let sz = (t["szDecimals"] as? Int) ?? (t["szDecimals"] as? NSNumber)?.intValue ?? 8
                        szDecimalsMap[pos] = sz
                        let weiDecimals = (t["weiDecimals"] as? Int) ?? 18
                        if let evmObj = t["evmContract"] as? [String: Any],
                           let addr = evmObj["address"] as? String {
                            evmContractMap[pos] = addr
                            let extraWei = (evmObj["evm_extra_wei_decimals"] as? Int) ?? 0
                            evmDecimalsMap[pos] = weiDecimals + extraWei
                        }
                    }
                    SpotMetaCache.shared.save(tokenIdMap: tokenIdMap, evmContractMap: evmContractMap,
                                               evmDecimalsMap: evmDecimalsMap, szDecimalsMap: szDecimalsMap,
                                               tokenNameByIndex: tokenNameByIndex)
                }
            } catch {
                print("[TRANSFER] spotMeta fetch failed in sub-balance: \(error)")
            }
        }

        // Fetch spot balances for this account
        do {
            let data = try await hlPost(["type": "spotClearinghouseState", "user": accountAddress])
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let balances = json["balances"] as? [[String: Any]] {

                var tokens: [SpotToken] = []
                for b in balances {
                    guard let coin = b["coin"] as? String,
                          let totStr = b["total"] as? String,
                          let total = Double(totStr), total > 0 else { continue }

                    let tokenIdx: Int
                    if let idx = b["token"] as? Int { tokenIdx = idx }
                    else if let n = b["token"] as? NSNumber { tokenIdx = n.intValue }
                    else { tokenIdx = -1 }

                    let rawTokenId = tokenIdMap[tokenIdx] ?? ""
                    let tokenForAPI: String
                    if rawTokenId.isEmpty { tokenForAPI = coin }
                    else if rawTokenId.contains(":") { tokenForAPI = rawTokenId }
                    else { tokenForAPI = "\(coin):\(rawTokenId)" }

                    let hold = Double(b["hold"] as? String ?? "0") ?? 0
                    let avail = max(0, total - hold)
                    let display = SpotToken.displayName(for: coin)
                    let sz = szDecimalsMap[tokenIdx] ?? 8
                    tokens.append(SpotToken(coin: coin, displayCoin: display, token: tokenForAPI,
                                            tokenIndex: tokenIdx, balance: total, available: avail, szDecimals: sz))
                }
                subSpotTokens = tokens.sorted { tokenUSDValue($0) > tokenUSDValue($1) }
                // Auto-select highest USD value token
                if selectedSubToken == nil {
                    selectedSubToken = subSpotTokens.first
                }
                print("[TRANSFER] Sub-account \(String(accountAddress.prefix(10))): \(tokens.count) spot tokens")
            }
        } catch {
            print("[TRANSFER] fetchSubSpotBalances failed: \(error)")
        }
    }

    // MARK: - Helpers

    private func infoRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
                .foregroundColor(Color(white: 0.5))
            Spacer()
            Text(value)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
        }
    }
}
