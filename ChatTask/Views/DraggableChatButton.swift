import SwiftUI
import os.log

// MARK: - Storage (defaults vs saved position)

private enum DraggableChatFABStorage {
    private static let migratedKey = "homeChatFABPositionStorageMigrated_v1"

    /// Ensures `homeChatFABHasSavedPosition` exists for installs that only had rel X/Y keys.
    static func migrateIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: migratedKey) else { return }
        defer { UserDefaults.standard.set(true, forKey: migratedKey) }

        guard UserDefaults.standard.object(forKey: "homeChatFABHasSavedPosition") == nil else { return }

        let hasRel = UserDefaults.standard.object(forKey: "homeChatFABRelX") != nil
            || UserDefaults.standard.object(forKey: "homeChatFABRelY") != nil
        guard hasRel else { return }

        let xv = UserDefaults.standard.double(forKey: "homeChatFABRelX")
        let yv = UserDefaults.standard.double(forKey: "homeChatFABRelY")
        let isExactlyBottomRight = abs(xv - 1.0) < 1e-6 && abs(yv - 1.0) < 1e-6
        // Any non–bottom-right stored values imply the user had dragged before.
        UserDefaults.standard.set(!isExactlyBottomRight, forKey: "homeChatFABHasSavedPosition")
    }
}

// MARK: - Metrics

private enum DraggableChatButtonMetrics {
    static let size: CGFloat = 56
    static let edgeMargin: CGFloat = 16
    static let onboardingTooltipWidth: CGFloat = 292
    /// Room for title, body, optional “Try:” line, and highlighted example pill.
    static let onboardingTooltipBubbleHeight: CGFloat = 176
    static let onboardingTooltipPointerHeight: CGFloat = 10
    static let onboardingTooltipGap: CGFloat = 22
    /// Small gap above the home indicator / bottom safe inset (8–16 pt range; keeps the
    /// circle fully visible without a large artificial “danger zone”).
    static let bottomSafeMargin: CGFloat = 12
    /// Movement at or below this distance (points) counts as a tap, not a drag.
    static let tapDistanceThreshold: CGFloat = 12
}

// MARK: - DraggableChatButton

/// A Messenger-style floating action button: draggable, edge-snapping, persisted, and
/// non-blocking (full-screen pass-through except on the circle).
struct DraggableChatButton: View {

    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ChatTask", category: "ChatFAB")

    @Environment(\.themePalette) private var themePalette

    /// Persisted horizontal position: 0 = left edge of the safe band, 1 = right.
    @AppStorage("homeChatFABRelX") private var storedRelX: Double = 1.0
    /// Persisted vertical position: 0 = top of the safe band, 1 = bottom.
    @AppStorage("homeChatFABRelY") private var storedRelY: Double = 1.0
    /// After the first completed drag, restored values are used; until then, bottom-right default.
    @AppStorage("homeChatFABHasSavedPosition") private var hasSavedPosition: Bool = false

    let onTap: () -> Void
    let accessibilityLabel: String
    /// Pulsing ring for first-launch onboarding (does not block layout).
    var showOnboardingHighlight: Bool = false
    var onboardingTitle: String = ""
    var onboardingBody: String = ""
    var onboardingExample: String = ""
    var onboardingDismissA11y: String = "Close"
    var onOnboardingDismiss: () -> Void = {}

    @State private var dragTranslation: CGSize = .zero
    @State private var isDragging = false
    @State private var onboardingRingPulse = false
    #if DEBUG
    @State private var didLogInitialLayout = false
    @State private var didLogPlacementMode = false
    #endif

