import StoreKit
import SwiftUI

// MARK: - Plan selection

enum SubscriptionPlan: String, CaseIterable, Identifiable {
    case monthly
    case yearly
    var id: String { rawValue }
}

// MARK: - PaywallView

struct PaywallView: View {
    @Environment(SubscriptionManager.self) private var subscriptionManager
    @Environment(\.dismiss) private var dismiss

    @State private var selectedPlan: SubscriptionPlan = .yearly
    @State private var errorMessage = ""
    @State private var showErrorAlert = false

    // MARK: - Derived state

    private var isPurchasing: Bool { subscriptionManager.purchaseState == .purchasing }
    private var isRestoring: Bool  { subscriptionManager.purchaseState == .restoring }
    private var isIdle: Bool       { subscriptionManager.purchaseState == .idle }

    private var selectedProduct: Product? {
        selectedPlan == .monthly
            ? subscriptionManager.monthlyProduct
            : subscriptionManager.yearlyProduct
    }

    private func displayPrice(for plan: SubscriptionPlan) -> String {
        switch plan {
        case .monthly: return subscriptionManager.monthlyProduct?.displayPrice ?? SubscriptionConfig.Copy.monthlyPrice
        case .yearly:  return subscriptionManager.yearlyProduct?.displayPrice  ?? SubscriptionConfig.Copy.yearlyPrice
        }
    }

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color(.systemBackground).ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    headerSection
                        .padding(.top, 56)
                        .padding(.bottom, 28)

                    trialBanner
                        .padding(.horizontal, 20)
                        .padding(.bottom, 28)

                    benefitsSection
                        .padding(.horizontal, 24)
                        .padding(.bottom, 28)

                    planSection
                        .padding(.horizontal, 20)
                        .padding(.bottom, 28)

                    ctaSection
                        .padding(.horizontal, 20)
                        .padding(.bottom, 16)

                    secondaryActions
                        .padding(.bottom, 20)

