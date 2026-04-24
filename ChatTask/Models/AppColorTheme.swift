import SwiftUI
import UIKit

// MARK: - Appearance mode (persisted)

enum AppAppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    static let storageKey = "appAppearanceMode"

    init(storageRaw: String) {
        self = AppAppearanceMode(rawValue: storageRaw) ?? .system
    }

    var displayName: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

// MARK: - Accent identity (persisted)

enum AppAccentColor: String, CaseIterable, Identifiable {
    case blue
    case purple
    case green
    case orange
    case pink

    var id: String { rawValue }

    static let storageKey = "appAccentColor"

    init(storageRaw: String) {
        self = AppAccentColor(rawValue: storageRaw) ?? .blue
    }

    var displayName: String {
        switch self {
        case .blue: return "Blue"
        case .purple: return "Purple"
        case .green: return "Green"
        case .orange: return "Orange"
        case .pink: return "Pink"
        }
    }

    var color: Color {
        switch self {
        case .blue: return Color(red: 0.0, green: 0.48, blue: 0.95)
        case .purple: return Color(red: 0.52, green: 0.33, blue: 0.94)
        case .green: return Color(red: 0.20, green: 0.68, blue: 0.52)
        case .orange: return Color(red: 0.95, green: 0.45, blue: 0.12)
        case .pink: return Color(red: 0.92, green: 0.38, blue: 0.62)
        }
    }
}

// MARK: - Resolved palette (colors + gradients)

struct AppThemePalette {
    let accent: AppAccentColor
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

    static func palette(for accent: AppAccentColor) -> AppThemePalette {
        let color = accent.color
        return AppThemePalette(
            accent: accent,
            primaryGradient: LinearGradient(
                colors: [color, color.opacity(0.82)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            accentColor: color,
            secondaryColor: color.opacity(0.72),
            backgroundColor: Color(.systemBackground),
            cardBackground: Color(.secondarySystemBackground),
            textPrimary: Color.primary,
            textSecondary: Color.secondary,
            assistantBubbleBackground: Color(.secondarySystemBackground),
            userBubbleForeground: .white,
            isMinimal: false
        )
    }
}

// MARK: - Environment

private enum AppThemePaletteKey: EnvironmentKey {
    static let defaultValue: AppThemePalette = .palette(for: .blue)
}

extension EnvironmentValues {
    var themePalette: AppThemePalette {
        get { self[AppThemePaletteKey.self] }
        set { self[AppThemePaletteKey.self] = newValue }
    }
}