    var body: some View {
        let _ = DraggableChatFABStorage.migrateIfNeeded()
        GeometryReader { geo in
            let layout = layoutMetrics(in: geo)
            if layout.isValid {
                let base = storedCenter(in: layout)
                let rawEnd = CGPoint(
                    x: base.x + dragTranslation.width,
                    y: base.y + dragTranslation.height
                )
                let clampedDrag = clampToSafeBand(rawEnd, layout: layout)
                let half = DraggableChatButtonMetrics.size / 2
                // Top-leading origin in the same coordinate space as `layoutMetrics` (GeometryReader),
                // avoiding `.position` + `.offset` which can misalign hit testing from the drawn circle.
                let topLeading = CGPoint(x: clampedDrag.x - half, y: clampedDrag.y - half)
                let tooltip = onboardingTooltipPlacement(iconCenter: clampedDrag, in: geo)

                ZStack(alignment: .topLeading) {
                    if showOnboardingHighlight {
                        Color.black.opacity(0.30)
                            .frame(width: geo.size.width, height: geo.size.height)
                            .contentShape(Rectangle())
                            .onTapGesture { onOnboardingDismiss() }
                            .zIndex(0)
                    }

                    if showOnboardingHighlight {
                        OnboardingCoachmarkTooltip(
                            title: onboardingTitle,
                            bodyText: onboardingBody,
                            example: onboardingExample,
                            dismissAccessibilityLabel: onboardingDismissA11y,
                            pointerX: tooltip.pointerX,
                            pointerPointsDown: tooltip.pointerPointsDown,
                            onDismiss: onOnboardingDismiss
                        )
                        .frame(width: DraggableChatButtonMetrics.onboardingTooltipWidth)
                        .offset(x: tooltip.origin.x, y: tooltip.origin.y)
                        .zIndex(1)
                    }

                    Image(systemName: "message.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(themePalette.isMinimal ? themePalette.accentColor : Color.white)
                        .frame(width: DraggableChatButtonMetrics.size, height: DraggableChatButtonMetrics.size)
                        .background(
                            Circle()
                                .fill(themePalette.primaryGradient)
                        )
                        .clipShape(Circle())
                        .overlay {
                        if showOnboardingHighlight {
                            ZStack {
                                Circle()
                                    .fill(themePalette.accentColor.opacity(onboardingRingPulse ? 0.08 : 0.18))
                                    .frame(
                                        width: DraggableChatButtonMetrics.size + 26,
                                        height: DraggableChatButtonMetrics.size + 26
                                    )
                                    .scaleEffect(onboardingRingPulse ? 1.24 : 1.0)
                                Circle()
                                    .stroke(themePalette.accentColor, lineWidth: 3)
                                    .frame(
                                        width: DraggableChatButtonMetrics.size + 16,
                                        height: DraggableChatButtonMetrics.size + 16
                                    )
                                    .scaleEffect(onboardingRingPulse ? 1.18 : 1.0)
                                    .opacity(onboardingRingPulse ? 0.28 : 0.90)
                            }
                        }
                    }
                        .shadow(
                            color: .black.opacity(themePalette.isMinimal ? 0.1 : 0.2),
                            radius: themePalette.isMinimal ? 4 : 6,
                            y: 3
                        )
                        .shadow(
                            color: showOnboardingHighlight ? themePalette.accentColor.opacity(0.36) : .clear,
                            radius: showOnboardingHighlight ? 12 : 0,
                            y: 0
                        )
                        .scaleEffect(isDragging ? 1.06 : (showOnboardingHighlight && onboardingRingPulse ? 1.14 : 1.0))
                        .opacity(isDragging ? 0.92 : 1.0)
                        .animation(.easeInOut(duration: 0.18), value: isDragging)
                        .animation(.easeInOut(duration: 1.2), value: onboardingRingPulse)
                        .contentShape(Circle())
                        .offset(x: topLeading.x, y: topLeading.y)
                        .accessibilityLabel(accessibilityLabel)
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { onTap() }
                        .onChange(of: showOnboardingHighlight) { _, show in
                            if show {
                                onboardingRingPulse = false
                                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                                    onboardingRingPulse = true
                                }
                            } else {
                                onboardingRingPulse = false
                            }
                        }
                        .onAppear {
                            guard showOnboardingHighlight else { return }
                            onboardingRingPulse = false
                            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                                onboardingRingPulse = true
                            }
                        }
                        .highPriorityGesture(
                            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                            .onChanged { value in
                                let d = hypot(value.translation.width, value.translation.height)
                                if d > DraggableChatButtonMetrics.tapDistanceThreshold {
                                    isDragging = true
                                }
                                dragTranslation = value.translation
                            }
                                .onEnded { value in
                                    let total = hypot(value.translation.width, value.translation.height)
                                    let layoutNow = layoutMetrics(in: geo)
                                    defer {
                                        dragTranslation = .zero
                                        isDragging = false
                                    }
                                    guard layoutNow.isValid else { return }
                                    let baseNow = storedCenter(in: layoutNow)
                                    let visibleCenter = clampToSafeBand(
                                        CGPoint(
                                            x: baseNow.x + value.translation.width,
                                            y: baseNow.y + value.translation.height
                                        ),
                                        layout: layoutNow
                                    )
                                    let halfNow = DraggableChatButtonMetrics.size / 2
                                    let frameNow = CGRect(
                                        x: visibleCenter.x - halfNow,
                                        y: visibleCenter.y - halfNow,
                                        width: DraggableChatButtonMetrics.size,
                                        height: DraggableChatButtonMetrics.size
                                    )
                                    if total <= DraggableChatButtonMetrics.tapDistanceThreshold {
                                        let loc = value.location
                                        Self.log.info("chatFABTapped visibleCenter=(\(Double(visibleCenter.x), privacy: .public),\(Double(visibleCenter.y), privacy: .public)) tapLocation=(\(Double(loc.x), privacy: .public),\(Double(loc.y), privacy: .public)) savedRelativePosition=(\(storedRelX, privacy: .public),\(storedRelY, privacy: .public)) hasSavedPosition=\(hasSavedPosition, privacy: .public) computedButtonFrame=(x:\(Double(frameNow.minX), privacy: .public) y:\(Double(frameNow.minY), privacy: .public) w:\(Double(frameNow.width), privacy: .public) h:\(Double(frameNow.height), privacy: .public))")
                                        onTap()
                                        return
                                    }
                                    let endRaw = CGPoint(
                                        x: baseNow.x + value.translation.width,
                                        y: baseNow.y + value.translation.height
                                    )
                                    let midX = (layoutNow.minCenterX + layoutNow.maxCenterX) / 2
                                    let snappedX = endRaw.x < midX ? layoutNow.minCenterX : layoutNow.maxCenterX
                                    let snappedY = min(max(endRaw.y, layoutNow.minCenterY), layoutNow.maxCenterY)
                                    let snapped = CGPoint(x: snappedX, y: snappedY)
                                    let denomX = max(layoutNow.maxCenterX - layoutNow.minCenterX, 1)
                                    let denomY = max(layoutNow.maxCenterY - layoutNow.minCenterY, 1)
                                    let nx = (snapped.x - layoutNow.minCenterX) / denomX
                                    let ny = (snapped.y - layoutNow.minCenterY) / denomY
                                    #if DEBUG
                                    logLayoutDebug(geo: geo, layout: layoutNow, phase: "drop", droppedCenterY: snapped.y)
                                    #endif
                                    withAnimation(.spring(response: 0.38, dampingFraction: 0.84)) {
                                        hasSavedPosition = true
                                        storedRelX = Double(nx)
                                        storedRelY = Double(ny)
                                    }
                                }
                        )
                        .zIndex(2)
                    #if DEBUG
                    .onAppear {
                        if !didLogPlacementMode {
                            didLogPlacementMode = true
                            let mode = hasSavedPosition ? "saved" : "default_bottom_right"
                            print("[DraggableChatButton] placement: \(mode) rel=(\(storedRelX),\(storedRelY)) hasSavedPosition=\(hasSavedPosition)")
                        }
                        guard !didLogInitialLayout else { return }
                        didLogInitialLayout = true
                        logLayoutDebug(geo: geo, layout: layout, phase: "initial", droppedCenterY: nil)
                    }
                    #endif
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(true)
    }

    #if DEBUG
    private func logLayoutDebug(geo: GeometryProxy, layout: SafeBand, phase: String, droppedCenterY: CGFloat?) {
        let half = DraggableChatButtonMetrics.size / 2
        let safe = geo.safeAreaInsets
        var message = """
        [DraggableChatButton] \(phase)
          container: \(geo.size.width) x \(geo.size.height)
          safeArea.top=\(safe.top) safeArea.bottom=\(safe.bottom) leading=\(safe.leading) trailing=\(safe.trailing)
          buttonSize=\(DraggableChatButtonMetrics.size)
          minCenterY=\(layout.minCenterY) maxCenterY=\(layout.maxCenterY)
          minButtonTopY=\(layout.minCenterY - half) maxButtonBottomY=\(layout.maxCenterY + half)
        """
        if let y = droppedCenterY {
            message += "\n  droppedCenterY=\(y) droppedButtonBottomY=\(y + half)"
        }
        print(message)
    }
    #endif

    // MARK: - Layout

    private struct SafeBand {
        let minCenterX: CGFloat
        let maxCenterX: CGFloat
        let minCenterY: CGFloat
        let maxCenterY: CGFloat

        var isValid: Bool { maxCenterX >= minCenterX && maxCenterY >= minCenterY }
    }

    private struct TooltipPlacement {
        let origin: CGPoint
        let pointerX: CGFloat
        let pointerPointsDown: Bool
    }

    private func layoutMetrics(in geo: GeometryProxy) -> SafeBand {
        let safe = geo.safeAreaInsets
        let w = geo.size.width
        let h = geo.size.height
        let half = DraggableChatButtonMetrics.size / 2
        let m = DraggableChatButtonMetrics.edgeMargin
        let minCX = half + m + safe.leading
        let maxCX = w - half - m - safe.trailing
        let minCY = half + m + safe.top
        // Bottom: h − safeBottom − smallMargin − radius (no extra tab-bar “danger zone”).
        let maxCY = h - half - safe.bottom - DraggableChatButtonMetrics.bottomSafeMargin
        return SafeBand(minCenterX: minCX, maxCenterX: maxCX, minCenterY: minCY, maxCenterY: maxCY)
    }

    private func storedCenter(in band: SafeBand) -> CGPoint {
        let nx: CGFloat
        let ny: CGFloat
        if hasSavedPosition {
            nx = CGFloat(storedRelX.clamped(to: 0...1))
            ny = CGFloat(storedRelY.clamped(to: 0...1))
        } else {
            // Bottom-right in the safe band (respects margins + home indicator via layout metrics).
            nx = 1.0
            ny = 1.0
        }
        let x = band.minCenterX + nx * (band.maxCenterX - band.minCenterX)
        let y = band.minCenterY + ny * (band.maxCenterY - band.minCenterY)
        return CGPoint(x: x, y: y)
    }

    private func onboardingTooltipPlacement(iconCenter: CGPoint, in geo: GeometryProxy) -> TooltipPlacement {
        let safe = geo.safeAreaInsets
        let edge = DraggableChatButtonMetrics.edgeMargin
        let width = DraggableChatButtonMetrics.onboardingTooltipWidth
        let bubbleHeight = DraggableChatButtonMetrics.onboardingTooltipBubbleHeight
        let pointerHeight = DraggableChatButtonMetrics.onboardingTooltipPointerHeight
        let totalHeight = bubbleHeight + pointerHeight
        let half = DraggableChatButtonMetrics.size / 2
        let gap = DraggableChatButtonMetrics.onboardingTooltipGap
        let minX = safe.leading + edge
        let maxX = max(minX, geo.size.width - safe.trailing - edge - width)
        let minY = safe.top + edge
        let maxY = max(minY, geo.size.height - safe.bottom - edge - totalHeight)

        let proposedX = iconCenter.x - width + DraggableChatButtonMetrics.size
        let x = min(max(proposedX, minX), maxX)
        let aboveY = iconCenter.y - half - gap - totalHeight
        let canFitAbove = aboveY >= minY
        let belowY = iconCenter.y + half + gap
        let y = min(max(canFitAbove ? aboveY : belowY, minY), maxY)
        let pointerX = min(max(iconCenter.x - x, 24), width - 24)
        return TooltipPlacement(
            origin: CGPoint(x: x, y: y),
            pointerX: pointerX,
            pointerPointsDown: canFitAbove
        )
    }

    private func clampToSafeBand(_ p: CGPoint, layout band: SafeBand) -> CGPoint {
        let x = min(max(p.x, band.minCenterX), band.maxCenterX)
        let y = min(max(p.y, band.minCenterY), band.maxCenterY)
        return CGPoint(x: x, y: y)
    }
}

private struct OnboardingCoachmarkTooltip: View {
    let title: String
    let bodyText: String
    let example: String
    let dismissAccessibilityLabel: String
    let pointerX: CGFloat
    let pointerPointsDown: Bool
    let onDismiss: () -> Void

    @Environment(\.themePalette) private var themePalette
    @Environment(\.colorScheme) private var colorScheme

    @State private var didAnimateIn = false
    @State private var revealedCharacterCount = 0

    private var exampleParts: (prefix: String, phrase: String) {
        OnboardingVoiceExampleFormatting.split(example)
    }

    private var phraseToReveal: String {
        let phrase = exampleParts.phrase
        if !phrase.isEmpty { return phrase }
        return example.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !pointerPointsDown {
                pointer
                    .rotationEffect(.degrees(180))
                    .padding(.leading, pointerX - 9)
            }

            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(title)
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(.primary)
                    Text(bodyText)
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !exampleParts.prefix.isEmpty {
                        Text(exampleParts.prefix)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    examplePhrasePill(text: revealedPhrase)
                }
                Spacer(minLength: 8)
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(dismissAccessibilityLabel)
            }
            .padding(14)
            .frame(
                width: DraggableChatButtonMetrics.onboardingTooltipWidth,
                height: DraggableChatButtonMetrics.onboardingTooltipBubbleHeight,
                alignment: .topLeading
            )
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.16), radius: 14, y: 5)

