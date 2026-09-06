import AppKit
import SwiftUI

struct CoverFlowView: View {
    @EnvironmentObject private var session: FlipSession
    @State private var images: [String: NSImage] = [:]
    @State private var settledFlow: CGFloat = 0
    @State private var flipAnim: FlipFlowAnim?

    private let sideCount = 2
    private let flipDuration: TimeInterval = 0.20

    var body: some View {
        stage
            .onAppear {
                settledFlow = CGFloat(session.selectionIndex)
                flipAnim = nil
                reloadImages()
            }
            .onChange(of: session.selectionIndex) { _, newValue in
                retargetFlow(to: CGFloat(newValue))
                reloadImages()
            }
            .onChange(of: session.photos) { _, _ in
                images = [:]
                settledFlow = CGFloat(session.selectionIndex)
                flipAnim = nil
                reloadImages()
            }
    }

    private var stage: some View {
        GeometryReader { geo in
            let layout = CoverFlowLayout(size: geo.size)
            TimelineView(.animation(minimumInterval: nil, paused: flipAnim == nil)) { timeline in
                let flow = flowPosition(at: timeline.date)
                CoverFlowStage(
                    flowPosition: flow,
                    photos: session.photos,
                    images: images,
                    decisions: session.cullStore.decisions,
                    layout: layout,
                    sideCount: sideCount,
                    onSelectIndex: { session.select(index: $0) }
                )
                .onChange(of: timeline.date) { _, date in
                    finishIfNeeded(at: date)
                }
            }
            .clipShape(Rectangle())
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 24)
                    .onEnded { value in
                        if value.translation.width < -50 {
                            session.goNext()
                        } else if value.translation.width > 50 {
                            session.goPrevious()
                        }
                    }
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Sample the live (possibly mid-flight) position, then retarget so stacked
    /// steps share one settle window from this keypress.
    private func retargetFlow(to target: CGFloat) {
        let now = Date()
        let current = flowPosition(at: now)
        if abs(current - target) < 0.0001 {
            settledFlow = target
            flipAnim = nil
            return
        }
        settledFlow = current
        flipAnim = FlipFlowAnim(from: current, to: target, start: now, duration: flipDuration)
    }

    private func flowPosition(at date: Date) -> CGFloat {
        guard let flipAnim else { return settledFlow }
        return flipAnim.value(at: date)
    }

    private func finishIfNeeded(at date: Date) {
        guard let flipAnim, flipAnim.isComplete(at: date) else { return }
        settledFlow = flipAnim.to
        self.flipAnim = nil
    }

    private func reloadImages() {
        guard !session.photos.isEmpty else {
            images = [:]
            return
        }

        let center = session.selectionIndex
        let start = max(0, center - sideCount - 2)
        let end = min(session.photos.count - 1, center + sideCount + 2)

        for i in start...end {
            let photo = session.photos[i]
            let neighbor = i != center
            if let cached = session.previews.image(for: photo, neighbor: neighbor)
                ?? session.previews.image(for: photo, neighbor: !neighbor) {
                images[photo.id] = cached
            }
            session.previews.request(photo, neighbor: neighbor) { image in
                if let image {
                    images[photo.id] = image
                }
            }
        }

        session.previews.prefetch(around: center, in: session.photos, radius: sideCount + 6)
    }
}

// MARK: - Flip animation (explicit sample + retarget)

/// Ease-in-out settle — smooth start/end while still sampling mid-flight on interrupt.
private struct FlipFlowAnim {
    var from: CGFloat
    var to: CGFloat
    var start: Date
    var duration: TimeInterval

    func progress(at date: Date) -> CGFloat {
        guard duration > 0 else { return 1 }
        return CGFloat(max(0, min(1, date.timeIntervalSince(start) / duration)))
    }

    func value(at date: Date) -> CGFloat {
        let t = easeInOut(progress(at: date))
        return from + (to - from) * t
    }

    func isComplete(at date: Date) -> Bool {
        progress(at: date) >= 1
    }

    /// Smoothstep (Hermite) ease-in-out.
    private func easeInOut(_ t: CGFloat) -> CGFloat {
        t * t * (3 - 2 * t)
    }
}

// MARK: - Layout + stage

private struct CoverFlowLayout {
    let centerSlot: CGFloat
    let sideScale: CGFloat
    let focusScale: CGFloat
    let tiltDegrees: Double
    let layer1X: CGFloat
    let layer2X: CGFloat

    init(size: CGSize) {
        let focusScale: CGFloat = 1.30
        // Cap the base slot so L0 at focusScale still fits on screen.
        let maxFocusExtent = min(size.width * 0.56, size.height * 0.92)
        let centerSlot = min(size.width * 0.46, size.height * 0.94, maxFocusExtent / focusScale)
        let edgePad: CGFloat = 20
        let sideScale: CGFloat = 0.88
        let tiltDegrees: Double = 38
        let cosTilt = abs(CGFloat(Foundation.cos(tiltDegrees * .pi / 180)))
        let layer2Half = centerSlot * sideScale * 0.5 * max(cosTilt, 0.35)
        let layer2X = max(centerSlot * 0.55, size.width * 0.5 - edgePad - layer2Half)
        let layer1Base = min(centerSlot * 0.42, layer2X * 0.55) * 1.20
        let layer1X = min(layer1Base * 1.18, layer2X * 0.92)

        self.centerSlot = centerSlot
        self.sideScale = sideScale
        self.focusScale = focusScale
        self.tiltDegrees = tiltDegrees
        self.layer1X = layer1X
        self.layer2X = layer2X
    }
}

private struct CoverFlowStage: View {
    let flowPosition: CGFloat
    let photos: [PhotoItem]
    let images: [String: NSImage]
    let decisions: [String: CullDecision]
    let layout: CoverFlowLayout
    let sideCount: Int
    let onSelectIndex: (Int) -> Void

