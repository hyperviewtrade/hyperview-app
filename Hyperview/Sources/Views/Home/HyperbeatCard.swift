import SwiftUI

struct HyperbeatCard: View {
    let onOpen: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Liquid Bank Account")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                Text("Powered by Hyperbeat")
                    .font(.system(size: 11))
                    .foregroundColor(Color(white: 0.5))
            }

            Spacer()

            Button(action: onOpen) {
                Text("Open")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.black)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.hlGreen)
                    .cornerRadius(8)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(white: 0.11))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color(white: 0.18), lineWidth: 1)
                )
        )
    }
}
