import SwiftUI

struct TransactionApprovalSheet: View {
    let tx: PendingTransaction
    let onConfirm: () -> Void
    let onReject: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color(white: 0.3))
                .frame(width: 40, height: 4)
                .padding(.top, 10)

            Text("Confirm Transaction")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.white)
                .padding(.top, 16)
                .padding(.bottom, 20)

            VStack(spacing: 12) {
                row(label: "To", value: formatAddress(tx.to))
                row(label: "Value", value: tx.valueEth > 0
                    ? String(format: "%.6f ETH", tx.valueEth) : "0 ETH")
                row(label: "Data", value: tx.dataSize > 0
                    ? "\(tx.dataSize) bytes (contract call)" : "None")
                if tx.estimatedGas > 0 {
                    row(label: "Gas Limit", value: "\(tx.estimatedGas + tx.estimatedGas / 5)")
                }
            }
            .padding(.horizontal, 20)

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

                Button(action: onConfirm) {
                    Text("Confirm")
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

    private func row(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Color(white: 0.5))
            Spacer()
            Text(value)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundColor(.white)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color(white: 0.11))
        .cornerRadius(10)
    }

    private func formatAddress(_ addr: String) -> String {
        guard addr.count > 10 else { return addr }
        return String(addr.prefix(6)) + "..." + String(addr.suffix(4))
    }
}
