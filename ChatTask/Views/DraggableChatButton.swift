import SwiftUI

// MARK: - Metrics

private enum DraggableChatButtonMetrics {
    static let size: CGFloat = 56
    static let edgeMargin: CGFloat = 16
    /// Extra space above tab bar / home indicator + typical tab height so the FAB
    /// stays clear of the last task rows and the tab bar.
    static let bottomClearance: CGFloat = 32
    /// When the FAB’s vertical position is within this fraction of the draggable
    /// band measured from the bottom, nudge it slightly upward after release.
    static let bottomSoftZoneStart: CGFloat = 0.68
    static let bottomSoftZoneNudge: CGFloat = 32
    /// Movement at or below this distance (points) counts as a tap, not a drag.
    static let tapDistanceThreshold: CGFloat = 12
}

// MARK: - DraggableChatButton

/// A Messenger-style floating action button: draggable, edge-snapping, persisted, and
/// non-blocking (full-screen pass-through except on the circle).
struct DraggableChatButton: View {

    /// Persisted horizontal position: 0 = left edge of the safe band, 1 = right (default).
    @AppStorage("homeChatFABRelX") private var storedRelX: Double = 1.0
    /// Persisted vertical position: 0 = top of the safe band, 1 = bottom (default).
    @AppStorage("homeChatFABRelY") private var storedRelY: Double = 1.0

    let onTap: () -> Void
    let accessibilityLabel: String

    @State private var dragTranslation: CGSize = .zero
    @State private var isDragging = false

    var body: some View {
        GeometryReader { geo in
            let layout = layoutMetrics(in: geo)
            if layout.isValid {
                let base = storedCenter(in: layout)
                let rawEnd = CGPoint(
                    x: base.x + dragTranslation.width,
                    y: base.y + dragTranslation.height
                )
                let clampedDrag = clampToSafeBand(rawEnd, layout: layout, dragging: true)
                let dragOffset = CGSize(
                    width: clampedDrag.x - base.x,
                    height: clampedDrag.y - base.y
                )

                ZStack {
                    Color.clear
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .allowsHitTesting(false)

                    Image(systemName: "message.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: DraggableChatButtonMetrics.size, height: DraggableChatButtonMetrics.size)
                        .background(Color.accentColor)
                        .clipShape(Circle())
                        .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
                        .scaleEffect(isDragging ? 1.06 : 1.0)
                        .opacity(isDragging ? 0.92 : 1.0)
                        .animation(.easeInOut(duration: 0.18), value: isDragging)
                        .position(base)
                        .offset(dragOffset)
                        .contentShape(Circle())
                        .accessibilityLabel(accessibilityLabel)
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { onTap() }
                        .gesture(
                            DragGesture(minimumDistance: 0)
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
                                    if total <= DraggableChatButtonMetrics.tapDistanceThreshold {
                                        onTap()
                                        return
                                    }
                                    let baseNow = storedCenter(in: layoutNow)
                                    let endRaw = CGPoint(
                                        x: baseNow.x + value.translation.width,
                                        y: baseNow.y + value.translation.height
                                    )
                                    let midX = (layoutNow.minCenterX + layoutNow.maxCenterX) / 2
                                    let snappedX = endRaw.x < midX ? layoutNow.minCenterX : layoutNow.maxCenterX
                                    let snappedY = softClampY(endRaw.y, layout: layoutNow, dragging: false)
                                    let snapped = CGPoint(x: snappedX, y: snappedY)
                                    let denomX = max(layoutNow.maxCenterX - layoutNow.minCenterX, 1)
                                    let denomY = max(layoutNow.maxCenterY - layoutNow.minCenterY, 1)
                                    let nx = (snapped.x - layoutNow.minCenterX) / denomX
                                    let ny = (snapped.y - layoutNow.minCenterY) / denomY
                                    withAnimation(.spring(response: 0.38, dampingFraction: 0.84)) {
                                        storedRelX = Double(nx)
                                        storedRelY = Double(ny)
                                    }
                                }
                        )
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(true)
    }

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
        let maxCY = h - half - m - safe.bottom - DraggableChatButtonMetrics.bottomClearance
        return SafeBand(minCenterX: minCX, maxCenterX: maxCX, minCenterY: minCY, maxCenterY: maxCY)
    }

    private func storedCenter(in band: SafeBand) -> CGPoint {
        let nx = CGFloat(storedRelX.clamped(to: 0...1))
        let ny = CGFloat(storedRelY.clamped(to: 0...1))
        let x = band.minCenterX + nx * (band.maxCenterX - band.minCenterX)
        let y = band.minCenterY + ny * (band.maxCenterY - band.minCenterY)
        return CGPoint(x: x, y: y)
    }

    private func clampToSafeBand(_ p: CGPoint, layout band: SafeBand, dragging: Bool) -> CGPoint {
        let x = min(max(p.x, band.minCenterX), band.maxCenterX)
        let y = softClampY(p.y, layout: band, dragging: dragging)
        return CGPoint(x: x, y: y)
    }

    private func softClampY(_ y: CGFloat, layout band: SafeBand, dragging: Bool) -> CGFloat {
        var y2 = min(max(y, band.minCenterY), band.maxCenterY)
        let span = band.maxCenterY - band.minCenterY
        guard span > 0 else { return y2 }
        let fromBottom = (y2 - band.minCenterY) / span
        if fromBottom >= DraggableChatButtonMetrics.bottomSoftZoneStart {
            y2 = min(y2, band.maxCenterY - (dragging ? 0 : DraggableChatButtonMetrics.bottomSoftZoneNudge))
        }
        return y2
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
