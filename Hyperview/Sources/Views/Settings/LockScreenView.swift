import SwiftUI

/// Full-screen lock overlay — shown when the app requires authentication.
/// Supports Face ID (if enabled) and password entry as primary/fallback.
struct LockScreenView: View {
    @ObservedObject private var wallet = WalletManager.shared

    @State private var passwordInput = ""
    @State private var showPasswordField = false
    @State private var showPassword = false
    @State private var passwordError: String?
    @State private var attempts = 0

    /// True if Face ID / Touch ID is available on this device
    private var biometricAvailable: Bool {
        wallet.biometricEnabled
    }

    var body: some View {
        ZStack {
            Color.hlBackground.ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()

                Image(systemName: "lock.fill")
                    .font(.system(size: 48))
                    .foregroundColor(.hlGreen)

                Text("Hyperview Locked")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.white)

                if let error = wallet.authError {
                    Text(error)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.tradingRed)
                        .transition(.opacity)
                }

                if !biometricAvailable || showPasswordField || wallet.authError != nil {
                    // Password unlock — shown when Face ID fails or user chooses password
                    if wallet.hasPassword {
                        passwordSection
                    }
                } else {
                    Text("Authenticate to continue")
                        .font(.system(size: 14))
                        .foregroundColor(Color(white: 0.5))
                }

                Spacer()

                VStack(spacing: 10) {
                    if biometricAvailable {
                        Button {
                            wallet.authError = nil
                            Task { await wallet.authenticateAppLaunch() }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "faceid")
                                    .font(.system(size: 20))
                                Text(showPasswordField ? "Use Face ID" : (wallet.authError != nil ? "Try Again" : "Unlock"))
                                    .font(.system(size: 16, weight: .semibold))
                            }
                            .foregroundColor(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.hlGreen)
                            .cornerRadius(12)
                        }
                        .padding(.horizontal, 40)

                        if !showPasswordField && wallet.hasPassword {
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    showPasswordField = true
                                    wallet.authError = nil
                                }
                            } label: {
                                Text("Use Password Instead")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(Color(white: 0.5))
                            }
                        }
                    } else {
                        // No biometric — password is the only option
                        Button {
                            submitPassword()
                        } label: {
                            Text("Unlock")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(passwordInput.isEmpty ? Color(white: 0.4) : .black)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(passwordInput.isEmpty ? Color.hlGreen.opacity(0.3) : Color.hlGreen)
                                .cornerRadius(12)
                        }
                        .disabled(passwordInput.isEmpty)
                        .padding(.horizontal, 40)
                    }
                }
                .padding(.bottom, 60)
            }
            .animation(.easeInOut(duration: 0.2), value: wallet.authError)
            .animation(.easeInOut(duration: 0.2), value: showPasswordField)
        }
    }

    // MARK: - Password section

    private var passwordSection: some View {
        VStack(spacing: 12) {
            Text("Enter your password")
                .font(.system(size: 14))
                .foregroundColor(Color(white: 0.5))

            HStack {
                if showPassword {
                    TextField("Password", text: $passwordInput)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onSubmit { submitPassword() }
                } else {
                    SecureField("Password", text: $passwordInput)
                        .textContentType(.password)
                        .onSubmit { submitPassword() }
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
            .padding(.horizontal, 40)

            if let error = passwordError {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundColor(.tradingRed)
                    .transition(.opacity)
            }
        }
    }

    private func submitPassword() {
        passwordError = nil
        guard !passwordInput.isEmpty else { return }

        if wallet.verifyPassword(passwordInput) {
            wallet.isUnlocked = true
            wallet.authError = nil
        } else {
            attempts += 1
            passwordError = "Wrong password"
            passwordInput = ""
            // Add a small delay after multiple failed attempts
            if attempts >= 3 {
                passwordError = "Wrong password — \(attempts) attempts"
            }
        }
    }
}
