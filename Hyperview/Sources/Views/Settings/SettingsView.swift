import SwiftUI

struct SettingsView: View {
    @AppStorage("hl_defaultInterval") private var defaultInterval = "1h"
    @AppStorage("hl_haptics")         private var hapticsOn        = true
    @AppStorage("hl_slippage")        private var slippage: Double  = 0.1

    @AppStorage("hl_phantomAddress") private var phantomAddress = ""

    @ObservedObject private var walletMgr = WalletManager.shared
    @ObservedObject private var notifMgr  = NotificationManager.shared

    @State private var showWalletConnect = false
    @State private var showAlerts        = false
    @State private var alerts            = PriceAlert.all
    @State private var phantomInput      = ""
    @State private var globalAliases: [String: String] = [:]
    @State private var allAliases: [String: String] = [:]
    @State private var feeDiscount: String = "–"
    @State private var stakingTierLabel: String = "–"
    @State private var showPrivateKey = false
    @State private var revealedKey: String?
    @State private var keyCopied = false
    @State private var showImportKey = false
    @State private var importKeyInput = ""
    @State private var importError: String?
    @State private var importSuccess = false
    private var savedWalletKeys: [String] {
        (UserDefaults.standard.stringArray(forKey: "hl_saved_wallet_keys") ?? [])
    }

    // Sub-accounts
    @State private var subAccounts: [SubAccountInfo] = []
    @State private var isLoadingSubAccounts = false
    @State private var showCreateSubAccount = false
    @State private var newSubAccountName = ""
    @State private var createSubError: String?
    @State private var isCreatingSubAccount = false
    @State private var activeSubAccount: String? // nil = master
    @State private var masterAddress: String?

    struct SubAccountInfo {
        let name: String
        let address: String
        let balance: String
        let isPortfolioMargin: Bool
    }
    @FocusState private var phantomFieldFocused: Bool

    private static let recentPhantomKey = "hl_recentPhantomAddresses"

    var body: some View {
        List {

            // MARK: - Phantom
            Section {
                if phantomAddress.isEmpty {
                    // Input mode
                    HStack(spacing: 10) {
                        TextField("0x… or alias", text: $phantomInput)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(.white)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .focused($phantomFieldFocused)
                            .submitLabel(.done)
                            .onSubmit {
                                setPhantom(phantomInput)
                            }
                            .overlay(alignment: .trailing) {
                                if !phantomInput.isEmpty {
                                    Button { phantomInput = "" } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.system(size: 14))
                                            .foregroundColor(Color(white: 0.4))
                                    }
                                }
                            }

                        Button {
                            if let pasted = UIPasteboard.general.string {
                                phantomInput = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
                            }
                        } label: {
                            Image(systemName: "doc.on.clipboard")
                                .font(.system(size: 14))
                                .foregroundColor(.hlGreen)
                        }

                        Button {
                            setPhantom(phantomInput)
                        } label: {
                            Text("Set")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.black)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color.hlGreen)
                                .cornerRadius(6)
                        }
                    }

                    // ── Alias suggestions ──────────────────────────
                    if phantomFieldFocused {
                        let suggestions = phantomAliasSuggestions
                        if !suggestions.isEmpty {
                            ForEach(suggestions, id: \.address) { suggestion in
                                Button {
                                    phantomFieldFocused = false
                                    setPhantom(suggestion.address)
                                } label: {
                                    HStack(spacing: 8) {
                                        Text(suggestion.name)
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundColor(.hlGreen)
                                        Spacer()
                                        Text(shortAddress(suggestion.address))
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundColor(Color(white: 0.4))
                                    }
                                }
                            }
                        }
                    }

                    // Recent addresses — each in its own row for reliable tap targets
                    let recents = recentPhantomAddresses
                    if !recents.isEmpty && !phantomFieldFocused {
                        Text("Recent")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Color(white: 0.4))
                            .listRowSeparator(.hidden)

