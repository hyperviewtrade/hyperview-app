import SwiftUI

struct DappBrowserView: View {
    @StateObject private var provider = EthereumProvider()
    @Environment(\.dismiss) private var dismiss

    private let url = URL(string: "https://app.hyperbeat.org/pay/app")!

    var body: some View {
        NavigationStack {
            DappWebView(url: url, provider: provider)
                .ignoresSafeArea(edges: .bottom)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { dismiss() } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.white)
                        }
                    }
                    ToolbarItem(placement: .principal) {
                        Text("Hyperbeat")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { provider.reload() } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.white)
                        }
                    }
                }
                .toolbarBackground(Color.hlBackground, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
        }
        .sheet(isPresented: $provider.showTransactionApproval) {
            if let tx = provider.pendingTransaction {
                TransactionApprovalSheet(
                    tx: tx,
                    onConfirm: { provider.approveTransaction() },
                    onReject: { provider.rejectTransaction() }
                )
            }
        }
        .sheet(isPresented: $provider.showSignApproval) {
            if let msg = provider.pendingSignMessage {
                MessageSigningSheet(
                    pending: msg,
                    onSign: { provider.approveSign() },
                    onReject: { provider.rejectSign() }
                )
            }
        }
        .overlay {
            if provider.isProcessing {
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                    .overlay {
                        ProgressView()
                            .tint(.white)
                            .scaleEffect(1.3)
                    }
            }
        }
    }
}
