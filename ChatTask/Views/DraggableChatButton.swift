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
                            Circle()
                                .stroke(themePalette.accentColor, lineWidth: 3)
                                .frame(
                                    width: DraggableChatButtonMetrics.size + 16,
                                    height: DraggableChatButtonMetrics.size + 16
                                )
                                .scaleEffect(onboardingRingPulse ? 1.12 : 1.0)
                                .opacity(onboardingRingPulse ? 0.35 : 0.85)
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
                    .scaleEffect(isDragging ? 1.06 : (showOnboardingHighlight && onboardingRingPulse ? 1.08 : 1.0))
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

    private func clampToSafeBand(_ p: CGPoint, layout band: SafeBand) -> CGPoint {
        let x = min(max(p.x, band.minCenterX), band.maxCenterX)
        let y = min(max(p.y, band.minCenterY), band.maxCenterY)
        return CGPoint(x: x, y: y)
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
