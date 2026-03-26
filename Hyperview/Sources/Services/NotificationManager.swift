import Foundation
import Combine
import UserNotifications

// MARK: - NotificationManager
// Handles push notifications for price alerts and trade fills.

@MainActor
final class NotificationManager: ObservableObject {
    static let shared = NotificationManager()

    @Published var isAuthorized = false

    private init() {
        Task { await checkStatus() }
    }

    // MARK: - Authorization

    func requestAuthorization() async {
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
            isAuthorized = granted
        } catch {
            print("⚠️ Notifications auth: \(error)")
        }
    }

    func checkStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        isAuthorized = settings.authorizationStatus == .authorized
    }

    // MARK: - Price Alerts

    func schedulePriceAlert(_ alert: PriceAlert) {
        guard isAuthorized else { return }
        let content = UNMutableNotificationContent()
        content.title = "🔔 \(alert.symbol) Price Alert"
        let dir = alert.condition == .above ? "above" : "below"
        content.body  = "\(alert.symbol) crossed \(dir) $\(formatPrice(alert.price))"
        content.sound = .default

        // Fire immediately (called when price crosses threshold)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        let id      = "price_\(alert.id.uuidString)"
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request) { err in
            if let err { print("⚠️ Notification: \(err)") }
        }
    }

    func cancelAlert(id: UUID) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: ["price_\(id.uuidString)"]
        )
    }

    // MARK: - Trade Fills

    func sendFillNotification(symbol: String, side: String, size: Double, price: Double) {
        guard isAuthorized else { return }
        let content = UNMutableNotificationContent()
        content.title = "✅ Order Filled"
        content.body  = "\(side.uppercased()) \(formatSize(size)) \(symbol) @ \(formatPrice(price))"
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        let request = UNNotificationRequest(
            identifier: "fill_\(UUID().uuidString)",
            content: content,
            trigger: trigger
        )
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    // MARK: - Check active price alerts against live price

    func checkAlerts(symbol: String, price: Double) {
        let alerts = PriceAlert.all.filter { $0.symbol == symbol && $0.isActive }
        for alert in alerts {
            let triggered = alert.condition == .above
                ? price >= alert.price
                : price <= alert.price
            if triggered {
                schedulePriceAlert(alert)
                // Deactivate to avoid re-firing
                var updated = PriceAlert.all
                if let idx = updated.firstIndex(where: { $0.id == alert.id }) {
                    updated[idx].isActive = false
                    PriceAlert.all = updated
                }
            }
        }
    }

    // MARK: - Formatters

    private func formatPrice(_ p: Double) -> String {
        if p >= 1_000 { return String(format: "%.2f", p) }
        if p >= 1     { return String(format: "%.4f", p) }
        return String(format: "%.8f", p)
    }

    private func formatSize(_ s: Double) -> String {
        if s >= 1_000 { return String(format: "%.2fK", s / 1_000) }
        return String(format: "%.4f", s)
    }
}
