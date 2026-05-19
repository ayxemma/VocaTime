import Foundation

/// App Store Connect subscription product identifiers (single source of truth).
enum SubscriptionProductID {
    static let monthly = "com.chattask.monthly"
    static let yearly  = "com.chattask.yearly.v1"
    static let all     = [monthly, yearly]
}
