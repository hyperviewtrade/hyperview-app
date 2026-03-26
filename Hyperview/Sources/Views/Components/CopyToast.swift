import SwiftUI

/// Tiny "Copied ✓" toast that fades in/out automatically.
struct CopyToastModifier: ViewModifier {
    @Binding var show: Bool

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if show {
                Text("Copied ✓")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.hlGreen.opacity(0.9))
                    .cornerRadius(20)
                    .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) {
                            withAnimation(.easeOut(duration: 0.25)) { show = false }
                        }
                    }
                    .padding(.top, 8)
            }
        }
        .animation(.easeOut(duration: 0.2), value: show)
    }
}

extension View {
    /// Shows a brief "Copied ✓" toast at the top of the view.
    func copyToast(show: Binding<Bool>) -> some View {
        modifier(CopyToastModifier(show: show))
    }
}

/// Convenience: copies to clipboard and triggers the toast.
func copyWithToast(_ text: String, show: Binding<Bool>) {
    UIPasteboard.general.string = text
    withAnimation(.easeOut(duration: 0.2)) { show.wrappedValue = true }
}
