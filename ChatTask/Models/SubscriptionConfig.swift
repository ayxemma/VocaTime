import Foundation
import StoreKit

/// Centralized subscription pricing and product configuration.
///
/// Update product IDs and pricing here when wiring up StoreKit or RevenueCat.
/// Nothing else in the app should hard-code subscription values.
enum SubscriptionConfig {

    // MARK: - App Store product identifiers

    /// Must match App Store Connect exactly (`com.chattask.monthly`).
    static let monthlyProductID = "com.chattask.monthly"
    /// Must match App Store Connect exactly (`com.chattask.yearly.v1`).
    static let yearlyProductID  = "com.chattask.yearly.v1"

    // MARK: - Trial copy (single source of truth; must match App Store Connect introductory offer)

    /// Lower-sentence trial phrase for English UI. Localized paywall strings use per-language equivalents.
    static let trialText = "1-week free trial"

    // MARK: - Pricing

    static let monthlyPrice   = 2.99   // USD
    static let yearlyPrice    = 24.99  // USD

    // MARK: - Introductory offer (StoreKit)

    /// English trial phrase from the product’s introductory offer when available; otherwise `trialText`.
    static func resolvedTrialPhrase(for product: Product?) -> String {
        guard let period = product?.subscription?.introductoryOffer?.period else {
            return trialText
        }
        return englishTrialPhrase(for: period) ?? trialText
    }

    static func trialBannerBadge(for product: Product?) -> String {
        resolvedTrialPhrase(for: product).uppercased()
    }

    private static func englishTrialPhrase(for period: Product.SubscriptionPeriod) -> String? {
        let value = period.value
        switch period.unit {
        case .day:
            if value == 7 { return trialText }
            if value == 1 { return "1-day free trial" }
            return "\(value)-day free trial"
        case .week:
            if value == 1 { return trialText }
            return "\(value)-week free trial"
        case .month:
            if value == 1 { return "1-month free trial" }
            return "\(value)-month free trial"
        case .year:
            if value == 1 { return "1-year free trial" }
            return "\(value)-year free trial"
        @unknown default:
            return nil
        }
    }

    // MARK: - Paywall trigger

    /// The paywall is presented after the user has created this many tasks,
    /// ensuring they experience the app before being asked to subscribe.
    static let paywallTriggerTaskCount = 3

    // MARK: - User-facing copy

    enum Copy {
        // Header
        static let appName        = "ChatTask"
        static let headline       = "Turn voice into tasks instantly"
        static let subheadline    = "Create and manage tasks by voice or chat."

        // Trial (keep labels aligned with App Store Connect introductory offer)
        static let trialBadge: String = SubscriptionConfig.trialText.uppercased()
        static let ctaTitle       = "Start your \(SubscriptionConfig.trialText)"
        static let pricingDetail  = "Then $2.99/month or $24.99/year"

        // Benefits
        static let benefits: [(icon: String, text: String)] = [
            ("mic.fill",           "Unlimited AI voice tasks"),
            ("bell.badge.fill",    "Smart reminders"),
            ("globe",              "Multi-language support"),
            ("pencil.and.list.clipboard", "Voice and text task editing"),
        ]

        // Plans
        static let monthlyLabel      = "Monthly"
        static let monthlyPrice      = "$2.99"
        static let monthlyPer        = "/ month"
        static let monthlyDetail     = "$2.99 / month"
        static let monthlyTrial      = SubscriptionConfig.trialText
        static let yearlyLabel       = "Yearly"
        static let yearlyPrice       = "$24.99"
        static let yearlyPer         = "/ year"
        static let yearlyDetail      = "$24.99 / year"
        static let yearlyTrial       = SubscriptionConfig.trialText
        static let yearlyBadge       = "BEST VALUE"
        static let yearlySaving      = "Save 30%"

        // CTA
        static let startTrial        = "Start Free Trial"
        static let notNow            = "Not now"
        static let restore           = "Restore Purchases"

        // Disclosure
        static let disclosure        = "\(SubscriptionConfig.trialText), then $2.99/month or $24.99/year."
        static let renewalNotice     = "Auto-renews unless canceled."
        static let cancelAnytime     = "Cancel anytime."

        // Legacy aliases kept for any existing callers
        static let maybeLater        = notNow
    }
}
