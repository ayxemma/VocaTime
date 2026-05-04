import SwiftUI
import os.log

private struct ChatSheetSession: Identifiable {
    let id = UUID()
    let source: String
}

struct RootTabView: View {
    @Environment(\.appUILanguage) private var appUILanguage
    @Environment(\.themePalette) private var themePalette
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AppUILanguage.storageKey) private var languageRaw: String = AppUILanguage.defaultForDevice().rawValue
    @AppStorage(FirstLaunchOnboarding.completedKey) private var firstLaunchOnboardingCompleted = false

    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VocaTime", category: "RootTab")

    @State private var chatSheetSession: ChatSheetSession?
    @State private var chatViewModel = VoiceCommandViewModel()
    @State private var selectedTab = HomeTab.home.rawValue

    private enum HomeTab: Int {
        case home = 0
        case calendar = 1
    }

    var body: some View {
        let s = appUILanguage.strings
        let selectedUILanguage = AppUILanguage(storageRaw: languageRaw)

        ZStack {
            TabView(selection: $selectedTab) {
                NavigationStack {
                    HomeView(onChatTap: {
                        Self.log.info("chatFABTapped rootTabForward=true")
                        requestChatPresentation(source: "FAB")
                    })
                }
                .tabItem {
                    Label(s.homeTab, systemImage: "house.fill")
                }
                .tag(HomeTab.home.rawValue)

                NavigationStack {
                    CalendarView()
                }
                .tabItem {
                    Label(s.calendarTab, systemImage: "calendar")
                }
                .tag(HomeTab.calendar.rawValue)
            }

        }
        .sheet(item: $chatSheetSession, onDismiss: {
            Self.log.info("[RootTab] chatSheetDismissed")
            chatSheetSession = nil
        }) { session in
            ChatSheetView(
                viewModel: chatViewModel,
                showsStarterPrompt: !firstLaunchOnboardingCompleted,
                onOnboardingAction: { firstLaunchOnboardingCompleted = true }
            )
                .environment(\.themePalette, themePalette)
                .presentationDragIndicator(.visible)
                .onAppear {
                    Self.log.info("[RootTab] chatSheetPresented source=\(session.source, privacy: .public)")
                }
        }
        .onAppear {
            chatViewModel.uiLanguage = selectedUILanguage
        }
        .onChange(of: languageRaw) { _, _ in
            chatViewModel.uiLanguage = selectedUILanguage
            Task { await chatViewModel.handleUILanguageChanged() }
        }
        .onChange(of: scenePhase) { _, newPhase in
            chatViewModel.handleAppScenePhaseChange(newPhase)
        }
    }

    private func requestChatPresentation(source: String) {
        guard source == "FAB" else {
            Self.log.error("[RootTab] unexpectedChatPresentation source=\(source, privacy: .public)")
            return
        }
        BackendWarmup.scheduleSessionWarmup()
        if chatSheetSession != nil {
            Self.log.warning("[RootTab] unexpectedChatPresentation reason=existingSessionReset source=\(source, privacy: .public)")
            chatSheetSession = nil
            DispatchQueue.main.async {
                chatSheetSession = ChatSheetSession(source: source)
                Self.log.info("[RootTab] chatSheetPresentationRequested source=\(source, privacy: .public)")
            }
        } else {
            chatSheetSession = ChatSheetSession(source: source)
            Self.log.info("[RootTab] chatSheetPresentationRequested source=\(source, privacy: .public)")
        }
    }
}
