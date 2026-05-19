import Foundation
import Observation
import os.log
import StoreKit

// MARK: - Notifications

extension Notification.Name {
    /// Posted when free AI usage is exhausted and the app should present `PaywallView`.
    static let chatTaskPresentPaywall = Notification.Name("ChatTaskPresentPaywall")
}

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

    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ChatTask", category: "StoreKit")

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

    /// Persisted count of **successful** AI (LLM) chat actions while the user was not subscribed.
    /// Increment only after a successful task change from an LLM-backed parse; subscribed users bypass the limit.
    private(set) var freeAIParseSuccessCount: Int {
        didSet { UserDefaults.standard.set(freeAIParseSuccessCount, forKey: Keys.freeAIParseSuccessCount) }
    }

    // MARK: - Private

    private var listenerTask: Task<Void, Never>?

    // MARK: - Init / deinit

    init() {
        isProUnlocked       = UserDefaults.standard.bool(forKey: Keys.isProUnlocked)
        paywallWasDismissed = UserDefaults.standard.bool(forKey: Keys.paywallWasDismissed)
        freeAIParseSuccessCount = UserDefaults.standard.integer(forKey: Keys.freeAIParseSuccessCount)
        #if DEBUG
        print("[PaywallGate] SubscriptionManager init isProUnlocked=\(isProUnlocked) freeAIUsage=\(freeAIParseSuccessCount)/\(SubscriptionConfig.freeAIParseAllowance)")
        #endif
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
        monthlyProduct = nil
        yearlyProduct = nil

        let requestedIDs = SubscriptionProductID.all
        Self.log.info("[StoreKit] productsRequested ids=\(Self.jsonIDs(requestedIDs), privacy: .public)")

        do {
            let products = try await Product.products(for: requestedIDs)
            let loadedIDs = products.map(\.id)
            let missing = Set(requestedIDs).subtracting(loadedIDs)

            Self.log.info("[StoreKit] productsLoaded ids=\(Self.jsonIDs(loadedIDs), privacy: .public)")
            for id in missing.sorted() {
                Self.log.warning("[StoreKit] productMissing id=\(id, privacy: .public)")
            }

            for product in products {
                switch product.id {
                case SubscriptionProductID.monthly:
                    monthlyProduct = product
                case SubscriptionProductID.yearly:
                    yearlyProduct = product
                default:
                    Self.log.warning("[StoreKit] unexpectedProduct id=\(product.id, privacy: .public)")
                }
            }
        } catch {
            Self.log.error("[StoreKit] productsLoadFailed error=\(String(describing: error), privacy: .public)")
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
        #if DEBUG
        print("[PaywallGate] checkEntitlements isProUnlocked=\(isProUnlocked)")
        #endif
    }

    // MARK: - Purchase

    /// Initiate a purchase for `product`.
    /// Updates `purchaseState` and `isProUnlocked` on the main actor.
    func purchase(_ product: Product) async {
        Self.log.info("[StoreKit] purchaseStarted productID=\(product.id, privacy: .public)")
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

    var remainingFreeAssistantUses: Int {
        guard !isProUnlocked else { return Int.max }
        return max(0, SubscriptionConfig.freeAIParseAllowance - freeAIParseSuccessCount)
    }

    var canUseAssistant: Bool {
        isProUnlocked || remainingFreeAssistantUses > 0
    }

    var shouldShowAssistantPaywall: Bool {
        !canUseAssistant
    }

    /// `true` when the user may run another AI parse (LLM) without subscribing.
    func canUseFreeAIParseSlot() -> Bool {
        canUseAssistant
    }

    /// Call after a **successful** chat outcome driven by an LLM-backed `ParsedCommand`.
    func recordSuccessfulFreeAIParseIfNeeded() {
        guard !isProUnlocked else { return }
        freeAIParseSuccessCount += 1
        Self.log.info("[PaywallGate] freeAIParseSuccessCount=\(self.freeAIParseSuccessCount, privacy: .public) limit=\(SubscriptionConfig.freeAIParseAllowance, privacy: .public)")
        #if DEBUG
        print("[PaywallGate] recorded free AI usage; count=\(freeAIParseSuccessCount)/\(SubscriptionConfig.freeAIParseAllowance) isSubscribed=\(isProUnlocked)")
        #endif
    }

    #if DEBUG
    /// Resets the free AI usage counter (debug only).
    func resetFreeAIParseUsageForDebug() {
        freeAIParseSuccessCount = 0
        print("[PaywallGate] DEBUG reset freeAIParseSuccessCount=0")
    }
    #endif

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
        SubscriptionProductID.all.contains(id)
    }

    private static func jsonIDs(_ ids: [String]) -> String {
        "[\"" + ids.joined(separator: "\",\"") + "\"]"
    }

    private enum Keys {
        static let isProUnlocked          = "subscriptionIsProUnlocked"
        static let paywallWasDismissed    = "subscriptionPaywallDismissed"
        static let freeAIParseSuccessCount = "freeAIParseSuccessCount"
    }
}
