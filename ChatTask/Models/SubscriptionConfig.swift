import Foundation

/// Centralized subscription pricing and product configuration.
///
/// Update product IDs and pricing here when wiring up StoreKit or RevenueCat.
/// Nothing else in the app should hard-code subscription values.
enum SubscriptionConfig {

    // MARK: - App Store product identifiers

    static let monthlyProductID = "com.chattask.pro.monthly"
    static let yearlyProductID  = "com.chattask.pro.yearly"

    // MARK: - Pricing

    static let trialDays: Int = 5
    static let monthlyPrice   = 2.99   // USD
    static let yearlyPrice    = 24.99  // USD

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

        // Trial
        static let trialBadge     = "5-DAY FREE TRIAL"
        static let ctaTitle       = "Start your 5-day free trial"
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
        static let monthlyTrial      = "5-day free trial"
        static let yearlyLabel       = "Yearly"
        static let yearlyPrice       = "$24.99"
        static let yearlyPer         = "/ year"
        static let yearlyDetail      = "$24.99 / year"
        static let yearlyTrial       = "5-day free trial"
        static let yearlyBadge       = "BEST VALUE"
        static let yearlySaving      = "Save 30%"

        // CTA
        static let startTrial        = "Start Free Trial"
        static let notNow            = "Not now"
        static let restore           = "Restore Purchases"

        // Disclosure
        static let disclosure        = "5-day free trial, then $2.99/month or $24.99/year."
        static let renewalNotice     = "Auto-renews unless canceled."
        static let cancelAnytime     = "Cancel anytime."

        // Legacy aliases kept for any existing callers
        static let maybeLater        = notNow
    }
}
