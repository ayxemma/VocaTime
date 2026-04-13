import SwiftUI
import UIKit

struct PermissionsView: View {
    @Environment(PermissionService.self) private var permissionService
    @Environment(\.appUILanguage) private var appUILanguage
    @Environment(\.openURL) private var openURL

    private var strings: AppStrings { appUILanguage.strings }

    var body: some View {
        let s = strings
        List {
            Section {
                Text(s.permissionsIntro)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
            }

            Section(s.permissionsStatusHeader) {
                ForEach(PermissionKind.allCases) { kind in
                    PermissionRowView(kind: kind)
                }
            }

            if let message = permissionService.lastErrorMessage {
                Section {
                    Text(message)
                        .foregroundStyle(.red)
                        .font(.subheadline)
                } header: {
                    Text(s.lastMessageHeader)
                }
            }
        }
        .navigationTitle(s.permissionsNavigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await permissionService.refreshAll()
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(s.settings) {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
                }
            }
        }
    }
}

private struct PermissionRowView: View {
    @Environment(PermissionService.self) private var permissionService
    @Environment(\.appUILanguage) private var appUILanguage
    let kind: PermissionKind

    private var strings: AppStrings { appUILanguage.strings }

    var body: some View {
        let s = strings
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(kind.localizedTitle(strings: s))
                    .font(.headline)
                Spacer()
                Text(permissionService.status(for: kind).label(strings: s))
                    .font(.subheadline)
                    .foregroundStyle(statusColor)
            }
            Text(kind.localizedExplanation(strings: s))
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(s.requestAccess) {
                Task {
                    await permissionService.request(kind, language: appUILanguage)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(permissionService.status(for: kind) == .granted)
        }
        .padding(.vertical, 4)
    }

    private var statusColor: Color {
        switch permissionService.status(for: kind) {
        case .granted, .provisional:
            return .green
        case .denied:
            return .red
        case .restricted:
            return .orange
        case .notDetermined, .unknown:
            return .secondary
        }
    }
}

#Preview {
    NavigationStack {
        PermissionsView()
            .environment(PermissionService())
            .environment(\.appUILanguage, .en)
    }
}