    var body: some View {
        ZStack {
            Color.black

            ForEach(visibleIndices, id: \.self) { index in
                let offset = CGFloat(index) - flowPosition
                coverCard(
                    photo: photos[index],
                    index: index,
                    offset: offset
                )
            }
        }
    }

    private var visibleIndices: [Int] {
        guard !photos.isEmpty else { return [] }
        // Keep one extra slot past L2 so enter/exit can fade instead of blinking out.
        let fadeSlots = 1
        let lo = max(0, Int(floor(flowPosition)) - sideCount - fadeSlots)
        let hi = min(photos.count - 1, Int(ceil(flowPosition)) + sideCount + fadeSlots)
        return Array(lo...hi).sorted { abs(CGFloat($0) - flowPosition) > abs(CGFloat($1) - flowPosition) }
    }

    /// Opacity for cards past L2. One slot of travel ≈ flip settle (200ms).
    private func edgeOpacity(absOffset a: CGFloat) -> Double {
        let fadeStart: CGFloat = 2
        let fadeEnd: CGFloat = 3
        if a <= fadeStart { return 1 }
        if a >= fadeEnd { return 0 }
        return Double(1 - (a - fadeStart) / (fadeEnd - fadeStart))
    }

    /// Full shadow through L1; eases off between L1 and L2.
    private func shadowStrength(absOffset a: CGFloat) -> CGFloat {
        if a <= 1 { return 1 }
        if a >= 2 { return 0 }
        return 2 - a
    }

    private func xPosition(offset: CGFloat) -> CGFloat {
        guard abs(offset) > 0.0001 else { return 0 }
        let sign: CGFloat = offset < 0 ? -1 : 1
        let a = abs(offset)
        let distance: CGFloat
        if a <= 1 {
            distance = layout.layer1X * a
        } else if a <= 2 {
            distance = layout.layer1X + (layout.layer2X - layout.layer1X) * (a - 1)
        } else {
            distance = layout.layer2X + (layout.layer2X - layout.layer1X) * (a - 2)
        }
        return sign * distance
    }

    @ViewBuilder
    private func coverCard(photo: PhotoItem, index: Int, offset: CGFloat) -> some View {
        let image = images[photo.id]
        let a = abs(offset)
        let isCenter = a < 0.5
        let tiltAmount = min(a, 1.0) * layout.tiltDegrees
        let angle = offset == 0 ? 0.0 : (offset < 0 ? tiltAmount : -tiltAmount)
        let scale: CGFloat = a <= 1
            ? (layout.focusScale + (layout.sideScale - layout.focusScale) * a)
            : layout.sideScale
        let decision = decisions[photo.id] ?? .undecided
        let edgeFade = edgeOpacity(absOffset: a)
        let maxSize = CGSize(width: layout.centerSlot, height: layout.centerSlot)
        // Size the card to the fitted image so corner radius clips real pixels, not empty plate.
        let cardSize = fittedSize(for: image, in: maxSize)
        let cornerRadius: CGFloat = 6

        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: cardSize.width, height: cardSize.height)
            } else if isCenter {
                ProgressView()
                    .controlSize(.regular)
            }
        }
        .frame(width: cardSize.width, height: cardSize.height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(alignment: .topTrailing) {
            if decision != .undecided, isCenter {
                Text(decision.label)
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .padding(8)
            }
        }
        // Shared square reserve — image centered in the slot.
        .frame(width: maxSize.width, height: maxSize.height, alignment: .center)
        .opacity(edgeFade)
        .scaleEffect(scale, anchor: .center)
        .rotation3DEffect(
            .degrees(angle),
            axis: (x: 0, y: 1, z: 0),
            anchor: .center,
            anchorZ: 0,
            perspective: 0.5
        )
        .offset(x: xPosition(offset: offset))
        .zIndex(Double(100 - a * 10))
        // Same full diffuse shadow on L0 and L1; fades out toward L2.
        .shadow(
            color: .black.opacity(Double(shadowStrength(absOffset: a))),
            radius: 96 * shadowStrength(absOffset: a),
            y: 22 * shadowStrength(absOffset: a)
        )
        .allowsHitTesting(edgeFade > 0.05)
        .onTapGesture { onSelectIndex(index) }
        .accessibilityLabel(photo.fileName)
    }

    private func fittedSize(for image: NSImage?, in maxSize: CGSize) -> CGSize {
        guard let image else { return maxSize }
        let iw = max(image.size.width, 1)
        let ih = max(image.size.height, 1)
        let scale = min(maxSize.width / iw, maxSize.height / ih)
        return CGSize(width: iw * scale, height: ih * scale)
    }
}
