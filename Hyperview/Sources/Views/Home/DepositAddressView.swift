import SwiftUI
import CoreImage.CIFilterBuiltins

// MARK: - DepositAddressView
// Shows the deposit address (+ QR code) for a selected asset.
// For USDC on Arbitrum: fixed bridge address.
// For BTC/ETH/SOL: fetches a unique address from UNIT API.

struct DepositAddressView: View {
    let asset: DepositAsset

    @Environment(\.dismiss) private var dismiss
    @State private var depositAddress: String?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var copied = false
    @State private var showShareSheet = false
    @State private var walletCopyHint = false
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {

                // Asset header
                VStack(spacing: 8) {
                    Text("Deposit \(asset.name)")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(.white)
                    Text("Network: \(asset.network)")
                        .font(.system(size: 14))
                        .foregroundColor(Color(white: 0.5))
                }
                .padding(.top, 20)

                // Icon
                CoinIconView(symbol: asset.name, hlIconName: asset.name, iconSize: 48, isSpot: true)

                // QR code
                if let address = depositAddress {
                    qrCode(for: address)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 200, height: 200)
                        .padding(16)
                        .background(Color.white)
                        .cornerRadius(16)
                } else if isLoading {
                    VStack(spacing: 14) {
                        ProgressView()
                            .tint(.hlGreen)
                            .scaleEffect(1.2)
                        Text("Generating deposit address…")
                            .font(.system(size: 13))
                            .foregroundColor(Color(white: 0.5))
                    }
                    .frame(width: 232, height: 232)
                    .background(Color(white: 0.09))
                    .cornerRadius(16)
                } else if let error = errorMessage {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 28))
                            .foregroundColor(.orange)
                        Text(error)
                            .font(.system(size: 13))
                            .foregroundColor(Color(white: 0.5))
                            .multilineTextAlignment(.center)
                        Button("Retry") {
                            isLoading = true
                            errorMessage = nil
                            Task { await loadAddress() }
                        }
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.hlGreen)
                    }
                    .frame(width: 232, height: 232)
                    .background(Color(white: 0.09))
                    .cornerRadius(16)
                }

                // Address display + copy + share
                if let address = depositAddress {
                    VStack(spacing: 12) {
                        // Address text
                        Text(address)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)
                            .padding(12)
                            .background(Color.hlSurface)
                            .cornerRadius(10)

                        // Copy + Share buttons
                        HStack(spacing: 10) {
                            Button {
                                UIPasteboard.general.string = address
                                copied = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                    copied = false
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                                    Text(copied ? "Copied!" : "Copy")
                                }
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.black)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(Color.hlGreen)
                                .cornerRadius(10)
                            }

                            Button {
                                showShareSheet = true
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "square.and.arrow.up")
                                    Text("Share")
                                }
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(Color.hlSurface)
                                .cornerRadius(10)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(Color.white.opacity(0.15), lineWidth: 1)
                                )
                            }
                        }

                        // Wallet deep-link buttons
                        VStack(spacing: 8) {
                            Text("Send from wallet")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(Color(white: 0.45))
                                .frame(maxWidth: .infinity, alignment: .leading)

                            let wallets = Self.sendWallets(address: address)
                            let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)
                            LazyVGrid(columns: columns, spacing: 8) {
                                ForEach(wallets, id: \.name) { w in
                                    Button {
                                        UIPasteboard.general.string = address
                                        if w.needsPasteHint {
                                            walletCopyHint = true
                                            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                                                walletCopyHint = false
                                            }
                                        }
                                        if let url = URL(string: w.deepLink) {
                                            UIApplication.shared.open(url)
                                        }
                                    } label: {
                                        VStack(spacing: 5) {
                                            Text(w.icon)
                                                .font(.system(size: 22))
                                            Text(w.name)
                                                .font(.system(size: 11, weight: .medium))
                                                .foregroundColor(.white)
                                        }
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 10)
                                        .background(Color.hlSurface)
                                        .cornerRadius(10)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 10)
                                                .stroke(Color.white.opacity(0.1), lineWidth: 1)
                                        )
                                    }
                                }
                            }
                        }
                        .padding(.top, 4)
                    }
                    .padding(.horizontal, 20)
                    .sheet(isPresented: $showShareSheet) {
                        let msg = """
                        My deposit address for \(asset.name) (\(asset.network)):

                        \(address)

                        Send \(asset.name) only on the \(asset.network) network.
                        """
                        ShareSheet(items: [msg])
                    }
                }

                // Info cards — always visible
                VStack(spacing: 1) {
                    infoRow(label: "Network", value: asset.network)
                    infoRow(label: "Minimum Deposit", value: "\(asset.minDeposit) \(asset.name)")
                    infoRow(label: "Estimated Time", value: asset.estimatedTime)
                    infoRow(label: "Bridge Fee (Unit)", value: asset.estimatedFee)
                }
                .cornerRadius(12)
                .padding(.horizontal, 14)

                // Fee disclaimer
                Text("Fees are charged by Unit, a third-party bridge provider, not by Hyperview.")
                    .font(.system(size: 11))
                    .foregroundColor(Color(white: 0.4))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)

                // Warning
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.system(size: 14))
                    Text("Only send \(asset.name) on the \(asset.network) network. Sending other assets or using the wrong network may result in permanent loss.")
                        .font(.system(size: 12))
                        .foregroundColor(Color(white: 0.5))
                }
                .padding(14)
                .background(Color.orange.opacity(0.08))
                .cornerRadius(12)
                .padding(.horizontal, 14)
            }
            .padding(.bottom, 30)
        }
        .background(Color.hlBackground.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .bottom) {
            if walletCopyHint {
                Text("Address copied — paste it in the recipient field")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.hlSurface)
                    .cornerRadius(10)
                    .shadow(color: .black.opacity(0.4), radius: 8)
                    .padding(.bottom, 40)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .animation(.easeInOut(duration: 0.25), value: walletCopyHint)
            }
        }
        .task { await loadAddress() }
    }

    // MARK: - Load deposit address

    private func loadAddress() async {
        if let fixed = asset.fixedAddress {
            depositAddress = fixed
            isLoading = false
            return
        }

        // Hyperliquid native tokens: deposit to user's own HL address
        if asset.network.lowercased() == "hyperliquid" {
            if let walletAddr = WalletManager.shared.connectedWallet?.address {
                depositAddress = walletAddr
            } else {
                errorMessage = "Wallet not connected"
            }
            isLoading = false
            return
        }

        // Fetch from UNIT API
        guard let srcChain = asset.unitSrcChain,
              let walletAddr = WalletManager.shared.connectedWallet?.address else {
            errorMessage = "Wallet not connected"
            isLoading = false
            return
        }

        do {
            let addr = try await HyperliquidAPI.shared
                .generateDepositAddress(srcChain: srcChain, asset: asset.unitAsset,
                                         hlAddress: walletAddr)
            depositAddress = addr
        } catch {
            errorMessage = "Failed to generate address: \(error.localizedDescription)"
        }
        isLoading = false
    }

    // MARK: - QR code

    private func qrCode(for string: String) -> Image {
        let ctx = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let cgImage = ctx.createCGImage(output, from: output.extent) else {
            return Image(systemName: "xmark.square")
        }
        return Image(uiImage: UIImage(cgImage: cgImage))
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

    // MARK: - Wallet deep links

    private struct WalletLink {
        let name: String
        let icon: String
        let deepLink: String
        var needsPasteHint: Bool = false
    }

    /// Returns wallet options — only wallets whose scheme is openable are included.
    private static func sendWallets(address: String) -> [WalletLink] {
        let candidates: [WalletLink] = [
            // Deep link with address pre-filled (EIP-681 format for MetaMask)
            WalletLink(name: "MetaMask",   icon: "🦊", deepLink: "metamask://send/ethereum:\(address)"),
            WalletLink(name: "Trust",      icon: "🛡️", deepLink: "trust://send?asset=c60&address=\(address)"),
            WalletLink(name: "Coinbase",   icon: "🔵", deepLink: "cbwallet://send?address=\(address)"),
            // These wallets don't have reliable send deep links — open app + paste
            WalletLink(name: "Rainbow",    icon: "🌈", deepLink: "rainbow://", needsPasteHint: true),
            WalletLink(name: "Zerion",     icon: "⚡️", deepLink: "zerion://", needsPasteHint: true),
            WalletLink(name: "Uniswap",    icon: "🦄", deepLink: "uniswap://", needsPasteHint: true),
            WalletLink(name: "Rabby",      icon: "🐰", deepLink: "rabby://", needsPasteHint: true),
            WalletLink(name: "Phantom",    icon: "👻", deepLink: "phantom://", needsPasteHint: true),
            WalletLink(name: "OKX",        icon: "⬛", deepLink: "okex://", needsPasteHint: true),
            WalletLink(name: "Ledger",     icon: "🔒", deepLink: "ledgerlive://", needsPasteHint: true),
            WalletLink(name: "SafePal",    icon: "🔐", deepLink: "safepal://", needsPasteHint: true),
            WalletLink(name: "Bitget",     icon: "🅱️", deepLink: "bitkeep://", needsPasteHint: true),
            WalletLink(name: "1inch",      icon: "🐴", deepLink: "oneinch://", needsPasteHint: true),
            WalletLink(name: "imToken",    icon: "💎", deepLink: "imtokenlon://", needsPasteHint: true),
            WalletLink(name: "Exodus",     icon: "🚀", deepLink: "exodus://", needsPasteHint: true),
            WalletLink(name: "Argent",     icon: "🛡️", deepLink: "argent://", needsPasteHint: true),
        ]
        return candidates.filter { w in
            // Extract scheme from deep link
            guard let scheme = w.deepLink.components(separatedBy: "://").first,
                  let url = URL(string: "\(scheme)://") else { return false }
            return UIApplication.shared.canOpenURL(url)
        }
    }
}

// MARK: - UIKit Share Sheet wrapper

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
