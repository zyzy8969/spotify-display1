import UIKit
import AuthenticationServices

/// Supplies a window for `ASWebAuthenticationSession`.
/// Prefer key window (including when a sheet/modal is frontmost); avoid empty anchors — `start()` fails silently otherwise.
final class SpotifyAuthPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive }
            .flatMap { $0.windows }

        if let key = windows.first(where: { $0.isKeyWindow }) {
            return key
        }
        if let visible = windows.first(where: { !$0.isHidden && $0.alpha > 0 }) {
            return visible
        }
        let fallback = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { !$0.isHidden }
        return fallback ?? ASPresentationAnchor()
    }
}
