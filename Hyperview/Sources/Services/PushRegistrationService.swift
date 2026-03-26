import Foundation

/// Manages syncing the APNs device token + liquidation notification rules
/// to the Hyperview backend for real-time push notifications.
@MainActor
final class PushRegistrationService {
    static let shared = PushRegistrationService()

    private let backendURL = Configuration.backendBaseURL
    private let rulesKey = "liq_notification_rules"

    /// APNs device token (hex string), set by AppDelegate on registration
    var deviceToken: String?

    /// Sync current notification rules to the backend.
    /// Called when:
    ///   1. Device token is received (app launch)
    ///   2. User adds/removes/edits a notification rule
    func syncRulesToBackend() async {
        guard let token = deviceToken, !token.isEmpty else {
            print("[push] No device token yet — skipping sync")
            return
        }

        // Load rules from UserDefaults (same key as LiquidationsViewModel)
        let rules: [[String: Any]]
        if let data = UserDefaults.standard.data(forKey: rulesKey),
           let decoded = try? JSONDecoder().decode([NotificationRule].self, from: data) {
            rules = decoded.map { rule in
                [
                    "coin": rule.coin,
                    "minSize": rule.minSize,
                    "direction": rule.direction.rawValue.lowercased(),
                ] as [String: Any]
            }
        } else {
            rules = []
        }

        // POST to backend
        guard let url = URL(string: "\(backendURL)/push/register") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10

        let body: [String: Any] = [
            "deviceToken": token,
            "rules": rules,
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            print("[push] Synced \(rules.count) rules to backend (HTTP \(status))")
        } catch {
            print("[push] Sync failed: \(error.localizedDescription)")
        }
    }

    /// Unregister this device from push notifications.
    func unregister() async {
        guard let token = deviceToken else { return }
        guard let url = URL(string: "\(backendURL)/push/unregister") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["deviceToken": token])
        _ = try? await URLSession.shared.data(for: request)
    }
}
