import SwiftUI

// MARK: - WalletConnectView

struct WalletConnectView: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject private var walletMgr = WalletManager.shared

    @State private var manualAddress = ""
    @State private var showManual    = false
    @State private var errorMsg:     String?
    @State private var showCreateNewWalletAlert = false
    @State private var showFundsBlockedAlert = false

    private var anyWalletInstalled: Bool {
        WalletApp.allCases.contains { $0.isInstalled }
    }


    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let wallet = walletMgr.connectedWallet {
                    connectedView(wallet)
                } else {
                    connectView
                }
            }
            .background(Color.hlBackground.ignoresSafeArea())
            .navigationTitle("Wallet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }.tint(.hlGreen)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Connected state

    private func connectedView(_ wallet: ConnectedWallet) -> some View {
        VStack(spacing: 24) {
            // Status
            VStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 48))
                    .foregroundColor(Color.hlGreen)
                Text("Wallet Connected")
                    .font(.headline)
                    .foregroundColor(.white)
                Text(wallet.address)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.gray)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            .padding(.top, 32)

            // Info rows
            VStack(spacing: 1) {
                infoRow(icon: "wallet.pass", label: "Wallet App",  value: wallet.walletApp)
                infoRow(icon: "dollarsign.circle", label: "Account Value",
                        value: String(format: "$%.2f", walletMgr.accountValue))
                infoRow(icon: "star.circle", label: "Staking Tier",
                        value: walletMgr.stakingTier.rawValue)
                infoRow(icon: "percent", label: "Fee Discount",
                        value: String(format: "%.0f%%",
                                      walletMgr.stakingTier.feeDiscount * 100))
            }
            .background(Color.hlCardBackground)
            .cornerRadius(12)
            .padding(.horizontal, 20)

            // Refresh + Disconnect
            VStack(spacing: 12) {
                Button {
                    Task { await walletMgr.refreshAccountState() }
                } label: {
                    Label("Refresh Balance", systemImage: "arrow.clockwise")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.hlGreen)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.hlGreen.opacity(0.12))
                        .cornerRadius(10)
                }

                Button(role: .destructive) {
                    walletMgr.disconnect()
                } label: {
                    Text("Disconnect Wallet")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.red)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.red.opacity(0.1))
                        .cornerRadius(10)
                }

                Button {
                    if walletMgr.canSafelyCreateNewWallet {
                        showCreateNewWalletAlert = true
                    } else {
                        showFundsBlockedAlert = true
                    }
                } label: {
                    Label("Create New Wallet", systemImage: "plus.circle")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.hlGreen)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.hlGreen.opacity(0.12))
                        .cornerRadius(10)
                }
                .alert("Create New Wallet?", isPresented: $showCreateNewWalletAlert) {
                    Button("Cancel", role: .cancel) {}
                    Button("I've Backed Up My Key", role: .destructive) {
                        walletMgr.createNewWallet()
                        dismiss()
                    }
                } message: {
                    Text("Make sure you have exported your private key from Settings before continuing. A new wallet with a new private key will be generated.")
                }
                .alert("Cannot Create New Wallet", isPresented: $showFundsBlockedAlert) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(walletMgr.createWalletBlockedReason ?? "Transfer all funds out and export your private key from Settings first.")
                }
            }
            .padding(.horizontal, 20)

            Spacer()
        }
    }

    // MARK: - Connect state

    private var connectView: some View {
        VStack(spacing: 24) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "link.circle.fill")
                    .font(.system(size: 48))
                    .foregroundColor(.hlGreen)
                    .padding(.top, 32)
                Text("Connect Your Wallet")
                    .font(.title3.bold())
                    .foregroundColor(.white)
                Text("Connect to access trading, track positions and manage staking tiers.")
                    .font(.system(size: 13))
                    .foregroundColor(.gray)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            // Wallet app options — always shown, disabled if not installed
            VStack(spacing: 10) {
                ForEach(WalletApp.allCases) { app in
                    walletButton(app)
                }
            }
            .padding(.horizontal, 20)

            // Divider with OR
            HStack(spacing: 10) {
                Rectangle().fill(Color.hlDivider).frame(height: 1)
                Text("OR")
                    .font(.system(size: 12))
                    .foregroundColor(Color(white: 0.4))
                Rectangle().fill(Color.hlDivider).frame(height: 1)
            }
            .padding(.horizontal, 20)

            // Manual address entry
            VStack(spacing: 10) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showManual.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "keyboard")
                        Text(showManual ? "Hide Manual Entry" : "Enter Address Manually")
                    }
                    .font(.system(size: 14))
                    .foregroundColor(Color(white: 0.6))
                }

                if showManual {
                    VStack(spacing: 8) {
                        TextField("0x…", text: $manualAddress)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(.white)
                            .padding(12)
                            .background(Color.hlSurface)
                            .cornerRadius(8)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .padding(.horizontal, 20)

                        if let err = errorMsg {
                            Text(err)
                                .font(.system(size: 12))
                                .foregroundColor(.red)
                        }

                        Button {
                            connectManual()
                        } label: {
                            Text("Connect")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.black)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color.hlGreen)
                                .cornerRadius(10)
                        }
                        .padding(.horizontal, 20)
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: showManual)
            .onAppear {
                // Auto-expand manual entry when no wallet apps are installed (e.g. simulator)
                if !anyWalletInstalled { showManual = true }
            }

            Spacer()

            // Disclaimer
            Text("View-only mode: address entry lets you track positions without signing.\nTo trade, connect via a compatible wallet app.")
                .font(.system(size: 11))
                .foregroundColor(Color(white: 0.35))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
        }
    }

    // MARK: - Wallet button

    private func walletButton(_ app: WalletApp) -> some View {
        let isInstalled = app.isInstalled || app == .walletConnect

        return Button {
            connectWithApp(app)
        } label: {
            HStack(spacing: 12) {
                Text(app.icon)
                    .font(.system(size: 24))
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.rawValue)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(isInstalled ? .white : Color(white: 0.4))
                    Text(isInstalled ? "Tap to connect" : "Not installed")
                        .font(.system(size: 12))
                        .foregroundColor(Color(white: 0.4))
                }
                Spacer()
                if isInstalled {
                    Image(systemName: "arrow.right.circle")
                        .foregroundColor(.hlGreen)
                }
            }
            .padding(14)
            .background(isInstalled ? Color.hlSurface : Color.hlCardBackground)
            .cornerRadius(12)
        }
        .disabled(!isInstalled)
    }

    // MARK: - Info row

    private func infoRow(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(.hlGreen)
                .frame(width: 22)
            Text(label)
                .font(.system(size: 13))
                .foregroundColor(Color(white: 0.5))
            Spacer()
            Text(value)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.hlCardBackground)
    }

    // MARK: - Actions

    private func connectWithApp(_ app: WalletApp) {
        if app == .walletConnect {
            // WalletConnect: in production, integrate WalletConnect SDK.
            // For now, fall back to manual address entry.
            withAnimation(.easeInOut(duration: 0.2)) { showManual = true }
            return
        }
        guard let scheme = app.scheme, let url = URL(string: scheme) else { return }
        // Deep-link to wallet app. The wallet opens and the user can copy/paste address back.
        // A production app would use a callback URL scheme registered in Info.plist.
        UIApplication.shared.open(url)
        // After returning, show manual entry pre-filled
        showManual = true
    }

    private func connectManual() {
        errorMsg = nil
        let addr = manualAddress.trimmingCharacters(in: .whitespaces)
        guard addr.hasPrefix("0x"), addr.count == 42 else {
            errorMsg = "Invalid address — must start with 0x and be 42 characters"
            return
        }
        walletMgr.connectManual(address: addr)
        dismiss()
    }
}