            if pointerPointsDown {
                pointer
                    .padding(.leading, pointerX - 9)
            }
        }
        .opacity(didAnimateIn ? 1 : 0)
        .offset(y: didAnimateIn ? 0 : 8)
        .accessibilityElement(children: .combine)
        .task(id: example) {
            revealedCharacterCount = 0
            withAnimation(.easeOut(duration: 0.35)) {
                didAnimateIn = true
            }
            await reveal(phraseToReveal)
        }
    }

    @ViewBuilder
    private func examplePhrasePill(text: String) -> some View {
        let accentFillOpacity = colorScheme == .dark ? 0.22 : 0.12
        let accentStrokeOpacity = colorScheme == .dark ? 0.55 : 0.38
        Text(text)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(themePalette.textPrimary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(themePalette.accentColor.opacity(accentFillOpacity))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(themePalette.accentColor.opacity(accentStrokeOpacity), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.25 : 0.08), radius: 5, y: 2)
    }

    private var pointer: some View {
        CoachmarkPointer()
            .fill(.ultraThinMaterial)
            .frame(
                width: 18,
                height: DraggableChatButtonMetrics.onboardingTooltipPointerHeight
            )
    }

    private var revealedPhrase: String {
        String(phraseToReveal.prefix(revealedCharacterCount))
    }

    private func reveal(_ phrase: String) async {
        let totalDurationNanos: UInt64 = 850_000_000
        let count = max(phrase.count, 1)
        let delay = max(totalDurationNanos / UInt64(count), 12_000_000)
        for index in 1...phrase.count {
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            revealedCharacterCount = index
        }
    }
}

private struct CoachmarkPointer: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
