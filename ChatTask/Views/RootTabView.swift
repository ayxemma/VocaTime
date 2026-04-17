import SwiftUI

struct RootTabView: View {
    @Environment(\.appUILanguage) private var appUILanguage
    @Environment(\.themePalette) private var themePalette
    @AppStorage(AppUILanguage.storageKey) private var languageRaw: String = AppUILanguage.defaultForDevice().rawValue

    @State private var showChat = false
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
                    HomeView()
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

            // Full-window overlay (Home only): GeometryReader inside tab content measured
            // only the area above the tab bar, so maxY sat too high. Measuring here uses
            // the scene size and real bottom safe inset.
            if selectedTab == HomeTab.home.rawValue {
                DraggableChatButton(
                    onTap: { showChat = true },
                    accessibilityLabel: s.openCommandChat
                )
            }
        }
        .sheet(isPresented: $showChat) {
            ChatSheetView(viewModel: chatViewModel)
                .environment(\.themePalette, themePalette)
                .presentationDragIndicator(.visible)
        }
        .onAppear {
            chatViewModel.uiLanguage = selectedUILanguage
        }
        .onChange(of: languageRaw) { _, _ in
            chatViewModel.uiLanguage = selectedUILanguage
            Task { await chatViewModel.handleUILanguageChanged() }
        }
    }
}
