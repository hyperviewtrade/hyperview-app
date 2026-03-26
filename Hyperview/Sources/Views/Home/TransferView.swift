import SwiftUI

// MARK: - Transfer Modes

enum TransferMode: String, CaseIterable {
    case coreToEVM   = "Core → EVM"
    case evmToCore   = "EVM → Core"
}

// MARK: - Spot token for Core→EVM

private struct SpotToken: Identifiable {
    let id = UUID()
    let coin: String        // raw API coin name ("USOL", "HYPE", etc.)
    let displayCoin: String // human-readable name ("SOL", "HYPE", etc.)
    let token: String       // token identifier for API calls
    let tokenIndex: Int     // index in tokens array for bridge address
    let balance: Double
    var szDecimals: Int = 8    // Max decimal places accepted by Hyperliquid API (from spotMeta)
    var evmDecimals: Int = 18  // EVM decimals for this token (weiDecimals + evm_extra_wei_decimals)

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
                        // Refresh balances when switching modes (EVM tokens may have changed)
                        Task { await fetchBalances() }
                    }

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
                    VStack(alignment: .leading, spacing: 8) {
                        Text(amountLabel)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(Color(white: 0.5))

                        HStack(spacing: 10) {
                            TextField("0.00", text: $amount)
                                .keyboardType(.decimalPad)
                                .font(.system(size: 20, weight: .bold, design: .monospaced))
                                .foregroundColor(.white)
                                .onChange(of: amount) { oldValue, newValue in
                                    guard formatDecimalWithCommas(newValue) != newValue else { return }
                                    let formatted = formatDecimalOnChange(oldValue: oldValue, newValue: newValue)
                                    if formatted != newValue { amount = formatted }
                                }

                            Button("Max") {
                                let max = availableBalance
                                let selected = mode == .coreToEVM ? selectedToken : selectedEVMToken
                                let maxDec = selected?.szDecimals ?? 8
                                if max > 0 { amount = formatTokenAmount(max, maxDecimals: maxDec) }
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
                    }
                    .padding(.horizontal, 16)

                    // Info text
                    if mode == .coreToEVM {
                        HStack(spacing: 8) {
                            Image(systemName: "info.circle")
                                .foregroundColor(.hlGreen)
                            Text("Transfers tokens from Hypercore to your HyperEVM address. ~2s settlement. HYPE arrives as native gas token.")
                                .font(.system(size: 12))
                                .foregroundColor(Color(white: 0.5))
                        }
                        .padding(.horizontal, 20)
                    }

                    if mode == .evmToCore {
                        HStack(spacing: 8) {
                            Image(systemName: "info.circle")
                                .foregroundColor(.hlGreen)
                            Text("Transfers HYPE from HyperEVM back to Hypercore. Useful after CEX deposits that arrive on EVM.")
                                .font(.system(size: 12))
                                .foregroundColor(Color(white: 0.5))
                        }
                        .padding(.horizontal, 20)
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
            .task { await fetchBalances() }
        }
    }

    // MARK: - Token picker sheet

    private func tokenPickerSheet(tokens: [SpotToken], selected: String?, onSelect: @escaping (SpotToken) -> Void) -> some View {
        NavigationStack {
            List {
                if tokens.isEmpty {
                    Text("No tokens found")
                        .foregroundColor(Color(white: 0.5))
                        .listRowBackground(Color.hlBackground)
                } else {
                    ForEach(tokens) { t in
                        Button {
                            onSelect(t)
                        } label: {
                            HStack(spacing: 12) {
                                CoinIconView(symbol: t.displayCoin, hlIconName: t.displayCoin, iconSize: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(t.displayCoin)
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundColor(.white)
                                    Text(formatTokenAmount(t.balance, maxDecimals: t.szDecimals))
                                        .font(.system(size: 11))
                                        .foregroundColor(Color(white: 0.4))
                                }
                                Spacer()
                                if selected == t.coin {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.hlGreen)
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
                        if mode == .coreToEVM { showTokenPicker = false }
                        else { showEVMTokenPicker = false }
                    }
                    .foregroundColor(.hlGreen)
                }
            }
        }
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
                            Text("\(formatTokenAmount(t.balance, maxDecimals: t.szDecimals)) available")
                                .font(.system(size: 11))
                                .foregroundColor(Color(white: 0.4))
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
        mode == .coreToEVM ? "Hypercore" : "HyperEVM"
    }

    private var toLabel: String {
        mode == .coreToEVM ? "HyperEVM" : "Hypercore"
    }

    private var availableBalance: Double {
        mode == .coreToEVM ? (selectedToken?.balance ?? 0) : (selectedEVMToken?.balance ?? 0)
    }

    private var availableBalanceFormatted: String {
        if mode == .coreToEVM {
            if let t = selectedToken {
                return "\(formatTokenAmount(t.balance, maxDecimals: t.szDecimals)) \(t.displayCoin)"
            }
        } else {
            if let t = selectedEVMToken {
                return "\(formatTokenAmount(t.balance, maxDecimals: t.szDecimals)) \(t.displayCoin)"
            }
        }
        return "Select a token"
    }

    /// Format token amount with correct decimal precision, strip trailing zeros
    private func formatTokenAmount(_ value: Double, maxDecimals: Int = 8) -> String {
        let s = String(format: "%.\(maxDecimals)f", value)
        if s.contains(".") {
            var trimmed = s
            while trimmed.hasSuffix("0") { trimmed.removeLast() }
            if trimmed.hasSuffix(".") { trimmed.removeLast() }
            return trimmed
        }
        return s
    }

    /// Truncate a decimal string to at most N decimal places (no rounding, just cut)
    private func truncateDecimals(_ value: String, maxDecimals: Int) -> String {
        guard let dotIdx = value.firstIndex(of: ".") else { return value }
        let afterDot = value[value.index(after: dotIdx)...]
        if afterDot.count <= maxDecimals { return value }
        let endIdx = value.index(dotIdx, offsetBy: maxDecimals + 1)
        return String(value[value.startIndex..<endIdx])
    }

    private var amountLabel: String {
        if mode == .coreToEVM, let t = selectedToken { return "Amount (\(t.displayCoin))" }
        if mode == .evmToCore, let t = selectedEVMToken { return "Amount (\(t.displayCoin))" }
        return "Amount"
    }

    private var canSubmit: Bool {
        guard !isSubmitting else { return false }
        guard let val = Double(stripCommas(amount)), val > 0 else { return false }
        let selected = mode == .coreToEVM ? selectedToken : selectedEVMToken
        guard selected != nil else { return false }
        return val <= availableBalance
    }

    private var disabledReason: String? {
        guard !isSubmitting else { return nil }
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
                    let display = SpotToken.displayName(for: coin)
                    let sz = szDecimalsMap[tokenIdx] ?? 8
                    tokens.append(SpotToken(coin: coin, displayCoin: display, token: tokenForAPI, tokenIndex: tokenIdx, balance: total, szDecimals: sz))
                    print("[TRANSFER] Core: \(display) (\(coin)) = \(total), idx=\(tokenIdx), szDec=\(sz)")
                }
                spotTokens = tokens.sorted { $0.balance > $1.balance }
                if let sel = selectedToken, let updated = spotTokens.first(where: { $0.coin == sel.coin }) {
                    selectedToken = updated
                } else {
                    selectedToken = spotTokens.first { $0.coin == "HYPE" } ?? spotTokens.first
                }
                print("[TRANSFER] Found \(spotTokens.count) Core tokens")
            }
        } catch {
            debugInfo += "\nSpot: \(error.localizedDescription)"
            print("[TRANSFER] spot balances failed: \(error)")
        }

        // ── 3. EVM balances ──
        var evmList: [SpotToken] = []

        // Native HYPE
        do {
            let bal = try await HyperEVMRPC.shared.getBalance(address: address)
            print("[TRANSFER] EVM native HYPE: \(bal)")
            if bal > 0.0001 {
                // HYPE szDecimals = 2 on Hyperliquid, look up from meta or default to 2
                let hypeSzDec = tokenNameByIndex.first(where: { $0.value == "HYPE" }).flatMap { szDecimalsMap[$0.key] } ?? 2
                evmList.append(SpotToken(coin: "HYPE", displayCoin: "HYPE", token: "HYPE", tokenIndex: -1, balance: bal, szDecimals: hypeSzDec))
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
                                     tokenIndex: capturedIdx, balance: bal, szDecimals: sz, evmDecimals: decimals)
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
                                     tokenIndex: extra.idx, balance: bal, szDecimals: sz, evmDecimals: extra.decimals)
                }
            }
            for await result in group {
                if let token = result {
                    evmList.append(token)
                    print("[TRANSFER] EVM ERC20 \(token.displayCoin): \(token.balance) (contract: \(token.token))")
                }
            }
        }

        evmTokens = evmList.sorted { $0.balance > $1.balance }
        if let sel = selectedEVMToken, let updated = evmTokens.first(where: { $0.coin == sel.coin }) {
            selectedEVMToken = updated
        } else {
            selectedEVMToken = evmTokens.first
        }
        print("[TRANSFER] Found \(evmTokens.count) EVM tokens")

        debugInfo += "\nCore: \(spotTokens.count) tokens, EVM: \(evmTokens.count) tokens"
        debugInfo += "\nMeta: \(tokenIdMap.count) IDs, \(evmContractMap.count) EVM contracts"
        didLoadTokens = true
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
                // Truncate to szDecimals — Hyperliquid API rejects amounts with too many decimal places
                let cleanAmount = truncateDecimals(rawAmount, maxDecimals: token.szDecimals)
                print("[TRANSFER] Core→EVM: dest=\(bridge) token=\(token.token) amount=\(cleanAmount) (szDec=\(token.szDecimals)) coin=\(token.coin) idx=\(token.tokenIndex)")
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
            }

            let response = try await TransactionSigner.postAction(payload)
            print("[TRANSFER] API response: \(response)")

            if let status = response["status"] as? String, status == "ok" {
                isSuccess = true
                resultMessage = "Transfer successful!"
                amount = ""
                // Multiple retries for Core transfers too
                Task { await refreshWithRetries() }
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
        }

        isSubmitting = false
    }

    /// Refresh balances multiple times with increasing delays to catch bridge settlement.
    private func refreshWithRetries() async {
        // Retry at 2s, 5s, 10s — bridges can take a few seconds
        for delay in [2.0, 5.0, 10.0] {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            await fetchBalances()
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
