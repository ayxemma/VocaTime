import SwiftUI
import UIKit

// MARK: - Theme identity (persisted)

enum AppColorTheme: String, CaseIterable, Identifiable {
    case purple
    case pink
    case green
    case yellow
    case orange
    case red
    case blue
    case white

    var id: String { rawValue }

    static let storageKey = "appColorTheme"

    init(storageRaw: String) {
        self = AppColorTheme(rawValue: storageRaw) ?? .purple
    }

    var displayName: String {
        switch self {
        case .purple: return "Purple"
        case .pink: return "Pink"
        case .green: return "Green"
        case .yellow: return "Yellow"
        case .orange: return "Orange"
        case .red: return "Red"
        case .blue: return "Blue"
        case .white: return "White"
        }
    }

    /// Short accessibility hint for the theme picker.
    var accessibilityDescription: String {
        switch self {
        case .white: return "Minimal white theme"
        default: return "\(displayName) theme"
        }
    }
}

// MARK: - Resolved palette (colors + gradients)

struct AppThemePalette {
    let theme: AppColorTheme
    let primaryGradient: LinearGradient
    let accentColor: Color
    let secondaryColor: Color
    let backgroundColor: Color
    let cardBackground: Color
    let textPrimary: Color
    let textSecondary: Color
    let assistantBubbleBackground: Color
    /// Foreground for user-authored chat bubbles (white on dark gradients; dark on light gradients).
    let userBubbleForeground: Color
    let isMinimal: Bool

