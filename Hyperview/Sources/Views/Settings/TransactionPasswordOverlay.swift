import SwiftUI

/// Modal overlay that appears when a transaction requires password authentication
/// (Face ID not available or failed).
struct TransactionPasswordOverlay: View {
    @ObservedObject private var wallet = WalletManager.shared
    @State private var password = ""
    @State private var error: String?
    @State private var showPassword = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.6)
                .ignoresSafeArea()
                .onTapGesture { cancel() }

            VStack(spacing: 20) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 36))
                    .foregroundColor(.hlGreen)

                Text("Confirm Transaction")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.white)

                Text("Enter your password to authorize this action.")
                    .font(.system(size: 13))
                    .foregroundColor(Color(white: 0.5))
                    .multilineTextAlignment(.center)

                HStack {
                    if showPassword {
                        TextField("Password", text: $password)
                            .textContentType(.password)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .onSubmit { submit() }
                    } else {
                        SecureField("Password", text: $password)
                            .textContentType(.password)
                            .onSubmit { submit() }
                    }
                    Button { showPassword.toggle() } label: {
                        Image(systemName: showPassword ? "eye.slash" : "eye")
                            .foregroundColor(Color(white: 0.4))
                            .font(.system(size: 14))
                    }
                }
                .font(.system(size: 15))
                .foregroundColor(.white)
                .padding(14)
                .background(Color.hlSurface)
                .cornerRadius(10)

                if let error {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundColor(.tradingRed)
                }

                HStack(spacing: 12) {
                    Button { cancel() } label: {
                        Text("Cancel")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(Color(white: 0.5))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.hlSurface)
                            .cornerRadius(10)
                    }

                    Button { submit() } label: {
                        Text("Confirm")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(password.isEmpty ? Color(white: 0.4) : .black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(password.isEmpty ? Color.hlGreen.opacity(0.3) : Color.hlGreen)
                            .cornerRadius(10)
                    }
                    .disabled(password.isEmpty)
                }
            }
            .padding(24)
            .background(Color.hlCardBackground)
            .cornerRadius(16)
            .padding(.horizontal, 30)
        }
        .animation(.easeInOut(duration: 0.15), value: error)
    }

    private func submit() {
        error = nil
        guard !password.isEmpty else { return }
        if wallet.submitTransactionPassword(password) {
            // Success — overlay will dismiss automatically via pendingPasswordAuth → false
        } else {
            error = "Wrong password"
            password = ""
        }
    }

    private func cancel() {
        wallet.passwordAuthResult = false
    }
}
