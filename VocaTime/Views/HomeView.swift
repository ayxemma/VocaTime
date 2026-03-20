import SwiftUI

struct HomeView: View {
    @Environment(PermissionService.self) private var permissionService
    @State private var viewModel = VoiceCommandViewModel()
    @State private var showChat = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ScrollView {
                VStack(spacing: 24) {
                    VStack(spacing: 8) {
                        Text("VocaTime")
                            .font(.largeTitle.weight(.semibold))
                        Text("Speak → Understand → Schedule → Remind")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 24)

                    statusStrip

                    dashboardSection

                    NavigationLink {
                        PermissionsView()
                    } label: {
                        Label("Permission status", systemImage: "lock.shield")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .padding(.horizontal)
                    .padding(.bottom, 100)
                }
            }

            Button {
                showChat = true
            } label: {
                Image(systemName: "message.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(Color.accentColor)
                    .clipShape(Circle())
                    .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
            }
            .accessibilityLabel("Open command chat")
            .padding(.trailing, 20)
            .padding(.bottom, 28)
        }
        .sheet(isPresented: $showChat) {
            ChatSheetView(viewModel: viewModel)
                .presentationDragIndicator(.visible)
        }
        .task {
            await permissionService.refreshAll()
        }
    }

    private var dashboardSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Tasks")
                .font(.title2.weight(.semibold))
                .padding(.horizontal)

            taskColumn(title: "Today", items: viewModel.todayTasks)
            taskColumn(title: "Upcoming", items: viewModel.upcomingTasks)
            taskColumn(title: "Done", items: viewModel.doneTasks)
        }
    }

    private func taskColumn(title: String, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            if items.isEmpty {
                Text("Nothing here yet")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    Text("• \(item)")
                        .font(.subheadline)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
    }

    @ViewBuilder
    private var statusStrip: some View {
        let denied = PermissionKind.allCases.filter {
            permissionService.status(for: $0) == .denied
        }
        if !denied.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Some permissions are denied: \(denied.map(\.title).joined(separator: ", "))")
                    .font(.footnote)
                Text("Open Permission status to request access or fix in Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(Color.orange.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal)
        }
    }
}

#Preview {
    NavigationStack {
        HomeView()
            .environment(PermissionService())
    }
}
