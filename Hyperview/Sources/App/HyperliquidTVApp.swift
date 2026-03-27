import SwiftUI
import UserNotifications
import BackgroundTasks

// MARK: - AppDelegate — handles notifications + background liquidation checks

class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    static let bgTaskId = "com.Hyperview.liqCheck"

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self

        // Register background task for liquidation checks (fallback)
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.bgTaskId, using: nil) { task in
            self.handleBackgroundLiqCheck(task as! BGAppRefreshTask)
        }

        // Register for remote (push) notifications
        application.registerForRemoteNotifications()

        return true
    }

    // MARK: - APNs Token

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        print("[push] Device token: \(token)")
        PushRegistrationService.shared.deviceToken = token
        // Sync rules to backend with this token
        Task { await PushRegistrationService.shared.syncRulesToBackend() }
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("[push] Failed to register for remote notifications: \(error)")
    }

    // MARK: - Background Liquidation Check

    private func handleBackgroundLiqCheck(_ task: BGAppRefreshTask) {
        // Schedule next check immediately
        scheduleBackgroundLiqCheck()

        let checkTask = Task {
            await LiquidationNotificationService.shared.checkForNewLiquidations()
        }

        task.expirationHandler = {
            checkTask.cancel()
        }

        Task {
            await checkTask.value
            task.setTaskCompleted(success: true)
        }
    }

    /// Schedule the next background refresh. Call on app launch and after each BG task.
    func scheduleBackgroundLiqCheck() {
        let request = BGAppRefreshTaskRequest(identifier: Self.bgTaskId)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 5 * 60) // min 5 min
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            print("[BG] Failed to schedule liq check: \(error)")
        }
    }

    // MARK: - Notification Handling

    /// Called when user taps a notification -> navigate to Liquidations section.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let userInfo = response.notification.request.content.userInfo
        let notifType = userInfo["type"] as? String

        await MainActor.run {
            if notifType == "liquidation" {
                // Navigate to Home tab → Liquidations section
                AppState.shared.selectedTab = 0
                AppState.shared.pendingLiquidationOpen = true
                print("[LIQ NOTIFICATION TAP] type=liquidation, navigating to Liquidations")
            } else if let address = userInfo["walletAddress"] as? String {
                // Fallback: open wallet detail
                AppState.shared.selectedTab = 0
                AppState.shared.pendingWalletAddress = address
            }
        }
    }

    /// Show notification banners even when app is in foreground.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

// MARK: - App

@main
struct HyperliquidTVApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    init() {
        configureAppearance()
        KeyboardDoneBarSetup.install()
        IconCacheService.shared.refreshIfNeeded()

        // Connect backend relay at app launch
        RelayClient.shared.connect()

        // HIP-3 display names fetched later by MarketsViewModel (Phase 2 background task)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                // Schedule background liq check when app goes to background
                appDelegate.scheduleBackgroundLiqCheck()
            }
        }
    }

    private func configureAppearance() {
        let nav = UINavigationBarAppearance()
        nav.configureWithOpaqueBackground()
        nav.backgroundColor = UIColor(white: 0.07, alpha: 1)
        nav.titleTextAttributes = [.foregroundColor: UIColor.white]
        nav.largeTitleTextAttributes = [.foregroundColor: UIColor.white]
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav

        let tab = UITabBarAppearance()
        tab.configureWithOpaqueBackground()
        tab.backgroundColor = UIColor(red: 0.08, green: 0.08, blue: 0.09, alpha: 1)
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab
    }
}
