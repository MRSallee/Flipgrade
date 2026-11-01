import AppKit
import SwiftUI

struct CoverFlowView: View {
    @EnvironmentObject private var session: FlipSession
    @ObservedObject private var previews = PreviewService.shared
    /// Settled Cover Flow index; live position comes from `flipAnim` while moving.
    @State private var settledFlow: CGFloat = 0
    @State private var flipAnim: FlipFlowAnim?
    @State private var displayedFlow: CGFloat = 0
    /// Cull fan/lift + flip sample clock.
    @State private var clockNow = Date()
    @State private var pendingPreviewIDs: Set<String> = []
    @State private var flashOpacity: Double = 0
    @State private var displayedFlash: StarFlash?
    @State private var flashHideTask: Task<Void, Never>?
    @State private var fanAnim: CullClockAnim?
    @State private var liftAnim: CullClockAnim?
    @State private var zoomMouseFraction = CGPoint(x: 0.5, y: 0.5)
    @State private var isHoveringPhoto = false
    /// Accumulated trackpad/mouse-wheel delta — OS momentum keeps feeding this after lift.
    @State private var scrollDebt: CGFloat = 0
    /// Last selection used to bias prefetch toward scroll direction.
    @State private var priorSelectionIndex: Int = 0

    private let sideCount = 2
    private let flipDuration: TimeInterval = 0.20
    private let liftAnimDuration: TimeInterval = 0.24
    private let fanAnimDuration: TimeInterval = 0.18
    private let flashFadeDuration: TimeInterval = 0.05
    private let flashHoldNanoseconds: UInt64 = 400_000_000
    private let flashFadeNanoseconds: UInt64 = 50_000_000
    /// Points of vertical scroll per photo step (trackpad units).
    private let scrollStepThreshold: CGFloat = 48

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                stage
                    .opacity(session.isPixelZoom ? 0 : 1)
                    .allowsHitTesting(!session.isPixelZoom)
                if session.isPixelZoom {
                    pixelZoomOverlay(size: geo.size)
                }
                previewLoadingChrome
                    .allowsHitTesting(false)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .onHover { hovering in
                isHoveringPhoto = hovering
            }
            .overlay {
                ZoomMouseTracker(
                    syncToken: zoomMouseSyncToken,
                    onFraction: { next in
                        if abs(next.x - zoomMouseFraction.x) > 0.0005
                            || abs(next.y - zoomMouseFraction.y) > 0.0005 {
                            zoomMouseFraction = next
                        }
                    }
                )
            }
            .background(
                ScrollWheelMonitor { dx, dy, natural in
                    handleScrollWheel(deltaX: dx, deltaY: dy, naturalScrolling: natural)
                }
            )
        }
        .onAppear {
            settledFlow = CGFloat(session.selectionIndex)
            displayedFlow = settledFlow
            priorSelectionIndex = session.selectionIndex
            flipAnim = nil
            fanAnim = nil
            clockNow = Date()
            reloadImages(aheadBias: 0)
        }
        .onChange(of: previews.viewportRevision) { _, _ in
            // Drop IDs that painted; never keep waiting state for photos outside the stage.
            prunePendingPreviewIDs()
        }
        .onChange(of: session.selectionIndex) { _, newValue in
            let delta = newValue - priorSelectionIndex
            priorSelectionIndex = newValue
            // Bias embed prefetch into the flip direction so forward coasts aren't blank.
            let bias = delta > 0 ? 6 : (delta < 0 ? -6 : 0)
            if session.isCullBusy {
                previews.endMotion()
                settledFlow = CGFloat(newValue)
                displayedFlow = settledFlow
                flipAnim = nil
                reloadImages(aheadBias: bias)
                session.flashRating(at: newValue)
            } else {
                // Pause demosaic / soft→full upgrades for the multi-flip burst, but still
                // sync warm RAM into viewport so newly visible cards aren't blank.
                previews.beginMotion()
                retargetFlow(to: CGFloat(newValue))
                session.flashRating(at: newValue)
                reloadImages(aheadBias: bias)
            }
            if session.isPixelZoom, flipAnim == nil, let photo = session.currentPhoto {
                previews.requestFullResolution(photo)
            }
        }
        .onChange(of: session.activePhotos.map(\.id)) { oldIDs, newIDs in
            guard oldIDs != newIDs else { return }
            let maxIndex = max(0, session.activePhotos.count - 1)
            settledFlow = CGFloat(min(session.selectionIndex, maxIndex))
            displayedFlow = settledFlow
            flipAnim = nil
            priorSelectionIndex = session.selectionIndex
            reloadImages(aheadBias: 0)
        }
        .onChange(of: session.fanInToken) { _, _ in
            fanAnim = CullClockAnim(from: 0, to: 1, start: Date(), duration: fanAnimDuration)
            clockNow = Date()
        }
        .onChange(of: session.liftingIDs) { _, ids in
            if ids.isEmpty {
                if session.arrivingCards.isEmpty {
                    liftAnim = nil
                }
            } else {
                liftAnim = CullClockAnim(from: 0, to: 1, start: Date(), duration: liftAnimDuration)
                clockNow = Date()
            }
        }
        .onChange(of: session.departingCards.map(\.id)) { _, _ in
            reloadImages(aheadBias: 0)
        }
        .onChange(of: session.arrivingCards.map(\.id)) { _, _ in
            reloadImages(aheadBias: 0)
        }
        .onChange(of: session.starFlash) { _, flash in
            guard let flash else { return }
            flashStarBadge(flash)
        }
    }

    private var zoomMouseSyncToken: String {
        let photoID = session.currentPhoto?.id ?? ""
        let hasBitmap = session.currentPhoto.map { zoomImage(for: $0) != nil } ?? false
        let loading = session.currentPhoto.map { previews.isLoadingFullResolution($0) } ?? false
        return "\(session.isPixelZoom)-\(photoID)-\(hasBitmap)-\(loading)-\(previews.viewportRevision)-\(previews.fullResolutionRevision)"
    }

    private func zoomImage(for photo: PhotoItem) -> NSImage? {
        previews.fullImage(for: photo)
            ?? previews.viewportImages[photo.id]
            ?? previews.displayImage(for: photo)
    }

    private var previewLoadingChrome: some View {
        VStack {
            Spacer()
            HStack {
                if !pendingPreviewIDs.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                        Text("Loading previews…")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding(14)
                }
                Spacer()
            }
        }
    }

    /// Stars sit at the bottom of the focus frame (not screen-center).
    private var starFlashOverlay: some View {
        // Keep the view mounted while opacity animates — gating on opacity removes it
        // instantly and looks like a blink instead of a fade.
        Group {
            if let flash = displayedFlash {
                flashGlyph(flash)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .opacity(flashOpacity)
                    .padding(.bottom, 18)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .allowsHitTesting(false)
    }

    /// Hover chrome: clickable stars (click current rating to clear).
    private var hoverStarBar: some View {
        let rating = session.ratingForCurrentPhoto()
        return InteractiveStarRow(
            rating: rating,
            maxStars: StarRating.maxStars,
            onPick: { session.toggleOrSetRating($0) }
        )
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .opacity(isHoveringPhoto ? 1 : 0)
        .allowsHitTesting(isHoveringPhoto)
        .animation(.easeOut(duration: 0.12), value: isHoveringPhoto)
    }

    private func handleScrollWheel(deltaX: CGFloat, deltaY: CGFloat, naturalScrolling: Bool) {
        guard !session.isCullBusy, !session.activePhotos.isEmpty else { return }
        // Vertical only — horizontal scroll ignored (felt bad as dual-axis).
        guard abs(deltaY) >= abs(deltaX) else { return }
        guard abs(deltaY) > 0.25 else { return }

        // Match System Settings → Trackpad → Natural scrolling.
        // Positive debt = toward next photo.
        let signed = naturalScrolling ? -deltaY : deltaY
        scrollDebt += signed

        // Drain debt into photo steps — momentum events keep arriving after finger lift,
        // so coasting comes from AppKit for free (no custom physics).
        let step = scrollStepThreshold
        while scrollDebt >= step {
            scrollDebt -= step
            session.goNext()
            if session.isCullBusy { break }
        }
        while scrollDebt <= -step {
            scrollDebt += step
            session.goPrevious()
            if session.isCullBusy { break }
        }
    }

    @ViewBuilder
    private func flashGlyph(_ flash: StarFlash) -> some View {
        switch flash.kind {
        case .rating(let stars):
            // 0★ → three empty stars (same row as 1–3).
            StarRow(rating: stars, maxStars: StarRating.maxStars)
        case .layer(let layer):
            switch layer {
            case .all:
                Text("ALL")
                    .font(.title2.weight(.bold))
                    .tracking(2)
            default:
                StarRow(rating: layer.minimumRating, maxStars: StarRating.maxStars)
            }
        }
    }

    private func flashStarBadge(_ flash: StarFlash) {
        flashHideTask?.cancel()

        let alreadyShowing = displayedFlash != nil && flashOpacity > 0.01
        displayedFlash = flash

        if alreadyShowing {
            // Swap glyph in place; stay fully visible and restart the hold.
            flashOpacity = 1
        } else {
            flashOpacity = 0
            // Keep this animation off the Cover Flow flip transaction.
            var fadeIn = Transaction(animation: .linear(duration: flashFadeDuration))
            fadeIn.disablesAnimations = false
            withTransaction(fadeIn) {
                flashOpacity = 1
            }
        }

        let holdBeforeFadeOut = alreadyShowing
            ? flashHoldNanoseconds
            : flashFadeNanoseconds + flashHoldNanoseconds

        flashHideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: holdBeforeFadeOut)
            guard !Task.isCancelled else { return }
            let fadeOut = Transaction(animation: .linear(duration: flashFadeDuration))
            withTransaction(fadeOut) {
                flashOpacity = 0
            }
            try? await Task.sleep(nanoseconds: flashFadeNanoseconds)
            guard !Task.isCancelled else { return }
            displayedFlash = nil
        }
    }

    private var stage: some View {
        GeometryReader { geo in
            let layout = CoverFlowLayout(size: geo.size)
            let fanRunning = fanAnim != nil
            let liftRunning = liftAnim != nil
            let restorePending = session.cullReversed
            let flipRunning = flipAnim != nil
            let clockRunning = liftRunning || fanRunning || restorePending || flipRunning

            ZStack {
                // Stage outside TimelineView so preview swaps redraw while idle.
                CoverFlowStage(
                    flowPosition: displayedFlow,
                    photos: session.activePhotos,
                    images: previews.viewportImages,
                    previewEpoch: previews.viewportRevision &+ session.previewTick,
                    enhancingPhotoIDs: previews.enhancingPhotoIDs,
                    departingCards: session.departingCards,
                    arrivingCards: session.arrivingCards,
                    // Follow the visual center while coasting — selection can already be
                    // at first/last while displayedFlow is still catching up.
                    focusID: visualFocusID,
                    departingFromCenter: session.isDepartingFromCenter,
                    // Keep center frame fixed on normal flips; deck slides behind it.
                    pinnedFocus: !session.isDepartingFromCenter,
                    fanStableIDs: session.fanStableIDs,
                    fanFromOffsets: session.fanFromOffsets,
                    fanArmed: session.fanArmed,
                    cullReversed: session.cullReversed,
                    showEnhanceBadge: flipAnim == nil,
                    fanClock: fanAnim.map { (start: $0.start, duration: $0.duration) },
                    liftClock: liftAnim.map { (start: $0.start, duration: $0.duration) },
                    now: clockNow,
                    layout: layout,
                    sideCount: sideCount,
                    onSelectIndex: { index in
                        if index == session.selectionIndex {
                            session.togglePixelZoom()
                        } else {
                            session.select(index: index)
                        }
                    },
                    onDoubleTapIndex: { index in
                        if index == session.selectionIndex {
                            session.toggleFilterRelativeRating()
                        } else {
                            session.select(index: index)
                        }
                    }
                )
                .transaction { $0.animation = nil }

                // Stars anchored to the focus card footprint.
                ZStack {
                    starFlashOverlay
                        .opacity(isHoveringPhoto ? 0 : 1)
                        .allowsHitTesting(false)
                    hoverStarBar
                }
                .frame(
                    width: layout.centerSlot * layout.focusScale,
                    height: layout.centerSlot * layout.focusScale
                )

                TimelineView(
                    .animation(minimumInterval: 1.0 / 60.0, paused: !clockRunning)
                ) { timeline in
                    Color.clear
                        .onChange(of: timeline.date) { _, newDate in
                            guard clockRunning else { return }
                            clockNow = newDate
                            if flipRunning {
                                let flow = flowPosition(at: newDate)
                                if abs(flow - displayedFlow) > 0.0001 {
                                    displayedFlow = flow
                                }
                                finishFlipIfNeeded(at: newDate)
                            }
                            if fanRunning || liftRunning || restorePending {
                                finishFanIfNeeded(at: newDate)
                                finishLiftIfNeeded(at: newDate)
                            }
                        }
                }
                .allowsHitTesting(false)
            }
            .clipShape(Rectangle())
            .contentShape(Rectangle())
            .gesture(flipDrag)
            .onAppear { clockNow = Date() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 1:1 pixel zoom — window maps onto the photo; mouse position selects the region.
    private func pixelZoomOverlay(size: CGSize) -> some View {
        let photo = session.currentPhoto
        let image = photo.flatMap { zoomImage(for: $0) }
        let loadingFull = photo.map { previews.isLoadingFullResolution($0) } ?? false
        return ZStack {
            Color.black
            if let image {
                let bitmapPixels = PreviewService.pixelSize(image)
                // Upscale the current bitmap to full-res *long edge* while keeping its aspect
                // ratio — never force native WxH onto a differently oriented proxy (that skews).
                let layoutPixels: (width: Int, height: Int) = {
                    if let photo, previews.fullImage(for: photo) != nil {
                        return bitmapPixels
                    }
                    guard let photo,
                          let native = previews.fullPixelSize(for: photo)
                    else { return bitmapPixels }
                    return Self.zoomLayoutSize(bitmap: bitmapPixels, native: native)
                }()
                let backing = NSScreen.main?.backingScaleFactor ?? 2
                let scale = 1.0 / max(backing, 1)
                // 1 image pixel = 1 device pixel (using full-res layout size).
                let display = CGSize(
                    width: CGFloat(layoutPixels.width) * scale,
                    height: CGFloat(layoutPixels.height) * scale
                )
                let fx = min(1, max(0, zoomMouseFraction.x))
                let fy = min(1, max(0, zoomMouseFraction.y))
                let originX = fx * (size.width - display.width)
                let originY = fy * (size.height - display.height)

                Image(nsImage: image)
                    .resizable()
                    .interpolation(loadingFull ? .medium : .high)
                    .frame(width: display.width, height: display.height)
                    .position(
                        x: originX + display.width / 2,
                        y: originY + display.height / 2
                    )
                    // Don't include pixel width in id — soft→full swap must not remount.
                    .id("zoom-\(photo?.id ?? "")")
                    .transaction { $0.animation = nil }
            } else {
                ProgressView()
                    .tint(.white)
            }

            if loadingFull {
                EnhanceQualityBadge()
                    .padding(14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .allowsHitTesting(false)
            }

            // Tap target under star chrome so star buttons still receive clicks.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    session.toggleFilterRelativeRating()
                }
                .onTapGesture(count: 1) {
                    session.togglePixelZoom()
                }

            hoverStarBar
                .frame(width: size.width, height: size.height)
        }
        .frame(width: size.width, height: size.height)
    }

    /// Full-res layout size for a proxy bitmap: same aspect as the bitmap, long edge = native.
    private static func zoomLayoutSize(
        bitmap: (width: Int, height: Int),
        native: (width: Int, height: Int)
    ) -> (width: Int, height: Int) {
        let bitmapLong = max(bitmap.width, bitmap.height)
        guard bitmapLong > 0 else { return bitmap }
        let targetLong = max(native.width, native.height)
        let s = CGFloat(targetLong) / CGFloat(bitmapLong)
        return (
            max(1, Int((CGFloat(bitmap.width) * s).rounded())),
            max(1, Int((CGFloat(bitmap.height) * s).rounded()))
        )
    }

    private var flipDrag: some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                guard !session.isCullBusy else { return }
                if value.translation.width < -50 {
                    session.goNext()
                } else if value.translation.width > 50 {
                    session.goPrevious()
                } else if value.translation.height < -50 {
                    session.goLayerDown()
                } else if value.translation.height > 50 {
                    session.goLayerUp()
                }
            }
    }

    /// Photo under the visual center. During a flip this tracks `displayedFlow`, not
    /// `selectionIndex`, so a fast run to either end doesn't pin the destination early.
    private var visualFocusID: String? {
        let photos = session.activePhotos
        guard !photos.isEmpty else { return nil }
        let idx: Int
        if flipAnim != nil {
            idx = Int(displayedFlow.rounded())
        } else {
            idx = session.selectionIndex
        }
        return photos[min(max(0, idx), photos.count - 1)].id
    }

    /// Sample the live (possibly mid-flight) position, then retarget.
    private func retargetFlow(to target: CGFloat) {
        let now = Date()
        let current = flowPosition(at: now)
        if abs(current - target) < 0.0001 {
            settledFlow = target
            displayedFlow = target
            flipAnim = nil
            return
        }
        settledFlow = current
        flipAnim = FlipFlowAnim(from: current, to: target, start: now, duration: flipDuration)
        displayedFlow = current
        clockNow = now
    }

    private func flowPosition(at date: Date) -> CGFloat {
        guard let flipAnim else { return settledFlow }
        return flipAnim.value(at: date)
    }

    private func finishFlipIfNeeded(at date: Date) {
        guard let flipAnim, flipAnim.isComplete(at: date) else { return }
        settledFlow = flipAnim.to
        displayedFlow = flipAnim.to
        self.flipAnim = nil
        previews.endMotion()
        reloadImages(aheadBias: 0)
        if session.isPixelZoom, let photo = session.currentPhoto {
            previews.requestFullResolution(photo)
        }
    }

    private func finishFanIfNeeded(at date: Date) {
        guard let fanAnim, fanAnim.isComplete(at: date) else { return }
        self.fanAnim = nil
        session.clearFanArmed()
    }

    private func finishLiftIfNeeded(at date: Date) {
        guard let liftAnim, liftAnim.isComplete(at: date) else { return }
        if session.liftingIDs.isEmpty {
            self.liftAnim = nil
        }
    }

    private func reloadImages(aheadBias: Int) {
        if session.activePhotos.isEmpty && session.departingCards.isEmpty && session.arrivingCards.isEmpty {
            previews.clearViewport()
            pendingPreviewIDs = []
            return
        }

        // Rebuild waiting set each pass — cancelled/in-flight embeds must not leak the chrome.
        var waiting = Set<String>()

        if !session.activePhotos.isEmpty {
            let center = session.selectionIndex
            // Visible cards first (sync warm RAM → viewport), then direction-biased prefetch.
            let start = max(0, center - sideCount - 2)
            let end = min(session.activePhotos.count - 1, center + sideCount + 2)

            for i in start...end {
                let photo = session.activePhotos[i]
                loadImage(for: photo, priority: i == center ? .focused : .normal, waiting: &waiting)
            }

            session.previews.prefetch(
                around: center,
                in: session.activePhotos,
                radius: sideCount + 3,
                aheadBias: aheadBias
            )
        }

        // Leavers: paint from RAM only — never request or count toward "Loading previews…".
        for card in session.departingCards {
            if let display = session.previews.displayImage(for: card.photo) {
                previews.setViewportImage(display, for: card.photo.id)
            }
        }
        for card in session.arrivingCards {
            loadImage(for: card.photo, priority: .normal, waiting: &waiting)
        }

        pendingPreviewIDs = waiting
    }

    private func prunePendingPreviewIDs() {
        guard !pendingPreviewIDs.isEmpty else { return }
        let stageIDs = stagePhotoIDs()
        pendingPreviewIDs = Set(pendingPreviewIDs.filter { id in
            stageIDs.contains(id) && previews.viewportImages[id] == nil
        })
    }

    private func stagePhotoIDs() -> Set<String> {
        var ids = Set<String>()
        if !session.activePhotos.isEmpty {
            let center = session.selectionIndex
            let start = max(0, center - sideCount - 2)
            let end = min(session.activePhotos.count - 1, center + sideCount + 2)
            for i in start...end {
                ids.insert(session.activePhotos[i].id)
            }
        }
        // Departing cards never belong in the loading chrome.
        for card in session.arrivingCards { ids.insert(card.photo.id) }
        return ids
    }

    private func loadImage(for photo: PhotoItem, priority: PreviewPriority, waiting: inout Set<String>) {
        if let display = session.previews.displayImage(for: photo) {
            // Rendered proxy when ready (same look for focus + neighbors); else embedded placeholder.
            previews.setViewportImage(display, for: photo.id)
        } else if previews.viewportImages[photo.id] == nil {
            waiting.insert(photo.id)
        }

        // Completion may never run (cancelled / already in-flight) — waiting set is rebuilt on reload.
        session.previews.request(photo, priority: priority, completion: nil)
    }
}

