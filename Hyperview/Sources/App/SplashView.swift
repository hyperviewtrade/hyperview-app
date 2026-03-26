import SwiftUI

struct SplashView: View {
    @State private var logoScale: CGFloat = 1.0
    @State private var logoOpacity: Double = 1.0
    @State private var textOpacity: Double = 1.0
    @State private var glowScale: CGFloat = 0.8
    @State private var glowOpacity: Double = 0.0

    var body: some View {
        ZStack {
            Color.hlBackground.ignoresSafeArea()

            // Glow effect behind logo — independent animation
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.hlGreen.opacity(0.35), Color.hlGreen.opacity(0.08), Color.clear],
                        center: .center,
                        startRadius: 5,
                        endRadius: 150
                    )
                )
                .frame(width: 300, height: 300)
                .opacity(glowOpacity)
                .scaleEffect(glowScale)
                .blur(radius: 20)

            VStack(spacing: 16) {
                Image("HyperviewLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 80, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .scaleEffect(logoScale)
                    .opacity(logoOpacity)

                Text("Hyperview")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .opacity(textOpacity)
            }
        }
        .onAppear {
            startAnimation()
        }
    }

    private func startAnimation() {
        // Glow: smooth pulse independently (0s - 3.5s)
        withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
            glowOpacity = 0.7
            glowScale = 1.1
        }

        // Logo: subtle pulse (0s - 3s)
        withAnimation(.easeInOut(duration: 1.3).repeatCount(2, autoreverses: true)) {
            logoScale = 1.08
        }

        // Phase 2: Contract before explosion (3.2s)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) {
            // Stop glow pulsing — set to steady
            withAnimation(.easeIn(duration: 0.15)) {
                logoScale = 0.9
                glowOpacity = 0.3
                glowScale = 0.9
            }
        }

        // Phase 3: EXPLOSION zoom — ends at exactly 5s (3.5s + 1.5s = 5s)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
            withAnimation(.easeIn(duration: 1.5)) {
                logoScale = 15.0
                logoOpacity = 0
                textOpacity = 0
                glowOpacity = 0
                glowScale = 3.0
            }
        }
    }
}
