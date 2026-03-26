import Foundation
import UserNotifications

/// Standalone service for checking liquidation notifications.
/// Works both in-app (called by LiquidationsViewModel) and in background (BGAppRefreshTask).
final class LiquidationNotificationService {
    static let shared = LiquidationNotificationService()

    private let backendURL = Configuration.backendBaseURL
    private let notifiedKey = "liq_notified_ids"
    private let rulesKey = "liq_notification_rules"

    /// Check latest liquidations against saved rules and send local notifications.
    /// Safe to call from any context (foreground or background).
    func checkForNewLiquidations() async {
        // Load rules from UserDefaults
        guard let rulesData = UserDefaults.standard.data(forKey: rulesKey),
              let rules = try? JSONDecoder().decode([NotificationRule].self, from: rulesData),
              !rules.isEmpty
        else { return }

        // Fetch latest liquidations
        guard let url = URL(string: "\(backendURL)/liquidations?limit=50"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let response = try? JSONDecoder().decode(LiquidationsResponse.self, from: data)
        else { return }

        // Load notified IDs from disk (persisted across launches)
        var notifiedIds = Set(UserDefaults.standard.stringArray(forKey: notifiedKey) ?? [])

        var newNotifications = 0
        for liq in response.liquidations {
            guard !notifiedIds.contains(liq.id) else { continue }
            notifiedIds.insert(liq.id)

            if matchesAnyRule(liq, rules: rules) {
                sendNotification(liq)
                newNotifications += 1
            }
        }

        // Trim to keep only current IDs (prevent unbounded growth)
        let currentIds = Set(response.liquidations.map(\.id))
        notifiedIds = notifiedIds.intersection(currentIds)
        UserDefaults.standard.set(Array(notifiedIds), forKey: notifiedKey)

        if newNotifications > 0 {
            print("[BG] Sent \(newNotifications) liquidation notification(s)")
        }
    }

    /// Sync in-memory notified IDs to disk (called by ViewModel during foreground polling).
    func persistNotifiedIds(_ ids: Set<String>) {
        UserDefaults.standard.set(Array(ids), forKey: notifiedKey)
    }

    /// Load persisted notified IDs (called by ViewModel on init).
    func loadPersistedNotifiedIds() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: notifiedKey) ?? [])
    }

    // MARK: - Private

    private func matchesAnyRule(_ liq: LiquidationItem, rules: [NotificationRule]) -> Bool {
        for rule in rules {
            guard rule.coin == liq.coin && liq.sizeUSD >= rule.minSize else { continue }
            switch rule.direction {
            case .both:  return true
            case .long:  if liq.isLong { return true }
            case .short: if !liq.isLong { return true }
            }
        }
        return false
    }

    private func sendNotification(_ liq: LiquidationItem) {
        let content = UNMutableNotificationContent()
        content.title = "\(liq.coin) \(liq.side) Liquidation"
        content.body = "\(liq.formattedSize) liquidated @ \(liq.formattedPrice)"
        content.sound = .default
        content.userInfo = ["walletAddress": liq.address, "type": "liquidation"]

        let request = UNNotificationRequest(
            identifier: "liq-\(liq.id)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
