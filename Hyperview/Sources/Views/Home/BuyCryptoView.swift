import SwiftUI
import SafariServices

// MARK: - BuyCryptoView
// Amount picker + payment method → opens MoonPay in-app via SFSafariViewController.

struct BuyCryptoView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var wallet = WalletManager.shared

    @State private var amount: String = "100"
    @State private var selectedPreset: Int? = 100
    @State private var paymentMethod = PaymentMethod.card
    @State private var showSafari = false

    private let presets = [50, 100, 500, 1000]

    enum PaymentMethod: String, CaseIterable, Identifiable {
        case card       = "Debit/Credit Card"
        case applePay   = "Apple Pay"
        case revolut    = "Revolut Pay"
        case paypal     = "PayPal"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .card:     return "creditcard.fill"
            case .applePay: return "apple.logo"
            case .revolut:  return "r.circle.fill"
            case .paypal:   return "p.circle.fill"
            }
        }

        var moonPayValue: String {
            switch self {
            case .card:     return "credit_debit_card"
            case .applePay: return "mobile_wallet"
            case .revolut:  return "revolut_pay"
            case .paypal:   return "paypal"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 24) {

                    // Amount input
                    VStack(spacing: 12) {
                        Text("Amount (USD)")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(Color(white: 0.5))
                            .frame(maxWidth: .infinity, alignment: .leading)

                        HStack {
                            Text("$")
                                .font(.system(size: 28, weight: .bold))
                                .foregroundColor(.white)
                            TextField("0", text: $amount)
                                .font(.system(size: 28, weight: .bold))
                                .foregroundColor(.white)
                                .keyboardType(.numberPad)
                                .onChange(of: amount) { _, newValue in
                                    selectedPreset = nil
                                    let formatted = formatIntegerWithCommas(newValue)
                                    if formatted != newValue { amount = formatted }
                                }
                        }
                        .padding(16)
                        .background(Color.hlSurface)
                        .cornerRadius(12)

                        // Presets
                        HStack(spacing: 8) {
                            ForEach(presets, id: \.self) { preset in
                                Button {
                                    amount = formatIntegerWithCommas("\(preset)")
                                    selectedPreset = preset
                                } label: {
                                    Text("$\(preset)")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundColor(selectedPreset == preset ? .black : .white)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 8)
                                        .background(selectedPreset == preset
                                                     ? Color.hlGreen
                                                     : Color.hlDivider)
                                        .cornerRadius(20)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 20)

                    // Payment method
                    VStack(spacing: 8) {
                        Text("Payment Method")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(Color(white: 0.5))
                            .frame(maxWidth: .infinity, alignment: .leading)

                        VStack(spacing: 1) {
                            ForEach(PaymentMethod.allCases) { method in
                                Button {
                                    paymentMethod = method
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: method.icon)
                                            .font(.system(size: 16))
                                            .foregroundColor(.white)
                                            .frame(width: 28)

                                        Text(method.rawValue)
                                            .font(.system(size: 14))
                                            .foregroundColor(.white)

                                        Spacer()

                                        if paymentMethod == method {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundColor(.hlGreen)
                                        }
                                    }
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 12)
                                    .background(Color.hlCardBackground)
                                }
                            }
                        }
                        .cornerRadius(12)
                    }
                    .padding(.horizontal, 14)

                    // Info
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "info.circle")
                            .foregroundColor(.hlGreen)
                            .font(.system(size: 14))
                        Text("You'll receive USDC on Hyperliquid. Powered by MoonPay. KYC may be required for first purchase.")
                            .font(.system(size: 12))
                            .foregroundColor(Color(white: 0.5))
                    }
                    .padding(14)
                    .background(Color.hlCardBackground)
                    .cornerRadius(12)
                    .padding(.horizontal, 14)
                }
            }

            // Buy button
            Button {
                showSafari = true
            } label: {
                Text("Buy USDC")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.hlGreen)
                    .cornerRadius(14)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
            .disabled(Double(stripCommas(amount)) ?? 0 < 20)
        }
        .background(Color.hlBackground.ignoresSafeArea())
        .navigationTitle("Buy with Card")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel") { dismiss() }
                    .foregroundColor(.hlGreen)
            }
        }
        .sheet(isPresented: $showSafari) {
            if let url = moonPayURL {
                SafariSheet(url: url)
            }
        }
    }

    // MARK: - MoonPay URL

    private var moonPayURL: URL? {
        guard let addr = wallet.connectedWallet?.address else { return nil }
        guard var comps = URLComponents(string: "https://buy.moonpay.com/") else { return nil }
        comps.queryItems = [
            URLQueryItem(name: "apiKey",             value: "pk_live_YOUR_KEY"),
            URLQueryItem(name: "currencyCode",       value: "usdc_arbitrum"),
            URLQueryItem(name: "walletAddress",      value: addr),
            URLQueryItem(name: "baseCurrencyAmount", value: stripCommas(amount)),
            URLQueryItem(name: "paymentMethod",      value: paymentMethod.moonPayValue),
            URLQueryItem(name: "theme",              value: "dark"),
            URLQueryItem(name: "colorCode",          value: "00FF00"),
        ]
        return comps.url
    }
}
