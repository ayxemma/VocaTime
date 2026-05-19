import SwiftUI

// MARK: - Priority color

enum ImportantPriorityStyle {
    /// Soft Apple-style priority red (Mail flag / Reminders cue — not system error red).
    static let markColor = Color(red: 0.90, green: 0.30, blue: 0.33)
}

// MARK: - Inline mark

/// A single “!” before task titles for `ReminderAlertStyle.important`.
struct ImportantPriorityMark: View {
    var font: Font = .body.weight(.semibold)
    var opacity: CGFloat = 1

    var body: some View {
        Text("!")
            .font(font)
            .foregroundStyle(ImportantPriorityStyle.markColor.opacity(opacity))
            .fixedSize()
            .accessibilityHidden(true)
    }
}

// MARK: - Title row

struct ImportantPrefixedTitle: View {
    let title: String
    let isImportant: Bool
    let font: Font
    var foreground: Color = .primary
    var markOpacity: CGFloat = 1
    var strikethrough: Bool = false
    var lineLimit: Int? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            if isImportant {
                ImportantPriorityMark(font: font.weight(.semibold), opacity: markOpacity)
            }
            Text(title)
                .font(font)
                .foregroundStyle(foreground)
                .strikethrough(strikethrough)
                .lineLimit(lineLimit)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isImportant ? "\(ReminderAlertStyle.important.displayName), \(title)" : title)
    }
}

// MARK: - Alert style picker styling

extension ReminderAlertStyle {
    func pickerValueColor(theme: AppThemePalette) -> Color {
        switch self {
        case .normal:
            return theme.accentColor
        case .important:
            return .primary
        }
    }
}

#Preview("Prefixed title") {
    VStack(alignment: .leading, spacing: 12) {
        ImportantPrefixedTitle(
            title: "Pick up Ary",
            isImportant: true,
            font: .body.weight(.semibold)
        )
        ImportantPrefixedTitle(
            title: "Prepare dinner ingredients",
            isImportant: true,
            font: .body.weight(.semibold)
        )
        ImportantPrefixedTitle(
            title: "Regular reminder",
            isImportant: false,
            font: .body.weight(.semibold)
        )
    }
    .padding()
}
