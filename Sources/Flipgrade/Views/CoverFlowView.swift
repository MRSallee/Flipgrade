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
    @State private var fanAnim: CullClockAnim?
    @State private var liftAnim: CullClockAnim?
    @State private var zoomMouseFraction = CGPoint(x: 0.5, y: 0.5)
    /// Accumulated trackpad/mouse-wheel delta — OS momentum keeps feeding this after lift.
    @State private var scrollDebt: CGFloat = 0
    /// Last selection used to bias prefetch toward scroll direction.
    @State private var priorSelectionIndex: Int = 0

    private let sideCount = 2
    private let flipDuration: TimeInterval = 0.20
    private let liftAnimDuration: TimeInterval = 0.24
    private let fanAnimDuration: TimeInterval = 0.18
    /// Points of vertical scroll per photo step (trackpad units).
    private let scrollStepThreshold: CGFloat = 48

    var body: some View {
        GeometryReader { geo in
            let header = CoverFlowLayout.headerHeight(safeTop: geo.safeAreaInsets.top)
            let stageSize = CGSize(width: geo.size.width, height: max(1, geo.size.height))
            let layout = CoverFlowLayout(size: stageSize, bottomInset: header)
            let inset = layout.bottomInset
            let focusLeft = max(0, (stageSize.width - layout.focusMaxWidth) / 2)
            // Window edge inset + same inset between text and the focus fit box.
            let textMaxWidth = max(0, focusLeft - 2 * inset)

            ZStack {
                Color.black
                stage(layout: layout, stageSize: stageSize)
                    .opacity(session.isPixelZoom ? 0 : 1)
                    .allowsHitTesting(!session.isPixelZoom)
                if session.isPixelZoom {
                    pixelZoomOverlay(size: geo.size)
                }
                infoChrome(inset: inset, textMaxWidth: textMaxWidth)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
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

    /// True while the focused photo still needs its first pixels or a soft→full upgrade.
    private var isFocusPreviewLoading: Bool {
        guard let photo = session.currentPhoto else { return false }
        if previews.enhancingPhotoIDs.contains(photo.id) { return true }
        if previews.viewportImages[photo.id] == nil,
           previews.displayImage(for: photo) == nil {
            return true
        }
        return false
    }

    /// TL folder/filter · BL file/date/rating · TR focused-preview loader.
    /// Edge padding matches the focus bottom inset; text width stops an inset short of the focus box.
    private func infoChrome(inset: CGFloat, textMaxWidth: CGFloat) -> some View {
        let folderName = session.folderURL?.lastPathComponent ?? ""
        let filterStars = session.ratingLayer.minimumRating
        let photo = session.currentPhoto
        let fileName = photo?.fileName ?? ""
        let dateText = photo.flatMap { PhotoCaptureDate.displayString(for: $0.url) } ?? ""
        let rating = session.ratingForCurrentPhoto()
        let colWidth = max(0, textMaxWidth)

        return ZStack {
            // Top-left — folder + active filter.
            VStack(alignment: .leading, spacing: FlipgradeFont.stackSpacing) {
                if !folderName.isEmpty {
                    Text(folderName)
                        .font(FlipgradeFont.folder)
                        .lineSpacing(FlipgradeFont.folderLineSpacing)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if session.ratingLayer == .all {
                    StarRow(rating: 0, maxStars: StarRating.maxStars)
                } else {
                    StarRow(rating: filterStars, maxStars: StarRating.maxStars)
                }
            }
            .frame(width: colWidth, alignment: .leading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(inset)
            .allowsHitTesting(false)

            // Bottom-left — file, capture date, rating (clickable).
            VStack(alignment: .leading, spacing: FlipgradeFont.stackSpacing) {
                if let photo, !fileName.isEmpty {
                    RevealInFinderLink(title: fileName, url: photo.url)
                }
                if !dateText.isEmpty {
                    Text(dateText)
                        .font(FlipgradeFont.ui)
                        .lineSpacing(FlipgradeFont.lineSpacing)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                InteractiveStarRow(
                    rating: rating,
                    maxStars: StarRating.maxStars,
                    onPick: { session.toggleOrSetRating($0) }
                )
            }
            .frame(width: colWidth, alignment: .leading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .padding(inset)

            // Top-right — focused preview loading only.
            VStack {
                HStack {
                    Spacer()
                    if isFocusPreviewLoading {
                        EnhanceQualityBadge()
                    }
                }
                Spacer()
            }
            .padding(inset)
            .allowsHitTesting(false)
        }
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

    private func stage(layout: CoverFlowLayout, stageSize: CGSize) -> some View {
        let fanRunning = fanAnim != nil
        let liftRunning = liftAnim != nil
        let restorePending = session.cullReversed
        let flipRunning = flipAnim != nil
        let clockRunning = liftRunning || fanRunning || restorePending || flipRunning

        return ZStack {
            // Stage outside TimelineView so preview swaps redraw while idle.
            CoverFlowStage(
                flowPosition: displayedFlow,
                photos: session.activePhotos,
                images: previews.viewportImages,
                previewEpoch: previews.viewportRevision &+ session.previewTick,
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
        .frame(width: stageSize.width, height: stageSize.height)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .clipShape(Rectangle())
        .contentShape(Rectangle())
        .gesture(flipDrag)
        .onAppear { clockNow = Date() }
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


            // Tap target under star chrome so star buttons still receive clicks.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    session.toggleFilterRelativeRating()
                }
                .onTapGesture(count: 1) {
                    session.togglePixelZoom()
                }
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

// MARK: - Finder link

private struct RevealInFinderLink: View {
    let title: String
    let url: URL
    @State private var isHovering = false

    var body: some View {
        Text(title)
            .font(FlipgradeFont.ui)
            .lineSpacing(FlipgradeFont.lineSpacing)
            .foregroundStyle(.white)
            .underline(isHovering, color: .white)
            .lineLimit(1)
            .truncationMode(.middle)
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovering = hovering
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
            .onTapGesture {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            .help("Reveal in Finder")
            .accessibilityAddTraits(.isLink)
    }
}

// MARK: - Stars

private struct StarRow: View {
    let rating: Int
    let maxStars: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(1...maxStars, id: \.self) { star in
                Image(systemName: star <= rating ? "star.fill" : "star")
                    .font(.system(size: FlipgradeFont.size, weight: .regular))
                    .foregroundStyle(.white)
            }
        }
        .frame(height: FlipgradeFont.lineHeight, alignment: .center)
    }
}

private struct InteractiveStarRow: View {
    let rating: Int
    let maxStars: Int
    let onPick: (Int) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(1...maxStars, id: \.self) { star in
                Button {
                    onPick(star)
                } label: {
                    Image(systemName: star <= rating ? "star.fill" : "star")
                        .font(.system(size: FlipgradeFont.size, weight: .regular))
                        .foregroundStyle(.white)
                        .frame(width: FlipgradeFont.lineHeight, height: FlipgradeFont.lineHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(star == rating ? "Clear rating" : "Rate \(star)★")
            }
        }
        .frame(height: FlipgradeFont.lineHeight, alignment: .center)
    }
}

/// Capsule bar while the focused preview is decoding (indeterminate — no byte %).
private struct EnhanceQualityBadge: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            // Ease between ~15% and ~85% so it reads as progress without a real meter.
            let pulse = 0.5 + 0.5 * sin(t * 2.2)
            let fill = 0.15 + 0.70 * pulse

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
    /// Header-sized bottom inset reserved under the shared focus fit box.
    let bottomInset: CGFloat
    /// Fit box for the focused image (shared by L2/L3 so midpoints stay aligned).
    let focusMaxWidth: CGFloat
    let focusMaxHeight: CGFloat
    /// Larger fit-box edge — used for lift distance / legacy slot math.
    let centerSlot: CGFloat
    /// Focused card scale (1.0 — slot already is the focus size).
    let focusScale: CGFloat
    /// L2 (first neighbor) relative to focus.
    let layer1Scale: CGFloat
    /// L3 (outer) relative to focus (= layer1²).
    let layer2Scale: CGFloat
    /// Distance from stage center to L2 card center.
    let layer1X: CGFloat
    /// Distance from stage center to L3 card center.
    let layer2X: CGFloat

    /// Window header / titlebar height — used as the focus bottom inset.
    static func headerHeight(safeTop: CGFloat) -> CGFloat {
        if safeTop > 1 { return safeTop }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            let chrome = window.frame.height - window.contentLayoutRect.height
            if chrome > 1 { return chrome }
        }
        return 28
    }

    init(size: CGSize, bottomInset: CGFloat) {
        let inset = max(0, bottomInset)
        let focusScale: CGFloat = 1.0
        let layer1Scale: CGFloat = 0.70
        let layer2Scale: CGFloat = layer1Scale * layer1Scale
        // Top at header baseline; matching bottom inset. L2/L3 use this same box.
        let focusMaxHeight = max(1, size.height - inset)
        let focusMaxWidth = min(max(1, size.width), focusMaxHeight)
        let centerSlot = max(focusMaxWidth, focusMaxHeight)

        // Flat stack: each side card sits 60% under the layer above (40% peek).
        // 50% would put the lower center on the upper outer edge; extra tuck pulls it inward.
        let under: CGFloat = 0.60
        let tuck = under - 0.5
        let focusOuter = focusMaxWidth * focusScale * 0.5
        let layer1X = focusOuter - tuck * focusMaxWidth * layer1Scale
        let layer2Outer = layer1X + focusMaxWidth * layer1Scale * 0.5
        let layer2X = layer2Outer - tuck * focusMaxWidth * layer2Scale

        self.bottomInset = inset
        self.focusMaxWidth = focusMaxWidth
        self.focusMaxHeight = focusMaxHeight
        self.centerSlot = centerSlot
        self.focusScale = focusScale
        self.layer1Scale = layer1Scale
        self.layer2Scale = layer2Scale
        self.layer1X = layer1X
        self.layer2X = layer2X
    }
}

private struct CoverFlowStage: View {
    let flowPosition: CGFloat
    let photos: [PhotoItem]
    let images: [String: NSImage]
    let previewEpoch: UInt64
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
        // Shared fit box is shorter by bottomInset; shift up so top sits on the header
        // baseline and L1/L2/L3 share that midpoint (not the raw stage center).
        .offset(y: -layout.bottomInset / 2)
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

    /// Slot newcomers ease in from — past the edge fade so they don't pop opaque.
    private func fanEntryOffset(for offset: CGFloat) -> CGFloat {
        guard abs(offset) > 0.0001 else { return 0 }
        let sign: CGFloat = offset < 0 ? -1 : 1
        return sign * max(abs(offset) + 0.65, 3.0)
    }

    /// Start pose for fan-in: last slot when reflowing, past fade-edge for newcomers.
    private func fanStartX(offset: CGFloat, fromOffset: CGFloat?) -> CGFloat {
        if let fromOffset {
            return xPosition(offset: fromOffset)
        }
        return xPosition(offset: fanEntryOffset(for: offset))
    }

    /// Width of the focused image inside the fit box (falls back to the slot width).
    private var focusImageWidth: CGFloat {
        let box = CGSize(width: layout.focusMaxWidth, height: layout.focusMaxHeight)
        if let focusID, let image = images[focusID] {
            return fittedSize(for: image, in: box).width
        }
        return layout.focusMaxWidth
    }

    /// Outer→inner location (0…1) where the layer above starts covering this card.
    private func occlusionOverlapLocation(
        offset: CGFloat,
        scale: CGFloat,
        cardWidth: CGFloat
    ) -> CGFloat {
        let half = cardWidth * scale * 0.5
        guard half > 0.5 else { return 0.5 }
        let center = abs(xPosition(offset: offset))
        let absOff = abs(offset)

        // Outer edge of the layer sitting on top of this card (stage coords, focus side).
        let upperOuterEdge: CGFloat
        if absOff <= 1.5 {
            upperOuterEdge = focusImageWidth * layout.focusScale * 0.5
        } else {
            // L2 outer edge ≈ L2 center + L2 half-width (use focus aspect as stand-in).
            let l2Half = focusImageWidth * layout.layer1Scale * 0.5
            upperOuterEdge = layout.layer1X + l2Half
        }

        let outer = center + half
        let inner = center - half
        let span = outer - inner
        guard span > 0.5 else { return 0.5 }
        return min(0.98, max(0.02, (outer - upperOuterEdge) / span))
    }

    private static let focusStroke = Color(red: 0x66 / 255, green: 0x66 / 255, blue: 0x66 / 255)

    /// Occlusion wash: 30% at the outer peek → 90% from the upper-layer edge inward.
    @ViewBuilder
    private func sideOcclusionGradient(
        offset: CGFloat,
        scale: CGFloat,
        cardWidth: CGFloat
    ) -> some View {
        let outerIsLeading = offset < 0
        let stop = occlusionOverlapLocation(offset: offset, scale: scale, cardWidth: cardWidth)
        LinearGradient(
            stops: [
                .init(color: .black.opacity(0.30), location: 0),
                .init(color: .black.opacity(0.90), location: stop),
                .init(color: .black.opacity(0.90), location: 1)
            ],
            startPoint: outerIsLeading ? .leading : .trailing,
            endPoint: outerIsLeading ? .trailing : .leading
        )
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func pinnedFocusCard(photo: PhotoItem, index: Int) -> some View {
        let image = images[photo.id]
        let maxSize = CGSize(width: layout.focusMaxWidth, height: layout.focusMaxHeight)
        let cardSize = fittedSize(for: image, in: maxSize)

        ZStack {
            Rectangle()
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

        }
        .frame(width: cardSize.width, height: cardSize.height)
        .clipShape(Rectangle())
        .overlay {
            Rectangle()
                .stroke(Self.focusStroke, lineWidth: 1)
        }
        .zIndex(120)
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
        let maxSize = CGSize(width: layout.focusMaxWidth, height: layout.focusMaxHeight)

        let finalX = xPosition(offset: offset)
        let fanT = localFanProgress(
            absOffset: a,
            stable: fanStable || (isCenter && fromOffset == nil),
            fromOffset: fromOffset,
            focusHandoff: focusHandoff
        )
        let startX = fanStartX(offset: offset, fromOffset: fromOffset)
        let liveX = startX + (finalX - startX) * fanT
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
        // Flat stack: L0 focus → L2 @ 70% → L3 @ 49%.
        let baseScale: CGFloat = {
            if poseA <= 1 {
                return layout.focusScale + (layout.layer1Scale - layout.focusScale) * poseA
            }
            if poseA <= 2 {
                return layout.layer1Scale + (layout.layer2Scale - layout.layer1Scale) * (poseA - 1)
            }
            return layout.layer2Scale
        }()
        let handoffCenter = focusHandoff && fanT > 0.5
        let scale = baseScale
        // Fit into a pre-scaled box so the card's layout bounds match its visual size —
        // ZStack then centers L2/L3 on the same midpoint as L1 (no scaleEffect drift).
        let fitBox = CGSize(width: maxSize.width * scale, height: maxSize.height * scale)
        let cardSize = fittedSize(for: image, in: fitBox)
        let baseOpacity = edgeOpacity(absOffset: poseA)

        let lift = lifting
            ? liftMotion(baseOpacity: baseOpacity, skipGray: skipGrayLift, reversed: liftReversed)
            : (y: 0, opacity: baseOpacity, gray: false)
        let grayed = lift.gray
        let showSideWash = !isCenter && !lifting && poseA > 0.05

        ZStack {
            // Dark placeholder while Drive/ImageIO hydrate the embedded preview.
            Rectangle()
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

            if showSideWash {
                // Scale is already baked into cardSize.
                sideOcclusionGradient(offset: poseOffset, scale: 1, cardWidth: cardSize.width)
                    .frame(width: cardSize.width, height: cardSize.height)
            }

        }
        .frame(width: cardSize.width, height: cardSize.height)
        .clipShape(Rectangle())
        .overlay {
            if isCenter {
                Rectangle()
                    .stroke(Self.focusStroke, lineWidth: 1)
            }
        }
        .saturation(grayed ? 0.0 : 1.0)
        .brightness(grayed ? -0.12 : 0)
        .opacity(lift.opacity)
        .offset(x: liveX, y: lift.y)
        .zIndex(
            Double(100 - poseA * 10)
                + (isCenter ? 1 : 0)
                + (lifting ? 1 : 0)
                + (handoffCenter ? 0.25 : 0)
                - (focusHandoff && fanT < 0.95 ? 0.5 : 0)
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
