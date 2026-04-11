import SwiftUI
import UIKit

@main
struct SpotifyDisplayApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        let nav = UINavigationBarAppearance()
        nav.configureWithOpaqueBackground()
        nav.backgroundColor = .white
        nav.shadowColor = .clear
        let bar = UINavigationBar.appearance()
        bar.standardAppearance = nav
        bar.compactAppearance = nav
        bar.scrollEdgeAppearance = nav
        bar.compactScrollEdgeAppearance = nav
        bar.isTranslucent = false
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                Color.white
                    .ignoresSafeArea(edges: .all)
                ContentView()
            }
            .preferredColorScheme(.light)
        }
    }
}