// MARK: - Stars

private struct StarRow: View {
    let rating: Int
    let maxStars: Int

    var body: some View {
        HStack(spacing: 5) {
            ForEach(1...maxStars, id: \.self) { star in
                Image(systemName: star <= rating ? "star.fill" : "star")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.primary)
            }
        }
    }
}

private struct InteractiveStarRow: View {
    let rating: Int
    let maxStars: Int
    let onPick: (Int) -> Void

    var body: some View {
        HStack(spacing: 5) {
            ForEach(1...maxStars, id: \.self) { star in
                Button {
                    onPick(star)
                } label: {
                    Image(systemName: star <= rating ? "star.fill" : "star")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(star == rating ? "Clear rating" : "Rate \(star)★")
            }
        }
    }
}

/// Eye + capsule bar while a higher-quality preview is decoding (indeterminate — no byte %).
private struct EnhanceQualityBadge: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            // Ease between ~15% and ~85% so it reads as progress without a real meter.
            let pulse = 0.5 + 0.5 * sin(t * 2.2)
            let fill = 0.15 + 0.70 * pulse

            HStack(spacing: 7) {
                Image(systemName: "eye")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .strokeBorder(Color.white.opacity(0.95), lineWidth: 1.2)
                        Capsule()
                            .fill(Color.white)
                            .frame(width: max(5, (geo.size.width - 3) * fill))
                            .padding(1.5)
                    }
                }
                .frame(width: 78, height: 7)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .accessibilityLabel("Building higher quality preview")
    }
}