                    disclosureSection
                        .padding(.horizontal, 28)
                        .padding(.bottom, 36)
                }
            }

            closeButton
                .padding(.top, 12)
                .padding(.trailing, 16)
        }
        .alert("Purchase Failed", isPresented: $showErrorAlert) {
            Button("OK") { subscriptionManager.clearPurchaseError() }
        } message: {
            Text(errorMessage)
        }
        .onChange(of: subscriptionManager.purchaseState) { _, newState in
            if case .failed(let msg) = newState {
                errorMessage = msg
                showErrorAlert = true
            }
        }
        .onChange(of: subscriptionManager.isProUnlocked) { _, unlocked in
            if unlocked { dismiss() }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.10))
                    .frame(width: 80, height: 80)
                Image(systemName: "mic.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(Color.accentColor)
            }

            Text(SubscriptionConfig.Copy.appName)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)

            Text(SubscriptionConfig.Copy.headline)
                .font(.system(size: 22, weight: .semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(.primary)
                .padding(.horizontal, 24)

            Text(SubscriptionConfig.Copy.subheadline)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }

    // MARK: - Trial banner

    private var trialBanner: some View {
        HStack(spacing: 14) {
            Image(systemName: "gift.fill")
                .font(.system(size: 22))
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 3) {
                Text(SubscriptionConfig.Copy.trialBadge)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.accentColor)
                    .kerning(0.5)

                Text(SubscriptionConfig.Copy.ctaTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)

                Text(SubscriptionConfig.Copy.pricingDetail)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .background(Color.accentColor.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.accentColor.opacity(0.20), lineWidth: 1)
        )
    }

    // MARK: - Benefits

    private var benefitsSection: some View {
        VStack(spacing: 14) {
            ForEach(SubscriptionConfig.Copy.benefits, id: \.text) { item in
                HStack(spacing: 14) {
                    Image(systemName: item.icon)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 22)
                    Text(item.text)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
    }

    // MARK: - Plan picker

    private var planSection: some View {
        VStack(spacing: 10) {
            PlanCard(
                label: SubscriptionConfig.Copy.monthlyLabel,
                price: displayPrice(for: .monthly),
                per: SubscriptionConfig.Copy.monthlyPer,
                badge: nil,
                isSelected: selectedPlan == .monthly
            ) { selectedPlan = .monthly }

            PlanCard(
                label: SubscriptionConfig.Copy.yearlyLabel,
                price: displayPrice(for: .yearly),
                per: SubscriptionConfig.Copy.yearlyPer,
                badge: SubscriptionConfig.Copy.yearlyBadge,
                isSelected: selectedPlan == .yearly
            ) { selectedPlan = .yearly }
        }
    }

    // MARK: - CTA

    private var ctaSection: some View {
        Button {
            Task { await handlePurchase() }
        } label: {
            ZStack {
                if isPurchasing {
                    ProgressView().tint(.white)
                } else {
                    Text(SubscriptionConfig.Copy.startTrial)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(Color.accentColor.opacity(isPurchasing ? 0.7 : 1.0))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .shadow(color: Color.accentColor.opacity(0.25), radius: 8, y: 4)
            .animation(.easeInOut(duration: 0.15), value: isPurchasing)
        }
        .disabled(!isIdle)
    }

    // MARK: - Secondary actions

    private var secondaryActions: some View {
        VStack(spacing: 12) {
            Button(SubscriptionConfig.Copy.notNow) {
                subscriptionManager.dismissPaywall()
                dismiss()
            }
            .font(.system(size: 15))
            .foregroundStyle(.secondary)
            .disabled(!isIdle)

            Button {
                Task { await subscriptionManager.restorePurchases() }
            } label: {
                if isRestoring {
                    HStack(spacing: 6) {
                        ProgressView()
                            .scaleEffect(0.75)
                        Text("Restoring…")
                    }
                } else {
                    Text(SubscriptionConfig.Copy.restore)
                }
            }
            .font(.system(size: 14))
            .foregroundStyle(.secondary)
            .opacity(0.7)
            .disabled(!isIdle)
        }
    }

    // MARK: - Disclosure

    private var disclosureSection: some View {
        VStack(spacing: 4) {
            Text(SubscriptionConfig.Copy.disclosure)
            Text(SubscriptionConfig.Copy.renewalNotice)
            Text(SubscriptionConfig.Copy.cancelAnytime)
        }
        .font(.system(size: 11))
        .foregroundStyle(Color(.tertiaryLabel))
        .multilineTextAlignment(.center)
    }

    // MARK: - Close button

    private var closeButton: some View {
        Button {
            subscriptionManager.dismissPaywall()
            dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .background(Color(.secondarySystemFill))
                .clipShape(Circle())
        }
        .accessibilityLabel("Close")
    }

    // MARK: - Purchase action

    private func handlePurchase() async {
        guard let product = selectedProduct else {
            errorMessage = "This product is currently unavailable. Please check your connection and try again."
            showErrorAlert = true
            return
        }
        await subscriptionManager.purchase(product)
    }
}

// MARK: - PlanCard

private struct PlanCard: View {
    let label: String
    let price: String
    let per: String
    let badge: String?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                // Radio indicator
                ZStack {
                    Circle()
                        .strokeBorder(
                            isSelected ? Color.accentColor : Color(.tertiaryLabel),
                            lineWidth: isSelected ? 2 : 1.5
                        )
                        .frame(width: 22, height: 22)
                    if isSelected {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 12, height: 12)
                    }
                }

                // Plan label + badge
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(label)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.primary)
                        if let badge {
                            Text(badge)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Color.accentColor)
                                .clipShape(Capsule())
                        }
                    }
                    Text("5-day free trial included")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Live price
                VStack(alignment: .trailing, spacing: 1) {
                    Text(price)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.primary)
                    Text(per)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
            .background(
                isSelected
                    ? Color.accentColor.opacity(0.07)
                    : Color(.secondarySystemBackground)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(
                        isSelected ? Color.accentColor.opacity(0.55) : Color(.separator).opacity(0.5),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            )
            .animation(.easeInOut(duration: 0.15), value: isSelected)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Preview

#Preview("Paywall – Yearly selected") {
    PaywallView()
        .environment(SubscriptionManager())
}

#Preview("Paywall – Monthly selected") {
    PaywallView()
        .environment(SubscriptionManager())
}