    static func palette(for theme: AppColorTheme) -> AppThemePalette {
        switch theme {
        case .purple:
            return AppThemePalette(
                theme: theme,
                primaryGradient: LinearGradient(
                    colors: [
                        Color(red: 0.55, green: 0.32, blue: 0.95),
                        Color(red: 0.32, green: 0.45, blue: 0.98),
                        Color(red: 0.62, green: 0.38, blue: 0.92),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                accentColor: Color(red: 0.52, green: 0.33, blue: 0.94),
                secondaryColor: Color(red: 0.42, green: 0.52, blue: 0.96),
                backgroundColor: Color(.systemGroupedBackground),
                cardBackground: Color(red: 0.97, green: 0.96, blue: 1.0),
                textPrimary: Color.primary,
                textSecondary: Color.secondary,
                assistantBubbleBackground: Color(.secondarySystemGroupedBackground),
                userBubbleForeground: .white,
                isMinimal: false
            )

        case .pink:
            return AppThemePalette(
                theme: theme,
                primaryGradient: LinearGradient(
                    colors: [
                        Color(red: 0.98, green: 0.45, blue: 0.72),
                        Color(red: 0.62, green: 0.38, blue: 0.94),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                accentColor: Color(red: 0.92, green: 0.38, blue: 0.62),
                secondaryColor: Color(red: 0.75, green: 0.45, blue: 0.88),
                backgroundColor: Color(.systemGroupedBackground),
                cardBackground: Color(red: 1.0, green: 0.96, blue: 0.98),
                textPrimary: Color.primary,
                textSecondary: Color.secondary,
                assistantBubbleBackground: Color(.secondarySystemGroupedBackground),
                userBubbleForeground: .white,
                isMinimal: false
            )

        case .green:
            return AppThemePalette(
                theme: theme,
                primaryGradient: LinearGradient(
                    colors: [
                        Color(red: 0.18, green: 0.72, blue: 0.52),
                        Color(red: 0.22, green: 0.62, blue: 0.68),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                accentColor: Color(red: 0.20, green: 0.68, blue: 0.52),
                secondaryColor: Color(red: 0.30, green: 0.58, blue: 0.62),
                backgroundColor: Color(.systemGroupedBackground),
                cardBackground: Color(red: 0.94, green: 0.98, blue: 0.96),
                textPrimary: Color.primary,
                textSecondary: Color.secondary,
                assistantBubbleBackground: Color(.secondarySystemGroupedBackground),
                userBubbleForeground: .white,
                isMinimal: false
            )

        case .yellow:
            return AppThemePalette(
                theme: theme,
                primaryGradient: LinearGradient(
                    colors: [
                        Color(red: 1.0, green: 0.84, blue: 0.28),
                        Color(red: 1.0, green: 0.62, blue: 0.22),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                accentColor: Color(red: 0.95, green: 0.62, blue: 0.12),
                secondaryColor: Color(red: 0.92, green: 0.72, blue: 0.18),
                backgroundColor: Color(.systemGroupedBackground),
                cardBackground: Color(red: 1.0, green: 0.99, blue: 0.94),
                textPrimary: Color.primary,
                textSecondary: Color.secondary,
                assistantBubbleBackground: Color(.secondarySystemGroupedBackground),
                userBubbleForeground: Color(red: 0.15, green: 0.12, blue: 0.08),
                isMinimal: false
            )

        case .orange:
            return AppThemePalette(
                theme: theme,
                primaryGradient: LinearGradient(
                    colors: [
                        Color(red: 1.0, green: 0.52, blue: 0.18),
                        Color(red: 1.0, green: 0.72, blue: 0.22),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                accentColor: Color(red: 1.0, green: 0.52, blue: 0.20),
                secondaryColor: Color(red: 0.98, green: 0.68, blue: 0.28),
                backgroundColor: Color(.systemGroupedBackground),
                cardBackground: Color(red: 1.0, green: 0.96, blue: 0.92),
                textPrimary: Color.primary,
                textSecondary: Color.secondary,
                assistantBubbleBackground: Color(.secondarySystemGroupedBackground),
                userBubbleForeground: .white,
                isMinimal: false
            )

        case .red:
            return AppThemePalette(
                theme: theme,
                primaryGradient: LinearGradient(
                    colors: [
                        Color(red: 0.95, green: 0.28, blue: 0.38),
                        Color(red: 0.92, green: 0.45, blue: 0.68),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                accentColor: Color(red: 0.92, green: 0.28, blue: 0.42),
                secondaryColor: Color(red: 0.88, green: 0.42, blue: 0.58),
                backgroundColor: Color(.systemGroupedBackground),
                cardBackground: Color(red: 1.0, green: 0.95, blue: 0.96),
                textPrimary: Color.primary,
                textSecondary: Color.secondary,
                assistantBubbleBackground: Color(.secondarySystemGroupedBackground),
                userBubbleForeground: .white,
                isMinimal: false
            )

        case .blue:
            return AppThemePalette(
                theme: theme,
                primaryGradient: LinearGradient(
                    colors: [
                        Color(red: 0.22, green: 0.48, blue: 0.95),
                        Color(red: 0.18, green: 0.72, blue: 0.88),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                accentColor: Color(red: 0.24, green: 0.52, blue: 0.94),
                secondaryColor: Color(red: 0.28, green: 0.68, blue: 0.85),
                backgroundColor: Color(.systemGroupedBackground),
                cardBackground: Color(red: 0.94, green: 0.97, blue: 1.0),
                textPrimary: Color.primary,
                textSecondary: Color.secondary,
                assistantBubbleBackground: Color(.secondarySystemGroupedBackground),
                userBubbleForeground: .white,
                isMinimal: false
            )

        case .white:
            return AppThemePalette(
                theme: theme,
                primaryGradient: LinearGradient(
                    colors: [
                        Color(white: 0.98),
                        Color(white: 0.94),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                accentColor: Color(red: 0.0, green: 0.48, blue: 0.95),
                secondaryColor: Color(red: 0.45, green: 0.48, blue: 0.52),
                backgroundColor: Color(.systemGroupedBackground),
                cardBackground: Color(.secondarySystemGroupedBackground),
                textPrimary: Color.primary,
                textSecondary: Color.secondary,
                assistantBubbleBackground: Color(.secondarySystemGroupedBackground),
                userBubbleForeground: Color.primary,
                isMinimal: true
            )
        }
    }
}

// MARK: - Environment

private enum AppThemePaletteKey: EnvironmentKey {
    static let defaultValue: AppThemePalette = .palette(for: .purple)
}

extension EnvironmentValues {
    var themePalette: AppThemePalette {
        get { self[AppThemePaletteKey.self] }
        set { self[AppThemePaletteKey.self] = newValue }
    }
}
