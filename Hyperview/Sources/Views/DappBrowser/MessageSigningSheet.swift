import SwiftUI

struct MessageSigningSheet: View {
    let pending: PendingSign
    let onSign: () -> Void
    let onReject: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color(white: 0.3))
                .frame(width: 40, height: 4)
                .padding(.top, 10)

            Text("Sign Message")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.white)
                .padding(.top, 16)
                .padding(.bottom, 20)

            ScrollView {
                Text(pending.message)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(Color(white: 0.8))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(Color(white: 0.11))
                    .cornerRadius(10)
            }
            .padding(.horizontal, 20)
            .frame(maxHeight: 200)

            Spacer()

            HStack(spacing: 12) {
                Button(action: onReject) {
                    Text("Reject")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color(white: 0.18))
                        .cornerRadius(12)
                }

                Button(action: onSign) {
                    Text("Sign")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.hlGreen)
                        .cornerRadius(12)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 30)
        }
        .background(Color.hlBackground.ignoresSafeArea())
        .presentationDetents([.medium])
    }
}
