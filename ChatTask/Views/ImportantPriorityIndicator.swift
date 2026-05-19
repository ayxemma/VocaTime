import SwiftUI

// MARK: - Priority badge

/// Calm, Apple-style indicator for `ReminderAlertStyle.important` (not error/warning red).
struct ImportantPriorityBadge: View {
    enum Size {
        case compact
        case regular

        var dimension: CGFloat {
            switch self {
            case .compact: return 18
            case .regular: return 22
            }
        }

        var fontSize: CGFloat {
            switch self {
            case .compact: return 11
            case .regular: return 13
            }
        }
    }

    var size: Size = .compact

    @Environment(\.themePalette) private var themePalette

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [
                            themePalette.accentColor.opacity(0.92),
                            themePalette.secondaryColor.opacity(0.78),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Text("!")
                .font(.system(size: size.fontSize, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .offset(y: -0.5)
        }
        .frame(width: size.dimension, height: size.dimension)
        .shadow(color: themePalette.accentColor.opacity(0.28), radius: size == .compact ? 2 : 3, x: 0, y: 1)
        .accessibilityLabel(ReminderAlertStyle.important.displayName)
    }
}

// MARK: - Task card accent

struct ImportantTaskCardAccent: ViewModifier {
    let isImportant: Bool
    @Environment(\.themePalette) private var themePalette

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .leading) {
                if isImportant {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    themePalette.accentColor.opacity(0.85),
                                    themePalette.secondaryColor.opacity(0.55),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: 3)
                        .padding(.leading, 11)
                        .padding(.vertical, 13)
                }
            }
            .background {
                if isImportant {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(themePalette.accentColor.opacity(themePalette.isMinimal ? 0.06 : 0.08))
                }
            }
    }
}

extension View {
    func importantTaskCardAccent(_ isImportant: Bool) -> some View {
        modifier(ImportantTaskCardAccent(isImportant: isImportant))
    }
}

// MARK: - Alert style picker styling

extension ReminderAlertStyle {
    func pickerValueColor(theme: AppThemePalette) -> Color {
        switch self {
        case .silent:
            return .secondary
        case .default:
            return theme.accentColor
        case .important:
            return theme.accentColor
        }
    }
}

#Preview("Badge sizes") {
    HStack(spacing: 16) {
        ImportantPriorityBadge(size: .compact)
        ImportantPriorityBadge(size: .regular)
    }
    .padding()
    .environment(\.themePalette, .palette(for: .purple))
}
