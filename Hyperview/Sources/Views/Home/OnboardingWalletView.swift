import SwiftUI
import UserNotifications

struct OnboardingWalletView: View {
    @ObservedObject private var wallet = WalletManager.shared

    /// 0 = wallet created + keychain info, 1 = create password, 2 = notifications, 3 = Face ID
    @State private var step = 0

    // Password fields
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var passwordError: String?
    @State private var showPassword = false
    @State private var showConfirmPassword = false

    enum PasswordField { case password, confirm }
    @FocusState private var focusedField: PasswordField?

    var body: some View {
        ZStack {
            Color.hlBackground.ignoresSafeArea()

            switch step {
            case 1:  createPasswordScreen
            case 2:  notificationsScreen
            case 3:  faceIDScreen
            default: walletCreatedScreen
            }
        }
        .animation(.easeInOut(duration: 0.25), value: step)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Button {
                    switch focusedField {
                    case .confirm: focusedField = .password
                    default: break
                    }
                } label: {
                    Image(systemName: "chevron.up")
                }
                .disabled(focusedField == .password)

                Button {
                    switch focusedField {
                    case .password: focusedField = .confirm
                    default: break
                    }
                } label: {
                    Image(systemName: "chevron.down")
                }
                .disabled(focusedField == .confirm)

                Spacer()

                Button("Done") {
                    focusedField = nil
                }
                .fontWeight(.semibold)
                .foregroundColor(.hlGreen)
            }
        }
    }

    // MARK: - Step 0: Wallet created + Keychain info

    private var walletCreatedScreen: some View {
        VStack(spacing: 28) {
            Spacer()

            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 52))
                .foregroundColor(.hlGreen)

            VStack(spacing: 8) {
                Text("EVM Wallet Created")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.white)
                Text("Your wallet is ready to use")
                    .font(.system(size: 14))
                    .foregroundColor(Color(white: 0.5))
            }

            if let addr = wallet.connectedWallet?.address {
                VStack(spacing: 4) {
                    Text("Your address")
                        .font(.system(size: 12))
                        .foregroundColor(Color(white: 0.4))
                    Text(addr)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .padding(10)
                        .background(Color.hlSurface)
                        .cornerRadius(8)
                }
                .padding(.horizontal, 20)
            }

            // Keychain info card
            VStack(alignment: .leading, spacing: 14) {
                infoItem(icon: "lock.fill", title: "Hardware encrypted",
                         text: "Your private key is stored in the iOS Keychain, protected by the Secure Enclave chip.")

                infoItem(icon: "iphone.and.arrow.forward", title: "Device-only",
                         text: "The key never leaves your device. It is not included in iCloud backups.")

                infoItem(icon: "key.fill", title: "Export anytime",
                         text: "You can export your private key from Settings if you ever need a backup.")
            }
            .padding(16)
            .background(Color.hlCardBackground)
            .cornerRadius(12)
            .padding(.horizontal, 20)

            Spacer()

            Button {
                step = 1
            } label: {
                Text("Continue")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.hlGreen)
                    .cornerRadius(12)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 30)
        }
    }

    // MARK: - Step 1: Create password

    private var createPasswordScreen: some View {
        VStack(spacing: 0) {
            backButton(to: 0)

            Spacer()

            VStack(spacing: 20) {
                Image(systemName: "lock.rectangle.on.rectangle")
                    .font(.system(size: 40))
                    .foregroundColor(.hlGreen)

                Text("Create a Password")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.white)

                Text("This password protects your wallet. You'll need it to unlock the app and confirm transactions.")
                    .font(.system(size: 13))
                    .foregroundColor(Color(white: 0.5))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)

                VStack(spacing: 12) {
                    // Password field
                    HStack {
                        if showPassword {
                            TextField("Password", text: $password)
                                .textContentType(.newPassword)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .focused($focusedField, equals: .password)
                                .submitLabel(.next)
                                .onSubmit { focusedField = .confirm }
                        } else {
                            SecureField("Password", text: $password)
                                .textContentType(.newPassword)
                                .focused($focusedField, equals: .password)
                                .submitLabel(.next)
                                .onSubmit { focusedField = .confirm }
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

                    // Confirm password field
                    HStack {
                        if showConfirmPassword {
                            TextField("Confirm Password", text: $confirmPassword)
                                .textContentType(.newPassword)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .focused($focusedField, equals: .confirm)
                                .submitLabel(.done)
                                .onSubmit { if isPasswordValid { submitPassword() } }
                        } else {
                            SecureField("Confirm Password", text: $confirmPassword)
                                .textContentType(.newPassword)
                                .focused($focusedField, equals: .confirm)
                                .submitLabel(.done)
                                .onSubmit { if isPasswordValid { submitPassword() } }
                        }
                        Button { showConfirmPassword.toggle() } label: {
                            Image(systemName: showConfirmPassword ? "eye.slash" : "eye")
                                .foregroundColor(Color(white: 0.4))
                                .font(.system(size: 14))
                        }
                    }
                    .font(.system(size: 15))
                    .foregroundColor(.white)
                    .padding(14)
                    .background(Color.hlSurface)
                    .cornerRadius(10)

                    // Password requirements
                    VStack(alignment: .leading, spacing: 4) {
                        requirementRow("At least 8 characters", met: password.count >= 8)
                        requirementRow("One uppercase letter", met: password.contains(where: { $0.isUppercase }))
                        requirementRow("One lowercase letter", met: password.contains(where: { $0.isLowercase }))
                        requirementRow("One number", met: password.contains(where: { $0.isNumber }))
                        if !confirmPassword.isEmpty {
                            requirementRow("Passwords match", met: password == confirmPassword)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if let error = passwordError {
                        Text(error)
                            .font(.system(size: 12))
                            .foregroundColor(.tradingRed)
                    }
                }
                .padding(.horizontal, 20)
            }

            Spacer()

            Button {
                submitPassword()
            } label: {
                Text("Set Password — Continue")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(isPasswordValid ? .black : Color(white: 0.4))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(isPasswordValid ? Color.hlGreen : Color.hlGreen.opacity(0.3))
                    .cornerRadius(12)
            }
            .disabled(!isPasswordValid)
            .padding(.horizontal, 20)
            .padding(.bottom, 30)
        }
    }

    private var isPasswordValid: Bool {
        WalletManager.validatePasswordStrength(password) == nil && password == confirmPassword && !password.isEmpty
    }

    private func submitPassword() {
        if let err = WalletManager.validatePasswordStrength(password) {
            passwordError = err
            return
        }
        if password != confirmPassword {
            passwordError = "Passwords don't match"
            return
        }
        passwordError = nil
        wallet.setPassword(password)
        step = 2
    }

    private func requirementRow(_ text: String, met: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: met ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 11))
                .foregroundColor(met ? .hlGreen : Color(white: 0.3))
            Text(text)
                .font(.system(size: 11))
                .foregroundColor(met ? .hlGreen : Color(white: 0.4))
        }
    }

    // MARK: - Step 2: Notifications

    private var notificationsScreen: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 20) {
                Image(systemName: "bell.badge.fill")
                    .font(.system(size: 48))
                    .foregroundColor(.hlGreen)

                Text("Enable Notifications")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.white)

                Text("Get alerted on whale trades, liquidations and important market moves in real time.")
                    .font(.system(size: 14))
                    .foregroundColor(Color(white: 0.5))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
            }

            Spacer()

            VStack(spacing: 10) {
                Button {
                    Task {
                        let center = UNUserNotificationCenter.current()
                        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
                        step = 3
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "bell.fill")
                        Text("Enable Notifications")
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.hlGreen)
                    .cornerRadius(12)
                }

                Button { step = 3 } label: {
                    Text("Not Now")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(Color(white: 0.5))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 30)
        }
    }

    // MARK: - Step 3: Face ID

    private var faceIDScreen: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 20) {
                Image(systemName: "faceid")
                    .font(.system(size: 48))
                    .foregroundColor(.hlGreen)

                Text("Unlock with Face ID")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.white)

                Text("Use Face ID for quick access instead of typing your password every time.")
                    .font(.system(size: 14))
                    .foregroundColor(Color(white: 0.5))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
            }

            Spacer()

            VStack(spacing: 10) {
                Button {
                    Task {
                        _ = await wallet.requestBiometricSetup()
                        wallet.hasCompletedOnboarding = true
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "faceid")
                        Text("Enable Face ID")
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.hlGreen)
                    .cornerRadius(12)
                }

                Button {
                    wallet.hasCompletedOnboarding = true
                } label: {
                    Text("Use Password Only")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(Color(white: 0.5))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 30)
        }
    }

    // MARK: - Helpers

    private func backButton(to targetStep: Int) -> some View {
        HStack {
            Button { step = targetStep } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                    Text("Back")
                }
                .font(.system(size: 15))
                .foregroundColor(.hlGreen)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
    }

    private func infoItem(icon: String, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(.hlGreen)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                Text(text)
                    .font(.system(size: 12))
                    .foregroundColor(Color(white: 0.5))
            }
        }
    }
}