// MARK: - Flip animation (continuous strip)

/// Ease-out strip scroll — retarget samples mid-flight position.
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
        let t = easeOut(progress(at: date))
        return from + (to - from) * t
    }

    func isComplete(at date: Date) -> Bool {
        progress(at: date) >= 1
    }

    private func easeOut(_ t: CGFloat) -> CGFloat {
        1 - (1 - t) * (1 - t)
    }
}

// MARK: - Cull animation

/// Wall-clock anim for cull fan/lift.
private struct CullClockAnim {
    var from: CGFloat
    var to: CGFloat
    var start: Date
    var duration: TimeInterval

    func progress(at date: Date) -> CGFloat {
        guard duration > 0 else { return 1 }
        return CGFloat(max(0, min(1, date.timeIntervalSince(start) / duration)))
    }

    func isComplete(at date: Date) -> Bool {
        progress(at: date) >= 1
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
    let previewEpoch: UInt64
    let enhancingPhotoIDs: Set<String>
    let departingCards: [DepartingCard]
    let arrivingCards: [DepartingCard]
    let focusID: String?
    /// Old L0 is flying out — new focus should slide L1→center with that lift.
    let departingFromCenter: Bool
    /// When true, center photo stays fixed and swaps instantly; deck slides behind.
    let pinnedFocus: Bool
    let fanStableIDs: Set<String>
    let fanFromOffsets: [String: CGFloat]
    let fanArmed: Bool
    let cullReversed: Bool
    /// Hide enhance chrome while Cover Flow is mid-slide.
    let showEnhanceBadge: Bool
    /// Fan clock: discard L1→L2, restore L2→L1.
    let fanClock: (start: Date, duration: TimeInterval)?
    let liftClock: (start: Date, duration: TimeInterval)?
    let now: Date
    let layout: CoverFlowLayout
    let sideCount: Int
    let onSelectIndex: (Int) -> Void
    var onDoubleTapIndex: ((Int) -> Void)? = nil

    /// Lift travel — far enough to clear the stage before fade.
    private var liftDistance: CGFloat { layout.centerSlot * 0.95 }

    private var arrivingIDs: Set<String> { Set(arrivingCards.map(\.id)) }

    private var pinnedFocusPhoto: PhotoItem? {
        guard pinnedFocus, let focusID else { return nil }
        return photos.first { $0.id == focusID }
    }

    var body: some View {
        // Keep revision in the body graph so soft→full swaps still redraw without remounting Images.
        let _ = previewEpoch
        ZStack {
            Color.black

            // Pinned overlay only when the new focus already has pixels. Otherwise its gray
            // placeholder would cover the outgoing deck card (instant blank on every cold flip).
            let pinnedHasImage = pinnedFocusPhoto.map { images[$0.id] != nil } ?? false

            ForEach(drawnIndices, id: \.self) { index in
                let photo = photos[index]
                if arrivingIDs.contains(photo.id) {
                    EmptyView()
                } else {
                    let offset = CGFloat(index) - flowPosition
                    // Pinned focus is drawn as a fixed overlay — hide its deck copy near center
                    // so it doesn't slide. Neighbors (including the photo leaving center) still move.
                    let hideUnderPin = pinnedHasImage
                        && photo.id == focusID
                        && abs(offset) < 0.55
                    if hideUnderPin {
                        EmptyView()
                    } else {
                        coverCard(
                            photo: photo,
                            index: index,
                            offset: offset,
                            lifting: false,
                            liftReversed: false,
                            skipGrayLift: false,
                            fanStable: fanStableIDs.contains(photo.id),
                            fromOffset: fanFromOffsets[photo.id],
                            focusHandoff: departingFromCenter && photo.id == focusID
                        )
                    }
                }
            }

            ForEach(departingCards) { card in
                coverCard(
                    photo: card.photo,
                    index: 0,
                    offset: card.offset,
                    lifting: true,
                    liftReversed: false,
                    skipGrayLift: card.skipGray,
                    fanStable: true,
                    fromOffset: nil,
                    focusHandoff: false
                )
            }

            ForEach(arrivingCards) { card in
                coverCard(
                    photo: card.photo,
                    index: 0,
                    offset: card.offset,
                    lifting: true,
                    liftReversed: true,
                    skipGrayLift: false,
                    fanStable: true,
                    fromOffset: nil,
                    focusHandoff: false
                )
            }

            if pinnedHasImage,
               let photo = pinnedFocusPhoto,
               let index = photos.firstIndex(where: { $0.id == photo.id }) {
                pinnedFocusCard(photo: photo, index: index)
            }
        }
    }

    /// Index range on stage (unordered).
    private var visibleIndices: [Int] {
        guard !photos.isEmpty else { return [] }
        let last = photos.count - 1
        let clampedFlow = min(max(flowPosition, 0), CGFloat(last))
        let fadeSlots = 1
        let lo = max(0, Int(floor(clampedFlow)) - sideCount - fadeSlots)
        let hi = min(last, Int(ceil(clampedFlow)) + sideCount + fadeSlots)
        guard lo <= hi else { return Array(photos.indices) }
        return Array(lo...hi)
    }

    /// Far → near so the focus card paints last. Identity stays `id: \.self` (index).
    private var drawnIndices: [Int] {
        visibleIndices.sorted { a, b in
            abs(CGFloat(a) - flowPosition) > abs(CGFloat(b) - flowPosition)
        }
    }

    private func edgeOpacity(absOffset a: CGFloat) -> Double {
        let fadeStart: CGFloat = 2
        let fadeEnd: CGFloat = 3
        if a <= fadeStart { return 1 }
        if a >= fadeEnd { return 0 }
        return Double(1 - (a - fadeStart) / (fadeEnd - fadeStart))
    }

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

    /// Discard: L1 then L2. Restore: L2 then L1.
    /// Focus handoff (L1→center) rides the discard lift so it doesn't snap under the gray L0.
    private func localFanProgress(
        absOffset a: CGFloat,
        stable: Bool,
        fromOffset: CGFloat?,
        focusHandoff: Bool
    ) -> CGFloat {
        if stable { return 1 }

        // New L0 slides in from L1 while old L0 grays/flies (same lift clock).
        if focusHandoff, fromOffset != nil, let liftClock, fanClock == nil {
            let elapsed = now.timeIntervalSince(liftClock.start)
            let total = liftClock.duration
            // Start with the gray beat so replacement begins moving as discards commit to flying.
            let start = total * 0.22
            let u = CGFloat(max(0, min(1, (elapsed - start) / max(0.001, total - start))))
            return u * u * (3 - 2 * u)
        }

        // Destination center with no reflow — already home.
        if a < 0.5 && fromOffset == nil { return 1 }
        // Handoff finished; don't re-run as a normal L1 fan.
        if a < 0.5 && fromOffset != nil && fanClock != nil { return 1 }

        guard let fanClock else {
            return fanArmed ? 0 : 1
        }
        let resolvedLayer = a < 0.5 ? 1 : max(1, min(2, Int(a.rounded())))
        let half = fanClock.duration * 0.5
        let delay: TimeInterval
        if cullReversed {
            delay = resolvedLayer == 2 ? 0.0 : half
        } else {
            delay = resolvedLayer == 1 ? 0.0 : half
        }
        let elapsed = now.timeIntervalSince(fanClock.start) - delay
        let u = CGFloat(max(0, min(1, elapsed / max(0.001, half))))
        return u * u * (3 - 2 * u)
    }

    /// Forward: gray → slide up → fade at top.
    /// Reversed: fade in at top → slide down (full color — no grayscale step).
    private func liftMotion(
        baseOpacity: Double,
        skipGray: Bool,
        reversed: Bool
    ) -> (y: CGFloat, opacity: Double, gray: Bool) {
        guard let liftClock else {
            // Waiting to drop in: park at the end of the forward lift (above, faded).
            if reversed {
                return (-liftDistance, 0, false)
            }
            return (0, baseOpacity, false)
        }
        let elapsed = now.timeIntervalSince(liftClock.start)
        let total = liftClock.duration

        if reversed {
            // Time-reverse slide/fade only — skip the gray hold so returners stay in color.
            let forwardElapsed = max(0, total - elapsed)
            let motion = forwardLiftMotion(
                elapsed: forwardElapsed,
                total: total,
                baseOpacity: baseOpacity,
                skipGray: true
            )
            return (motion.y, motion.opacity, false)
        }

        return forwardLiftMotion(elapsed: elapsed, total: total, baseOpacity: baseOpacity, skipGray: skipGray)
    }

    private func forwardLiftMotion(
        elapsed: TimeInterval,
        total: TimeInterval,
        baseOpacity: Double,
        skipGray: Bool
    ) -> (y: CGFloat, opacity: Double, gray: Bool) {
        let grayEnd = skipGray ? 0.0 : total * 0.22
        let slideEnd = skipGray ? total * 0.72 : total * 0.78

        let slideU: CGFloat
        if elapsed <= grayEnd {
            slideU = 0
        } else if elapsed >= slideEnd {
            slideU = 1
        } else {
            let u = CGFloat((elapsed - grayEnd) / max(0.001, slideEnd - grayEnd))
            slideU = u * u
        }

        let fadeU: CGFloat
        if elapsed <= slideEnd {
            fadeU = 0
        } else {
            fadeU = CGFloat(max(0, min(1, (elapsed - slideEnd) / max(0.001, total - slideEnd))))
        }

        return (-liftDistance * slideU, baseOpacity * Double(1 - fadeU), true)
    }

    private func tiltAngle(for offset: CGFloat) -> Double {
        guard abs(offset) > 0.0001 else { return 0 }
        let tiltAmount = min(abs(offset), 1.0) * layout.tiltDegrees
        return offset < 0 ? tiltAmount : -tiltAmount
    }

    /// Slot newcomers ease in from — past the edge fade so they don't pop opaque.
    private func fanEntryOffset(for offset: CGFloat) -> CGFloat {
        guard abs(offset) > 0.0001 else { return 0 }
        let sign: CGFloat = offset < 0 ? -1 : 1
        return sign * max(abs(offset) + 0.65, 3.0)
    }

    /// Start pose for fan-in: last slot when reflowing, past fade-edge for newcomers.
    private func fanStart(offset: CGFloat, fromOffset: CGFloat?) -> (x: CGFloat, angle: Double) {
        if let fromOffset {
            return (xPosition(offset: fromOffset), tiltAngle(for: fromOffset))
        }
        let entry = fanEntryOffset(for: offset)
        return (xPosition(offset: entry), tiltAngle(for: entry))
    }

    @ViewBuilder
    private func pinnedFocusCard(photo: PhotoItem, index: Int) -> some View {
        let image = images[photo.id]
        let maxSize = CGSize(width: layout.centerSlot, height: layout.centerSlot)
        let cardSize = fittedSize(for: image, in: maxSize)
        let cornerRadius: CGFloat = 6

        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color(white: 0.14))
                .frame(width: cardSize.width, height: cardSize.height)

            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: cardSize.width, height: cardSize.height)
                    .id("\(photo.id)-pinned-ready")
                    .transaction { $0.animation = nil }
            }

            if showEnhanceBadge, enhancingPhotoIDs.contains(photo.id) {
                EnhanceQualityBadge()
                    .padding(10)
                    .frame(width: cardSize.width, height: cardSize.height, alignment: .bottomLeading)
            }
        }
        .frame(width: cardSize.width, height: cardSize.height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .frame(width: maxSize.width, height: maxSize.height, alignment: .center)
        .scaleEffect(layout.focusScale, anchor: .center)
        .zIndex(120)
        .shadow(color: .black.opacity(1), radius: 96, y: 22)
        .onTapGesture(count: 2) {
            if let onDoubleTapIndex {
                onDoubleTapIndex(index)
            } else {
                onSelectIndex(index)
            }
        }
        .onTapGesture(count: 1) {
            onSelectIndex(index)
        }
        .accessibilityLabel(photo.fileName)
        .transaction { $0.animation = nil }
    }

    @ViewBuilder
    private func coverCard(
        photo: PhotoItem,
        index: Int,
        offset: CGFloat,
        lifting: Bool,
        liftReversed: Bool,
        skipGrayLift: Bool,
        fanStable: Bool,
        fromOffset: CGFloat?,
        focusHandoff: Bool
    ) -> some View {
        let image = images[photo.id]
        let a = abs(offset)
        let isCenter = a < 0.5 && !lifting
        let finalAngle = tiltAngle(for: offset)
        let maxSize = CGSize(width: layout.centerSlot, height: layout.centerSlot)
        let cardSize = fittedSize(for: image, in: maxSize)
        let cornerRadius: CGFloat = 6

        let finalX = xPosition(offset: offset)
        let fanT = localFanProgress(
            absOffset: a,
            stable: fanStable || (isCenter && fromOffset == nil),
            fromOffset: fromOffset,
            focusHandoff: focusHandoff
        )
        let start = fanStart(offset: offset, fromOffset: fromOffset)
        let liveX = start.x + (finalX - start.x) * fanT
        let liveAngle = start.angle + (finalAngle - start.angle) * fanT
        // Pose on screen (held/reflow start) — depth, fade, and scale follow this, not the destination.
        let poseOffset: CGFloat = {
            if lifting { return offset }
            if let fromOffset {
                return fromOffset + (offset - fromOffset) * fanT
            }
            let entry = fanEntryOffset(for: offset)
            return entry + (offset - entry) * fanT
        }()
        let poseA = abs(poseOffset)
        let baseScale: CGFloat = poseA <= 1
            ? (layout.focusScale + (layout.sideScale - layout.focusScale) * poseA)
            : layout.sideScale
        let handoffCenter = focusHandoff && fanT > 0.5
        let scale = baseScale
        let baseOpacity = edgeOpacity(absOffset: poseA)

        let lift = lifting
            ? liftMotion(baseOpacity: baseOpacity, skipGray: skipGrayLift, reversed: liftReversed)
            : (y: 0, opacity: baseOpacity, gray: false)
        let grayed = lift.gray

        ZStack {
            // Dark placeholder while Drive/ImageIO hydrate the embedded preview.
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color(white: 0.14))
                .frame(width: cardSize.width, height: cardSize.height)

            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: cardSize.width, height: cardSize.height)
                    // Remount only when pixels first appear (nil→image). Soft→full keeps this
                    // id so in-flight flip isn't reset; previewEpoch in body still refreshes bits.
                    .id("\(photo.id)-ready")
                    .transaction { $0.animation = nil }
            }

            if isCenter, showEnhanceBadge, enhancingPhotoIDs.contains(photo.id) {
                EnhanceQualityBadge()
                    .padding(10)
                    .frame(width: cardSize.width, height: cardSize.height, alignment: .bottomLeading)
            }
        }
        .frame(width: cardSize.width, height: cardSize.height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .frame(width: maxSize.width, height: maxSize.height, alignment: .center)
        .saturation(grayed ? 0.0 : 1.0)
        .brightness(grayed ? -0.12 : 0)
        .opacity(lift.opacity)
        .scaleEffect(scale, anchor: .center)
        .rotation3DEffect(
            .degrees(liveAngle),
            axis: (x: 0, y: 1, z: 0),
            anchor: .center,
            anchorZ: 0,
            perspective: 0.5
        )
        .offset(x: liveX, y: lift.y)
        // Same depth formula as before the preview-chase rewrites.
        .zIndex(
            Double(100 - poseA * 10)
                + (isCenter ? 1 : 0)
                + (lifting ? 1 : 0)
                + (handoffCenter ? 0.25 : 0)
                - (focusHandoff && fanT < 0.95 ? 0.5 : 0)
        )
        .shadow(
            color: .black.opacity(Double(shadowStrength(absOffset: poseA))),
            radius: 96 * shadowStrength(absOffset: poseA),
            y: 22 * shadowStrength(absOffset: poseA)
        )
        .allowsHitTesting(lift.opacity > 0.05 && !lifting)
        .onTapGesture(count: 2) {
            if let onDoubleTapIndex {
                onDoubleTapIndex(index)
            } else {
                onSelectIndex(index)
            }
        }
        .onTapGesture(count: 1) {
            onSelectIndex(index)
        }
        .accessibilityLabel(photo.fileName)
    }

    private func fittedSize(for image: NSImage?, in maxSize: CGSize) -> CGSize {
        if let image {
            let px = PreviewService.pixelSize(image)
            let iw = CGFloat(max(px.width, 1))
            let ih = CGFloat(max(px.height, 1))
            let scale = min(maxSize.width / iw, maxSize.height / ih)
            return CGSize(width: iw * scale, height: ih * scale)
        }
        let aspect: CGFloat = 3.0 / 2.0
        if maxSize.width / maxSize.height > aspect {
            let h = maxSize.height
            return CGSize(width: h * aspect, height: h)
        }
        let w = maxSize.width
        return CGSize(width: w, height: w / aspect)
    }
}

