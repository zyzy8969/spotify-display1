import UIKit

/// Ensures `UIWindow` and root hosting controller backgrounds are white (avoids gray strips behind SwiftUI).
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        return true
    }
}
