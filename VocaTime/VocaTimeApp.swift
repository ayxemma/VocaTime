import SwiftData
import SwiftUI

@main
struct VocaTimeApp: App {
    @State private var permissionService = PermissionService()

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(permissionService)
        }
        .modelContainer(for: TaskItem.self)
    }
}