                        ForEach(recents, id: \.self) { addr in
                            Button {
                                setPhantom(addr)
                            } label: {
                                HStack(spacing: 8) {
                                    Text(aliasFor(addr) ?? shortAddress(addr))
                                        .font(.system(size: 13, weight: .medium, design: aliasFor(addr) != nil ? .default : .monospaced))
                                        .foregroundColor(.white)
                                    if aliasFor(addr) != nil {
                                        Text(shortAddress(addr))
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundColor(Color(white: 0.35))
                                    }
                                    Spacer()
                                    Image(systemName: "arrow.right.circle")
                                        .font(.system(size: 12))
                                        .foregroundColor(Color(white: 0.3))
                                }
                            }
                        }
                    }
                } else {
                    // Connected phantom
                    HStack(spacing: 10) {
                        Image(systemName: "eye.fill")
                            .foregroundColor(.hlGreen)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            if let alias = aliasFor(phantomAddress) {
                                Text(alias)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(.white)
                                Text(shortPhantomAddress)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.gray)
                            } else {
                                Text(shortPhantomAddress)
                                    .font(.system(size: 14, design: .monospaced))
                                    .foregroundColor(.white)
                            }
                            Text("Viewing as this wallet")
                                .font(.system(size: 11))
                                .foregroundColor(.gray)
                        }
                        Spacer()
                    }

                    Button(role: .destructive) {
                        phantomAddress = ""
                    } label: {
                        HStack {
                            Image(systemName: "xmark.circle").foregroundColor(.red).frame(width: 24)
                            Text("Remove Phantom").foregroundColor(.red)
                        }
                    }
                }
            } header: {
                HStack(spacing: 6) {
                    Text("Phantom")
                    Text("👻")
                }
            } footer: {
                Text("Set an address to view its balance and positions.")
            }
            .listRowBackground(Color.hlCardBackground)

            // MARK: - Trading
            Section("Trading") {
                Picker("Default Interval", selection: $defaultInterval) {
                    ForEach(ChartInterval.allCases) { iv in
                        Text(iv.displayName).tag(iv.rawValue)
                    }
                }
                .tint(.hlGreen)

                labelRow(icon: "percent",
                         title: "Fee Discount",
                         value: feeDiscount)

                labelRow(icon: "lock.shield",
                         title: "Staking Tier",
                         value: stakingTierLabel)
            }
            .listRowBackground(Color.hlCardBackground)

            // MARK: - Notifications
            Section("Notifications") {
                if notifMgr.isAuthorized {
                    Button {
                        showAlerts = true
                    } label: {
                        HStack {
                            Image(systemName: "bell.badge").foregroundColor(.hlGreen).frame(width: 24)
                            Text("Price Alerts").foregroundColor(.white)
                            Spacer()
                            Text("\(alerts.filter(\.isActive).count) active")
                                .font(.system(size: 12))
                                .foregroundColor(.gray)
                            Image(systemName: "chevron.right").foregroundColor(.gray)
                        }
                    }
                } else {
                    Button {
                        Task { await notifMgr.requestAuthorization() }
                    } label: {
                        HStack {
                            Image(systemName: "bell.slash").foregroundColor(.orange).frame(width: 24)
                            Text("Enable Notifications").foregroundColor(.white)
                            Spacer()
                            Image(systemName: "chevron.right").foregroundColor(.gray)
                        }
                    }
                }
            }
            .listRowBackground(Color.hlCardBackground)

            // MARK: - Security
            Section("Security") {
                Toggle(isOn: Binding(
                    get: { walletMgr.biometricEnabled },
                    set: { newValue in
                        if newValue {
                            Task {
                                let success = await walletMgr.requestBiometricSetup()
                                if !success {
                                    // Biometric setup failed — keep disabled
                                }
                            }
                        } else {
                            walletMgr.biometricEnabled = false
                            walletMgr.isUnlocked = true
                        }
                    }
                )) {
                    HStack(spacing: 10) {
                        Image(systemName: "faceid")
                            .foregroundColor(.hlGreen)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Face ID")
                                .foregroundColor(.white)
                            Text("Lock app & confirm transactions")
                                .font(.system(size: 11))
                                .foregroundColor(.gray)
                        }
                    }
                }
                .tint(.hlGreen)

                // Export Private Key (only for local wallets)
                if walletMgr.isLocalWallet {
                    Button {
                        showPrivateKey = true
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "key.fill")
                                .foregroundColor(.orange)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Export Private Key")
                                    .foregroundColor(.white)
                                Text("View & copy your wallet key")
                                    .font(.system(size: 11))
                                    .foregroundColor(.gray)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12))
                                .foregroundColor(Color(white: 0.3))
                        }
                    }
                }

                // TEMPORARY: Saved wallets
                ForEach(savedWalletKeys, id: \.self) { key in
                    let addr = UserDefaults.standard.string(forKey: "hl_wallet_addr_\(key)") ?? ""
                    let label = UserDefaults.standard.string(forKey: "hl_wallet_label_\(key)") ?? key
                    let isCurrent = walletMgr.connectedWallet?.address.lowercased() == addr.lowercased()

                    if !isCurrent {
                        Button {
                            walletMgr.switchToSavedWallet(slot: key)
                            masterAddress = nil
                            activeSubAccount = nil
                            Task { await loadSubAccounts() }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .foregroundColor(.blue)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Switch to \(label)")
                                        .foregroundColor(.white)
                                    Text(addr.prefix(10) + "…")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(Color(white: 0.5))
                                }
                                Spacer()
                                Image(systemName: "arrow.right")
                                    .font(.system(size: 12))
                                    .foregroundColor(Color(white: 0.3))
                            }
                        }
                    }
                }

                // TEMPORARY: Import Private Key
                Button { showImportKey = true } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "square.and.arrow.down.fill")
                            .foregroundColor(.hlGreen)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Import Private Key")
                                .foregroundColor(.white)
                            Text("Switch to an external wallet")
                                .font(.system(size: 11))
                                .foregroundColor(.gray)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12))
                            .foregroundColor(Color(white: 0.3))
                    }
                }
            }
            .listRowBackground(Color.hlCardBackground)

            // MARK: - Sub-accounts
            Section("Sub-Accounts") {
                if subAccounts.isEmpty && !isLoadingSubAccounts {
                    Text("No sub-accounts")
                        .font(.system(size: 13))
                        .foregroundColor(Color(white: 0.5))
                } else if isLoadingSubAccounts {
                    HStack {
                        ProgressView().tint(.hlGreen)
                        Text("Loading…").font(.system(size: 13)).foregroundColor(Color(white: 0.5))
                    }
                }

                // Master account
                if !subAccounts.isEmpty, let wallet = walletMgr.connectedWallet {
                    Button {
                        switchToAccount(address: masterAddress ?? wallet.address, name: "Master", isPM: false)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "person.fill")
                                .foregroundColor(.hlGreen)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Master")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(.white)
                                Text((masterAddress ?? wallet.address).prefix(10) + "…")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(Color(white: 0.5))
                            }
                            Spacer()
                            if activeSubAccount == nil {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.hlGreen)
                            }
                        }
                    }
                }

                // Sub-accounts list
                ForEach(subAccounts, id: \.address) { sub in
                    Button {
                        switchToAccount(address: sub.address, name: sub.name, isPM: sub.isPortfolioMargin)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "person.2.fill")
                                .foregroundColor(.orange)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(sub.name)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundColor(.white)
                                    if sub.isPortfolioMargin {
                                        Text("PM")
                                            .font(.system(size: 9, weight: .bold))
                                            .foregroundColor(.hlGreen)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 2)
                                            .background(Color.hlGreen.opacity(0.15))
                                            .cornerRadius(4)
                                    }
                                }
                                HStack(spacing: 6) {
                                    Text(sub.address.prefix(10) + "…")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(Color(white: 0.5))
                                    Text(sub.balance)
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundColor(Color(white: 0.4))
                                }
                            }
                            Spacer()
                            if activeSubAccount == sub.address {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.hlGreen)
                            }
                        }
                    }
                }

                // Create new sub-account
                Button { showCreateSubAccount = true } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "plus.circle.fill")
                            .foregroundColor(.hlGreen)
                            .frame(width: 24)
                        Text("Create Sub-Account")
                            .font(.system(size: 13))
                            .foregroundColor(.hlGreen)
                    }
                }
            }
            .listRowBackground(Color.hlCardBackground)

            // MARK: - Network
            Section("Network") {
                labelRow(icon: "antenna.radiowaves.left.and.right",
                         title: "REST API",
                         value: "api.hyperliquid.xyz")
                labelRow(icon: "hammer.fill",
                         title: "Builder Code",
                         value: "0.005%")
            }
            .listRowBackground(Color.hlCardBackground)

            // MARK: - About
            Section("About") {
                labelRow(icon: "info.circle",       title: "Version",
                         value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0")
                labelRow(icon: "building.columns",  title: "Exchange",  value: "Hyperliquid")
            }
            .listRowBackground(Color.hlCardBackground)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.hlBackground)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    phantomFieldFocused = false
                }
                .fontWeight(.semibold)
                .foregroundColor(.hlGreen)
            }
        }
        .sheet(isPresented: $showWalletConnect) {
            WalletConnectView()
        }
        .sheet(isPresented: $showAlerts) {
            PriceAlertsView()
        }
        .sheet(isPresented: $showPrivateKey) {
            privateKeySheet
        }
        .sheet(isPresented: $showImportKey) {
            importKeySheet
                .presentationDetents([.height(300)])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showCreateSubAccount) {
            createSubAccountSheet
                .presentationDetents([.height(250)])
                .presentationDragIndicator(.visible)
        }
        .onAppear {
            alerts = PriceAlert.all
        }
        .task {
            if masterAddress == nil {
                masterAddress = walletMgr.connectedWallet?.address
            }
            await loadGlobalAliases()
            await loadStakingInfo()
            await loadSubAccounts()
        }
        .onChange(of: phantomAddress) { _, _ in
            Task { await loadStakingInfo() }
        }
    }

    // MARK: - Sub-Accounts

    private func loadSubAccounts() async {
        guard let wallet = walletMgr.connectedWallet else { return }
        let address = masterAddress ?? wallet.address
        await MainActor.run { isLoadingSubAccounts = true }

        guard let url = URL(string: "https://api.hyperliquid.xyz/info") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "type": "subAccounts",
            "user": address
        ])

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else {
            await MainActor.run { isLoadingSubAccounts = false }
            return
        }

        // Fetch oracle prices for PM balance calculation
        var oraclePrices: [String: Double] = ["USDC": 1.0, "USDH": 1.0, "USDT0": 1.0, "USDE": 1.0]
        if let midsReq = try? JSONSerialization.data(withJSONObject: ["type": "allMids"]) {
            var mReq = URLRequest(url: URL(string: "https://api.hyperliquid.xyz/info")!)
            mReq.httpMethod = "POST"
            mReq.addValue("application/json", forHTTPHeaderField: "Content-Type")
            mReq.httpBody = midsReq
            if let (mData, _) = try? await URLSession.shared.data(for: mReq),
               let mids = try? JSONSerialization.jsonObject(with: mData) as? [String: String] {
                for (coin, priceStr) in mids {
                    if let p = Double(priceStr) { oraclePrices[coin] = p }
                }
                if let btcP = oraclePrices["BTC"] { oraclePrices["UBTC"] = btcP }
            }
        }

        var parsed: [SubAccountInfo] = []
        for item in arr {
            guard let name = item["name"] as? String,
                  let subAddr = item["subAccountUser"] as? String
            else { continue }
            let isPM = (item["spotState"] as? [String: Any])?["portfolioMarginEnabled"] as? Bool ?? false

            var balance: Double
            if isPM {
                // PM accounts: fetch spotClearinghouseState for real supplied/borrowed
                balance = 0
                if let body = try? JSONSerialization.data(withJSONObject: [
                    "type": "spotClearinghouseState", "user": subAddr
                ]) {
                    var sReq = URLRequest(url: URL(string: "https://api.hyperliquid.xyz/info")!)
                    sReq.httpMethod = "POST"
                    sReq.addValue("application/json", forHTTPHeaderField: "Content-Type")
                    sReq.httpBody = body
                    if let (sData, _) = try? await URLSession.shared.data(for: sReq),
                       let sJson = try? JSONSerialization.jsonObject(with: sData) as? [String: Any],
                       let balances = sJson["balances"] as? [[String: Any]] {
                        for bal in balances {
                            let coin = bal["coin"] as? String ?? ""
                            let total = Double(bal["total"] as? String ?? "0") ?? 0
                            let isStable = coin == "USDC" || coin == "USDH" || coin == "USDT0" || coin == "USDE"
                            let price = oraclePrices[coin] ?? (isStable ? 1.0 : 0)
                            balance += total * price
                        }
                    }
                }
            } else {
                // Classic accounts: use perp accountValue
                let acctVal = (item["clearinghouseState"] as? [String: Any])?["marginSummary"] as? [String: Any]
                balance = (acctVal?["accountValue"] as? String).flatMap(Double.init) ?? 0
            }

            parsed.append(SubAccountInfo(
                name: name,
                address: subAddr,
                balance: String(format: "$%.2f", balance),
                isPortfolioMargin: isPM
            ))
        }

        await MainActor.run {
            subAccounts = parsed
            if masterAddress == nil { masterAddress = wallet.address }
            isLoadingSubAccounts = false
        }
    }

    private func switchToAccount(address: String, name: String, isPM: Bool) {
        let isMaster = (address == masterAddress)
        activeSubAccount = isMaster ? nil : address
        walletMgr.isPortfolioMargin = isPM
        walletMgr.activeVaultAddress = isMaster ? nil : address
        walletMgr.switchToAddress(address)
    }

    private var createSubAccountSheet: some View {
        VStack(spacing: 16) {
            Text("Create Sub-Account")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)
                .padding(.top, 8)

            TextField("Sub-account name", text: $newSubAccountName)
                .font(.system(size: 14))
                .foregroundColor(.white)
                .autocorrectionDisabled()
                .padding(12)
                .background(Color(white: 0.1))
                .cornerRadius(8)
                .padding(.horizontal, 16)

            if let err = createSubError {
                Text(err)
                    .font(.system(size: 12))
                    .foregroundColor(.tradingRed)
                    .padding(.horizontal, 16)
            }

            Button {
                guard !newSubAccountName.isEmpty else { return }
                isCreatingSubAccount = true
                createSubError = nil
                Task {
                    do {
                        let payload = try await TransactionSigner.signCreateSubAccount(name: newSubAccountName)
                        let result = try await TransactionSigner.postAction(payload)
                        if let status = result["status"] as? String, status == "err",
                           let errMsg = result["response"] as? String {
                            await MainActor.run {
                                createSubError = errMsg
                                isCreatingSubAccount = false
                            }
                            return
                        }
                        await loadSubAccounts()
                        await MainActor.run {
                            isCreatingSubAccount = false
                            newSubAccountName = ""
                            showCreateSubAccount = false
                        }
                    } catch {
                        await MainActor.run {
                            createSubError = error.localizedDescription
                            isCreatingSubAccount = false
                        }
                    }
                }
            } label: {
                if isCreatingSubAccount {
                    ProgressView().tint(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.hlGreen.opacity(0.6))
                        .cornerRadius(10)
                } else {
                    Text("Create")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.hlGreen)
                        .cornerRadius(10)
                }
            }
            .disabled(newSubAccountName.isEmpty || isCreatingSubAccount)
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 16)
        .background(Color(white: 0.08))
    }

    // MARK: - Import Private Key (TEMPORARY)

    private var importKeySheet: some View {
        VStack(spacing: 16) {
            Text("Import Private Key")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)
                .padding(.top, 8)

            Text("Paste your private key to switch wallet. Your current in-app wallet key will remain in Keychain.")
                .font(.system(size: 12))
                .foregroundColor(Color(white: 0.5))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)

            HStack(spacing: 8) {
                TextField("0x…", text: $importKeyInput)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(.white)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .padding(10)
                    .background(Color(white: 0.1))
                    .cornerRadius(8)

                Button {
                    if let pasted = UIPasteboard.general.string {
                        importKeyInput = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                } label: {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 16))
                        .foregroundColor(.hlGreen)
                }
            }
            .padding(.horizontal, 16)

            if let err = importError {
                Text(err)
                    .font(.system(size: 12))
                    .foregroundColor(.tradingRed)
            }

            if importSuccess {
                Text("✅ Wallet imported: \(walletMgr.connectedWallet?.address.prefix(10) ?? "")…")
                    .font(.system(size: 12))
                    .foregroundColor(.hlGreen)
            }

            Button {
                importError = nil
                importSuccess = false
                if walletMgr.importPrivateKey(importKeyInput) {
                    importSuccess = true
                    importKeyInput = ""
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        showImportKey = false
                        importSuccess = false
                    }
                } else {
                    importError = "Invalid private key (must be 32 bytes hex)"
                }
            } label: {
                Text("Import")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.hlGreen)
                    .cornerRadius(10)
            }
            .disabled(importKeyInput.isEmpty)
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 16)
        .background(Color(white: 0.08))
    }

    // MARK: - Private Key Export

    private var privateKeySheet: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                Image(systemName: "key.fill")
                    .font(.system(size: 44))
                    .foregroundColor(.orange)

                Text("Your Private Key")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.white)

                Text("Never share this with anyone. Anyone with your private key has full control of your wallet.")
                    .font(.system(size: 13))
                    .foregroundColor(Color(white: 0.5))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)

                if let key = revealedKey {
                    // Key revealed
                    Text(key)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.white)
                        .padding(14)
                        .frame(maxWidth: .infinity)
                        .background(Color(white: 0.09))
                        .cornerRadius(12)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.orange.opacity(0.3), lineWidth: 1)
                        )
                        .padding(.horizontal, 20)

                    Button {
                        UIPasteboard.general.string = key
                        keyCopied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { keyCopied = false }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: keyCopied ? "checkmark" : "doc.on.doc")
                            Text(keyCopied ? "Copied!" : "Copy Private Key")
                        }
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.orange)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(Color.orange.opacity(0.12))
                        .cornerRadius(10)
                    }
                } else {
                    // Not yet revealed — require Face ID
                    Button {
                        Task {
                            let ok = await walletMgr.authenticateForTransaction()
                            if ok {
                                revealedKey = walletMgr.privateKeyHex
                            }
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "faceid")
                            Text("Authenticate to Reveal")
                        }
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.orange)
                        .cornerRadius(12)
                    }
                    .padding(.horizontal, 20)
                }

                Spacer()

                // Warning
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.system(size: 14))
                    Text("Your key is stored only on this device in the iOS Keychain. Hyperview never sends it to any server.")
                        .font(.system(size: 12))
                        .foregroundColor(Color(white: 0.5))
                }
                .padding(14)
                .background(Color.orange.opacity(0.08))
                .cornerRadius(12)
                .padding(.horizontal, 14)
                .padding(.bottom, 20)
            }
            .background(Color.hlBackground.ignoresSafeArea())
            .navigationTitle("Export Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        revealedKey = nil  // Clear key from memory on dismiss
                        showPrivateKey = false
                    }
                    .foregroundColor(.hlGreen)
                }
            }
            .onDisappear {
                revealedKey = nil  // Safety: clear key when sheet dismissed
            }
        }
    }

    // MARK: - Phantom helpers

    private var shortPhantomAddress: String {
        shortAddress(phantomAddress)
    }

    private func shortAddress(_ addr: String) -> String {
        guard addr.count > 10 else { return addr }
        return "\(addr.prefix(6))…\(addr.suffix(4))"
    }

    private func setPhantom(_ input: String) {
        let addr = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard addr.hasPrefix("0x"), addr.count == 42 else { return }
        phantomAddress = addr
        phantomInput = ""
        addRecentPhantom(addr)
    }

    private var recentPhantomAddresses: [String] {
        UserDefaults.standard.stringArray(forKey: Self.recentPhantomKey) ?? []
    }

    private func addRecentPhantom(_ addr: String) {
        var recents = recentPhantomAddresses
        recents.removeAll { $0.lowercased() == addr.lowercased() }
        recents.insert(addr.lowercased(), at: 0)
        if recents.count > 5 { recents = Array(recents.prefix(5)) }
        UserDefaults.standard.set(recents, forKey: Self.recentPhantomKey)
    }

    private func aliasFor(_ address: String) -> String? {
        let key = address.lowercased()
        // Custom alias first
        let custom = UserDefaults.standard.dictionary(forKey: "customWalletAliases") as? [String: String] ?? [:]
        if let c = custom[key] { return c }
        // Global alias
        return globalAliases[key]
    }

    private var phantomAliasSuggestions: [(address: String, name: String)] {
        let input = phantomInput.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard input.count >= 2 else { return [] }
        if input.hasPrefix("0x") && input.count > 10 { return [] }
        return allAliases
            .filter { $0.value.lowercased().contains(input) || $0.key.contains(input) }
            .sorted { $0.value.lowercased() < $1.value.lowercased() }
            .prefix(5)
            .map { (address: $0.key, name: $0.value) }
    }

    private func loadStakingInfo() async {
        // Use phantom address if set, otherwise own wallet
        let addr: String
        if !phantomAddress.isEmpty && phantomAddress.hasPrefix("0x") && phantomAddress.count == 42 {
            addr = phantomAddress
        } else if let own = walletMgr.connectedWallet?.address {
            addr = own
        } else {
            feeDiscount = "–"
            stakingTierLabel = "–"
            return
        }

        do {
            let staking = try await HyperliquidAPI.shared.fetchStakingState(address: addr)
            let hypeStaked: Double = {
                if let delegated = staking["delegated"] as? String,
                   let val = Double(delegated) { return val }
                return 0
            }()

            let tier: WalletManager.StakingTier
            if hypeStaked >= 500_000 { tier = .tier6 }
            else if hypeStaked >= 100_000 { tier = .tier5 }
            else if hypeStaked >= 10_000 { tier = .tier4 }
            else if hypeStaked >= 1_000 { tier = .tier3 }
            else if hypeStaked >= 100 { tier = .tier2 }
            else if hypeStaked >= 10 { tier = .tier1 }
            else { tier = .none }

            stakingTierLabel = tier.rawValue
            feeDiscount = String(format: "%.0f%%", tier.feeDiscount * 100)
        } catch {
            feeDiscount = "–"
            stakingTierLabel = "–"
        }
    }

    private func loadGlobalAliases() async {
        // Custom aliases
        var merged = UserDefaults.standard.dictionary(forKey: "customWalletAliases") as? [String: String] ?? [:]
        // Global aliases
        if let url = URL(string: "https://api.hypurrscan.io/globalAliases"),
           let (data, _) = try? await URLSession.shared.data(from: url),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            let normalized = Dictionary(uniqueKeysWithValues: dict.map { ($0.key.lowercased(), $0.value) })
            globalAliases = normalized
            for (k, v) in normalized {
                if merged[k] == nil { merged[k] = v }
            }
        }
        allAliases = merged
    }

    private func labelRow(icon: String, title: String, value: String) -> some View {
        HStack {
            Image(systemName: icon).foregroundColor(.hlGreen).frame(width: 24)
            Text(title).foregroundColor(.white)
            Spacer()
            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.gray)
        }
    }
}

// MARK: - Price Alerts management sheet

struct PriceAlertsView: View {
    @Environment(\.dismiss) var dismiss
    @State private var alerts = PriceAlert.all
    @State private var showAdd = false

    var body: some View {
        NavigationStack {
            Group {
                if alerts.isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: "bell.slash")
                            .font(.system(size: 36))
                            .foregroundColor(.gray)
                        Text("No price alerts")
                            .foregroundColor(.gray)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(alerts) { alert in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(alert.symbol)
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundColor(.white)
                                    Text("\(alert.condition.rawValue) $\(String(format: "%.4f", alert.price))")
                                        .font(.system(size: 12))
                                        .foregroundColor(.gray)
                                }
                                Spacer()
                                Circle()
                                    .fill(alert.isActive ? Color.green : Color.gray)
                                    .frame(width: 8, height: 8)
                            }
                            .listRowBackground(Color.hlCardBackground)
                        }
                        .onDelete { idx in
                            alerts.remove(atOffsets: idx)
                            PriceAlert.all = alerts
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .background(Color.hlBackground)
            .navigationTitle("Price Alerts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }.tint(.hlGreen)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    EditButton().tint(.hlGreen)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
