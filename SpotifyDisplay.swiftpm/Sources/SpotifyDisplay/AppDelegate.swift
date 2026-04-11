import UIKit

/// Ensures `UIWindow` and root hosting controller backgrounds are white (avoids gray strips behind SwiftUI).
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sceneActivated),
            name: UIScene.didActivateNotification,
            object: nil
        )
        Self.paintWindowsWhite()
        UITableView.appearance().backgroundColor = .white
        return true
    }

    @objc private func sceneActivated() {
        Self.paintWindowsWhite()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    static func paintWindowsWhite() {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                window.backgroundColor = .white
                window.overrideUserInterfaceStyle = .light
                if let root = window.rootViewController?.view {
                    root.backgroundColor = .white
                    root.isOpaque = true
                }
            }
        }
    }
}
