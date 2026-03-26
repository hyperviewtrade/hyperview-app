import SwiftUI

/// Animated hourglass loading indicator.
/// Pure local animation — appears instantly on tap, no network needed.
struct WalletLoadingView: View {
    var message: String? = "Loading wallet data…"
    @State private var rotation: Double = 0
    @State private var pulse: Bool = false

    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                // Glow behind the hourglass — fixed frame, only opacity animates
                Circle()
                    .fill(Color.hlGreen.opacity(pulse ? 0.12 : 0.04))
                    .frame(width: 80, height: 80)
            }
            .frame(width: 80, height: 80)
            .overlay {
                Image(systemName: "hourglass")
                    .font(.system(size: 36, weight: .medium))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.hlGreen, Color.hlGreen.opacity(0.5)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .rotationEffect(.degrees(rotation))
            }

            if let message {
                Text(message)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(Color(white: 0.45))
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                pulse = true
            }
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: false)) {
                rotation = 360
            }
        }
    }
}