/// Local scroll-wheel monitor — receives deltas without stealing click hit-testing.
private struct ScrollWheelMonitor: NSViewRepresentable {
    /// deltaX, deltaY, naturalScrolling (`event.isDirectionInvertedFromDevice`).
    var onScroll: (CGFloat, CGFloat, Bool) -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ nsView: MonitorView, context: Context) {
        nsView.onScroll = onScroll
    }

    final class MonitorView: NSView {
        var onScroll: ((CGFloat, CGFloat, Bool) -> Void)?
        /// Event monitor token — torn down in `viewDidMoveToWindow` when detached.
        nonisolated(unsafe) private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.onScroll?(
                    event.scrollingDeltaX,
                    event.scrollingDeltaY,
                    event.isDirectionInvertedFromDevice
                )
                return event
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// AppKit mouse tracking — SwiftUI `onContinuousHover` only updates while moving,
/// so next-photo while zoomed would keep a stale / center pan until the first move.
struct ZoomMouseTracker: NSViewRepresentable {
    var syncToken: String
    var onFraction: (CGPoint) -> Void

    func makeNSView(context: Context) -> TrackerView {
        let view = TrackerView()
        view.onFraction = onFraction
        return view
    }

    func updateNSView(_ nsView: TrackerView, context: Context) {
        nsView.onFraction = onFraction
        if nsView.syncToken != syncToken {
            nsView.syncToken = syncToken
            nsView.sampleMouse()
        }
    }

    final class TrackerView: NSView {
        var onFraction: ((CGPoint) -> Void)?
        var syncToken: String = ""

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.backgroundColor = NSColor.clear.cgColor
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.acceptsMouseMovedEvents = true
            sampleMouse()
        }

        /// Let Cover Flow gestures / keys through; tracking areas still receive moves.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            // First SwiftUI pass often has zero bounds — re-sample once laid out
            // or the pan stays at a bogus fraction until the mouse moves.
            if bounds.width > 1, bounds.height > 1 {
                sampleMouse()
            }
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas {
                removeTrackingArea(area)
            }
            let options: NSTrackingArea.Options = [
                .activeInKeyWindow,
                .mouseMoved,
                .inVisibleRect,
                .enabledDuringMouseDrag
            ]
            addTrackingArea(NSTrackingArea(rect: .zero, options: options, owner: self, userInfo: nil))
        }

        override func mouseMoved(with event: NSEvent) {
            report(windowPoint: event.locationInWindow)
        }

        override func mouseDragged(with event: NSEvent) {
            report(windowPoint: event.locationInWindow)
        }

        func sampleMouse() {
            guard let window else { return }
            let screenPoint = NSEvent.mouseLocation
            let windowPoint = window.convertPoint(fromScreen: screenPoint)
            report(windowPoint: windowPoint)
        }

        private func report(windowPoint: CGPoint) {
            let local = convert(windowPoint, from: nil)
            let w = max(bounds.width, 1)
            let h = max(bounds.height, 1)
            // AppKit is bottom-left; SwiftUI pan uses top-left.
            let next = CGPoint(
                x: min(1, max(0, local.x / w)),
                y: min(1, max(0, 1 - (local.y / h)))
            )
            onFraction?(next)
        }
    }
}
