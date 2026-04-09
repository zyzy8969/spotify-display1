import UIKit
import AuthenticationServices

/// Supplies a window for `ASWebAuthenticationSession`.
final class SpotifyAuthPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        if let scene {
            return scene.windows.first { $0.isKeyWindow } ?? scene.windows.first ?? ASPresentationAnchor()
        }
        return ASPresentationAnchor()
    }
}
