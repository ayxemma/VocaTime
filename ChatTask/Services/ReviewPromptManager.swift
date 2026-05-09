import Foundation
import StoreKit
import UIKit

/// Persists successful AI action counts and requests the system review UI at most once (after 5 successes).
@MainActor
final class ReviewPromptManager {

    static let shared = ReviewPromptManager()

    private enum Keys {
        static let successfulAIActionCount = "successfulAIActionCount"
        static let hasRequestedAppReview = "hasRequestedAppReview"
    }

    private let defaults: UserDefaults
    private let requiredSuccessCount = 5

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Call only after the app has fully applied an AI-driven create/update/delete to persistence.
    func recordSuccessfulAIAction() {
        let newCount = defaults.integer(forKey: Keys.successfulAIActionCount) + 1
        defaults.set(newCount, forKey: Keys.successfulAIActionCount)
        print("[ReviewPrompt] successfulAIActionCount=\(newCount)")
        maybeRequestReview()
    }

    /// Invoked automatically from `recordSuccessfulAIAction`; exposed for tests or unusual call sites.
    func maybeRequestReview() {
        guard !defaults.bool(forKey: Keys.hasRequestedAppReview) else {
            print("[ReviewPrompt] requestReview skipped — hasRequestedAppReview already true")
            return
        }
        let count = defaults.integer(forKey: Keys.successfulAIActionCount)
        guard count >= requiredSuccessCount else { return }
        guard let scene = Self.preferredWindowSceneForReview() else {
            print("[ReviewPrompt] requestReview skipped — no UIWindowScene")
            return
        }
        print("[ReviewPrompt] invoking SKStoreReviewController.requestReview(in:) successfulAIActionCount=\(count)")
        SKStoreReviewController.requestReview(in: scene)
        defaults.set(true, forKey: Keys.hasRequestedAppReview)
    }

    /// Prefer the foreground-active scene; fall back to foreground-inactive so review can still run during transitions.
    private static func preferredWindowSceneForReview() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive }
            ?? scenes.first { $0.activationState == .foregroundInactive }
    }

    #if DEBUG
    /// Clears persisted review state (debug builds only; not surfaced in production UI).
    func resetReviewPromptState() {
        defaults.removeObject(forKey: Keys.successfulAIActionCount)
        defaults.removeObject(forKey: Keys.hasRequestedAppReview)
        print("[ReviewPrompt] DEBUG resetReviewPromptState — cleared keys")
    }
    #endif
}
