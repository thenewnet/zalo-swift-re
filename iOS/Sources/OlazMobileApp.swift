import SwiftUI
import UIKit

/// Olaz for iPhone: several Zalo accounts signed in at once, each running the official Zalo PC client code
/// (`ZaloEngine` on its own `AccountScope`), with a native iOS interface.
@main
struct OlazMobileApp: App {
    @UIApplicationDelegateAdaptor(OlazAppDelegate.self) private var appDelegate
    @State private var accounts = AccountsManager()
    @State private var settings = MobileSettings()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            MobileRootView()
                .environment(accounts)
                .environment(settings)
                .onAppear {
                    appDelegate.accounts = accounts
                    accounts.start()
                }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        accounts.appWillEnterForeground()
                        BackgroundKeepAlive.shared.stop()
                        BackgroundKeepAlive.shared.endGracePeriod()
                    case .background:
                        accounts.appDidEnterBackground()
                        if settings.keepAliveInBackground {
                            BackgroundKeepAlive.shared.start()
                        } else {
                            BackgroundKeepAlive.shared.beginGracePeriod()
                        }
                    default:
                        break
                    }
                }
        }
    }
}

final class OlazAppDelegate: NSObject, UIApplicationDelegate {
    @MainActor weak var accounts: AccountsManager?

    func applicationDidReceiveMemoryWarning(_ application: UIApplication) {
        MainActor.assumeIsolated { accounts?.handleMemoryWarning() }
    }
}

/// iOS-only preferences.
@MainActor
@Observable
final class MobileSettings {
    /// Keeps every account connected while the app is in the background (silent audio). On by default: realtime
    /// notifications for all accounts depend on it.
    var keepAliveInBackground: Bool = UserDefaults.standard.object(forKey: "mobile.keepAlive") as? Bool ?? true {
        didSet { UserDefaults.standard.set(keepAliveInBackground, forKey: "mobile.keepAlive") }
    }
}
