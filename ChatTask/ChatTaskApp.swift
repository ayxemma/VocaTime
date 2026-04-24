import SwiftData
import SwiftUI

@main
struct ChatTaskApp: App {
    @State private var permissionService = PermissionService()
    @State private var subscriptionManager = SubscriptionManager()

    /// Shared with SwiftUI and `TaskReminderService` (notification action handlers use SwiftData).
    private static let modelContainer: ModelContainer = {
        do {
            return try ModelContainer(for: TaskItem.self)
        } catch {
            fatalError("ChatTask: failed to create ModelContainer: \(error)")
        }
    }()

    init() {
        AppUILanguage.migrateLegacyUserDefaultsIfNeeded()
        TaskReminderService.shared.configure(modelContainer: Self.modelContainer)
        // Register the notification-center delegate immediately so foreground
        // notifications are presented.  Must happen before any notification fires.
        TaskReminderService.shared.setup()
    }

    var body: some Scene {
        WindowGroup {
            AppShellView()
                .environment(permissionService)
                .environment(subscriptionManager)
                .task {
                    // Subscription: start listening before any other async work so
                    // background renewals and deferred purchases are never missed.
                    subscriptionManager.startListeningForTransactions()
                    async let entitlements: () = subscriptionManager.checkEntitlements()
                    async let products: ()      = subscriptionManager.loadProducts()
                    async let notifications: () = permissionService.requestNotificationsIfNeeded()
                    _ = await (entitlements, products, notifications)
                }
        }
        .modelContainer(Self.modelContainer)
    }
}

private struct AppShellView: View {
    @AppStorage(AppUILanguage.storageKey) private var languageRaw: String = AppUILanguage.defaultForDevice().rawValue
    @AppStorage(AppAppearanceMode.storageKey) private var appearanceRaw: String = AppAppearanceMode.system.rawValue
    @AppStorage(AppAccentColor.storageKey) private var accentRaw: String = AppAccentColor.blue.rawValue
    @Environment(SubscriptionManager.self) private var subscriptionManager
    @Environment(\.scenePhase) private var scenePhase
    @Query private var allTasks: [TaskItem]

    @State private var showPaywall = false
    @State private var didRunRootOnAppearWarmup = false
    @State private var idlePreWarmTask: Task<Void, Never>?

    private var appearance: AppAppearanceMode { AppAppearanceMode(storageRaw: appearanceRaw) }
    private var accent: AppAccentColor { AppAccentColor(storageRaw: accentRaw) }
    private var themePalette: AppThemePalette { AppThemePalette.palette(for: accent) }

    var body: some View {
        let uiLang = AppUILanguage(storageRaw: languageRaw)
        RootTabView()
            .environment(\.appUILanguage, uiLang)
            .environment(\.themePalette, themePalette)
            .environment(\.locale, uiLang.locale)
            .tint(themePalette.accentColor)
            .preferredColorScheme(appearance.colorScheme)
            .animation(.easeInOut(duration: 0.25), value: accentRaw)
            .animation(.easeInOut(duration: 0.25), value: appearanceRaw)
            .sheet(isPresented: $showPaywall) {
                PaywallView()
                    .environment(\.appUILanguage, uiLang)
                    .environment(\.themePalette, themePalette)
                    .environment(\.locale, uiLang.locale)
            }
            .onChange(of: allTasks.count) { _, newCount in
                if !showPaywall && subscriptionManager.shouldShowPaywall(taskCount: newCount) {
                    showPaywall = true
                }
            }
            // Backend warm-up: SwiftUI lifecycle (not only `App.init`); `BackendWarmup` deduplicates in-session.
            .onAppear {
                if !didRunRootOnAppearWarmup {
                    didRunRootOnAppearWarmup = true
                    BackendWarmup.scheduleSessionWarmup()
                }
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active {
                    BackendWarmup.scheduleSessionWarmup()
                    idlePreWarmTask?.cancel()
                    idlePreWarmTask = Task(priority: .utility) {
                        try? await Task.sleep(nanoseconds: 6_000_000_000)
                        guard !Task.isCancelled else { return }
                        BackendWarmup.scheduleSessionWarmup()
                    }
                } else {
                    idlePreWarmTask?.cancel()
                    idlePreWarmTask = nil
                }
            }
    }
}
