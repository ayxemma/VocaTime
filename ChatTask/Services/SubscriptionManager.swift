import Foundation
import Observation
import StoreKit

// MARK: - Purchase state

enum PurchaseState: Equatable {
    case idle
    case purchasing
    case restoring
    case failed(String)
}

// MARK: - SubscriptionManager

/// App-wide subscription manager using StoreKit 2.
///
/// Lifecycle:
///   1. Call `startListeningForTransactions()` once at app launch to handle
///      background renewals and deferred purchases.
///   2. Call `checkEntitlements()` at launch to restore state after relaunch.
///   3. Call `loadProducts()` to fetch product metadata for the paywall UI.
///   4. Call `purchase(_:)` when the user selects a plan.
///   5. Call `restorePurchases()` from the paywall restore button.
///
/// To integrate a server-side receipt check later, add it inside
/// `checkEntitlements()` before setting `isProUnlocked`.
@MainActor
@Observable
final class SubscriptionManager {

    // MARK: - Products

    private(set) var monthlyProduct: Product?
    private(set) var yearlyProduct: Product?

    // MARK: - Entitlement state

    /// `true` when the user holds an active Pro subscription.
    /// Persisted in UserDefaults as a launch-time cache so the UI is correct
    /// before the async `checkEntitlements()` call resolves.
    private(set) var isProUnlocked: Bool {
        didSet { UserDefaults.standard.set(isProUnlocked, forKey: Keys.isProUnlocked) }
    }

    // MARK: - Purchase flow state

    private(set) var purchaseState: PurchaseState = .idle

    // MARK: - Paywall presentation state

    /// `true` after the user explicitly dismisses the paywall without subscribing.
    private(set) var paywallWasDismissed: Bool {
        didSet { UserDefaults.standard.set(paywallWasDismissed, forKey: Keys.paywallWasDismissed) }
    }

    // MARK: - Private

    private var listenerTask: Task<Void, Never>?

    // MARK: - Init / deinit

    init() {
        isProUnlocked       = UserDefaults.standard.bool(forKey: Keys.isProUnlocked)
        paywallWasDismissed = UserDefaults.standard.bool(forKey: Keys.paywallWasDismissed)
    }

    // MARK: - App launch startup

    /// Begin observing StoreKit transaction updates.
    /// Must be called once, early in the app lifecycle (before any purchases).
    func startListeningForTransactions() {
        listenerTask = Task.detached(priority: .background) { [weak self] in
            for await result in Transaction.updates {
                await self?.handle(transactionResult: result)
            }
        }
    }

    /// Fetch product metadata from App Store or the active StoreKit configuration.
    /// Safe to call on every launch; results are used to show live prices in the paywall.
    func loadProducts() async {
        do {
            let products = try await Product.products(for: [
                SubscriptionConfig.monthlyProductID,
                SubscriptionConfig.yearlyProductID,
            ])
            for product in products {
                switch product.id {
                case SubscriptionConfig.monthlyProductID: monthlyProduct = product
                case SubscriptionConfig.yearlyProductID:  yearlyProduct  = product
                default: break
                }
            }
        } catch {
            // Products unavailable — paywall falls back to hard-coded copy.
        }
    }

    /// Verify current entitlements and update `isProUnlocked`.
    /// Call on launch and after `restorePurchases()`.
    func checkEntitlements() async {
        var hasActive = false
        for await result in Transaction.currentEntitlements {
            guard case .verified(let tx) = result else { continue }
            if isProProduct(tx.productID) {
                hasActive = true
            }
            await tx.finish()
        }
        isProUnlocked = hasActive
    }

    // MARK: - Purchase

    /// Initiate a purchase for `product`.
    /// Updates `purchaseState` and `isProUnlocked` on the main actor.
    func purchase(_ product: Product) async {
        purchaseState = .purchasing
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                do {
                    let tx = try checkVerified(verification)
                    await tx.finish()
                    isProUnlocked = true
                    purchaseState = .idle
                } catch {
                    purchaseState = .failed(error.localizedDescription)
                }
            case .userCancelled:
                purchaseState = .idle
            case .pending:
                // Awaiting approval (e.g. Ask to Buy) — treat as not-yet-purchased.
                purchaseState = .idle
            @unknown default:
                purchaseState = .idle
            }
        } catch {
            purchaseState = .failed(error.localizedDescription)
        }
    }

    // MARK: - Restore

    /// Sync with the App Store to restore previous purchases.
    func restorePurchases() async {
        purchaseState = .restoring
        do {
            try await AppStore.sync()
            await checkEntitlements()
            purchaseState = .idle
        } catch {
            purchaseState = .failed(error.localizedDescription)
        }
    }

    // MARK: - Error handling

    func clearPurchaseError() {
        if case .failed = purchaseState { purchaseState = .idle }
    }

    // MARK: - Paywall presentation logic

    var isPremium: Bool { isProUnlocked }

    /// Returns `true` when the paywall should be presented.
    /// Never `true` on first launch — requires the user to have created
    /// at least `SubscriptionConfig.paywallTriggerTaskCount` tasks first.
    func shouldShowPaywall(taskCount: Int) -> Bool {
        !isProUnlocked && !paywallWasDismissed
            && taskCount >= SubscriptionConfig.paywallTriggerTaskCount
    }

    /// Records that the user dismissed the paywall without subscribing.
    func dismissPaywall() {
        paywallWasDismissed = true
    }

    /// Directly grant pro access (e.g. for debugging or future promo codes).
    func grantPremium() {
        isProUnlocked = true
    }

    // MARK: - Private helpers

    private func handle(transactionResult result: VerificationResult<Transaction>) async {
        guard case .verified(let tx) = result else { return }
        await tx.finish()
        await checkEntitlements()
    }

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified(_, let error): throw error
        case .verified(let value):      return value
        }
    }

    private func isProProduct(_ id: String) -> Bool {
        id == SubscriptionConfig.monthlyProductID || id == SubscriptionConfig.yearlyProductID
    }

    private enum Keys {
        static let isProUnlocked       = "subscriptionIsProUnlocked"
        static let paywallWasDismissed = "subscriptionPaywallDismissed"
    }
}
