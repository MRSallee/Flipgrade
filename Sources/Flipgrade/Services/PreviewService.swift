import AppKit
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum PreviewPriority: Comparable {
    /// Focused / about-to-be-focused card — decode first.
    case focused
    case normal

    static func < (lhs: PreviewPriority, rhs: PreviewPriority) -> Bool {
        // Lower sort order = sooner. focused < normal.
        switch (lhs, rhs) {
        case (.focused, .normal): return true
        case (.normal, .focused): return false
        default: return false
        }
    }
}

private enum EnhanceTier: Comparable {
    /// CIRAW (or ImageIO) at Cover Flow display size — same look for focus + neighbors.
    case display
    /// Full-resolution demosaic for Space 1:1 / future edit.
    case full

    static func < (lhs: EnhanceTier, rhs: EnhanceTier) -> Bool {
        switch (lhs, rhs) {
        case (.full, .display): return true
        case (.display, .full): return false
        default: return false
        }
    }
}

/// Progressive preview loader for cull + future edit:
/// 1) Embedded JPEG — placeholder only (camera look; outside the develop contract)
/// 2) Display proxy (~2K) via `RAWRender` — same color science as zoom / future export
/// 3) Full-res via `RAWRender` — Space zoom (and later edit/export)
///
/// Demosaiced bitmaps always go through `RAWRender` (Display P3, locked CIRAW settings).
/// Motion pauses viewport paints and demosaic starts; neighbors are idle-gated after settle.
@MainActor
final class PreviewService: ObservableObject {
    static let shared = PreviewService()

    private let embeddedQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.flipgrade.preview.embedded"
        // CloudStorage/Drive stalls hard if we open dozens of ORF files at once.
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .userInitiated
        return queue
    }()
    private let enhanceQueue = DispatchQueue(label: "com.flipgrade.preview.enhance", qos: .utility)

    private var generation: UInt64 = 0
    private var enhanceInFlight: Set<String> = []
    private var embeddedInFlight: Set<String> = []
    /// Queued/running embedded decodes — used to bump priority and cancel stale work.
    private var embeddedOps: [String: BlockOperation] = [:]
    private var embeddedRetryAttempt: [String: Int] = [:]
    private var pendingOrder: [String] = []
    private var pendingJobs: [String: EnhanceJob] = [:]
    private var enhanceBusy = false
    private var focusPhotoID: String?

    /// Camera embedded JPEG — temporary placeholder until the rendered proxy arrives.
    private var embeddedImages: [String: NSImage] = [:]
    private var embeddedOrder: [String] = []
    private let embeddedLimit = 64

    /// CIRAW display proxies (same pipeline/settings for every card).
    private var renderedImages: [String: NSImage] = [:]
    private var renderedOrder: [String] = []
    private let renderedLimit = 48
    private var renderedIDs: Set<String> = []

    /// Full-resolution demosaics for Space zoom.
    private var fullImages: [String: NSImage] = [:]
    private var fullOrder: [String] = []
    private let fullLimit = 8
    private var fullDecodedIDs: Set<String> = []
    /// Native pixel size (full sensor / file), used to lay out 1:1 zoom before full decode finishes.
    private var fullPixelSizes: [String: (width: Int, height: Int)] = [:]

    @Published private(set) var enhancingPhotoIDs: Set<String> = []
    /// Photos whose full-res demosaic was requested and is not ready yet (Space zoom spinner).
    @Published private(set) var loadingFullResolutionIDs: Set<String> = []
    @Published private(set) var viewportImages: [String: NSImage] = [:]
    @Published private(set) var viewportRevision: UInt64 = 0
    /// Bumps when a full-res bitmap arrives so zoom can swap without remounting.
    @Published private(set) var fullResolutionRevision: UInt64 = 0

    private var motionLocked = false
    private var deferredViewportImages: [String: NSImage] = [:]
    private var neighborsArmed = true
    private var neighborArmWorkItem: DispatchWorkItem?
    private let neighborArmDelay: TimeInterval = 0.35

    /// Long-edge cap for Cover Flow / cull previews — light enough to animate, same look everywhere.
    private let displayMaxPixelSize: CGFloat = 2048
    private let embeddedMaxPixelSize: CGFloat = 1600

    private struct EnhanceJob {
        let photo: PhotoItem
        let url: URL
        let current: NSImage?
        let generation: UInt64
        var priority: PreviewPriority
        var tier: EnhanceTier
        /// CIRAW global tone curve at enqueue time (app-wide Base preference).
        let boostAmount: Double
        let completion: (@MainActor (NSImage?) -> Void)?
    }

    init() {}

    /// Best available bitmap (full → rendered → embedded).
    func image(for photo: PhotoItem) -> NSImage? {
        fullImages[photo.id] ?? renderedImages[photo.id] ?? embeddedImages[photo.id]
    }

    /// Cover Flow display bitmap — rendered proxy preferred; embedded only as placeholder.
    func displayImage(for photo: PhotoItem) -> NSImage? {
        renderedImages[photo.id] ?? embeddedImages[photo.id]
    }

    /// Full-res demosaic when available (Space zoom).
    func fullImage(for photo: PhotoItem) -> NSImage? {
        fullImages[photo.id]
    }

    /// Native / full pixel dimensions for 1:1 layout — only from actual demosaic output.
    /// Never use CIRAWFilter.nativeSize here; it can disagree with the rendered bitmap and
    /// cause a proxy→full size jump in Space zoom.
    func fullPixelSize(for photo: PhotoItem) -> (width: Int, height: Int)? {
        if let cached = fullPixelSizes[photo.id] { return cached }
        if let full = fullImages[photo.id] {
            let size = Self.pixelSize(full)
            fullPixelSizes[photo.id] = size
            return size
        }
        return nil
    }

    func isLoadingFullResolution(_ photo: PhotoItem) -> Bool {
        loadingFullResolutionIDs.contains(photo.id)
    }

    func clearViewport() {
        viewportImages = [:]
        deferredViewportImages = [:]
        viewportRevision &+= 1
    }

    /// Call when Cover Flow starts moving — no viewport paints / demosaic starts until `endMotion()`.
    func beginMotion() {
        motionLocked = true
        neighborsArmed = false
        neighborArmWorkItem?.cancel()
        neighborArmWorkItem = nil
        for id in pendingOrder {
            if pendingJobs[id]?.tier == .full, !enhanceInFlight.contains(id) {
                loadingFullResolutionIDs.remove(id)
            }
        }
        // Abandon demosaic backlog immediately — don't replay coasted-past files after settle.
        pendingOrder.removeAll()
        pendingJobs.removeAll()
    }

    /// Resume preview work after the slide settles.
    func endMotion() {
        guard motionLocked else { return }
        motionLocked = false
        // Flush any coalesced first-paints still waiting on the next run-loop turn.
        if !coalescedViewportImages.isEmpty {
            var next = viewportImages
            for (photoID, image) in coalescedViewportImages where next[photoID] == nil {
                next[photoID] = image
            }
            coalescedViewportImages = [:]
            viewportImages = next
            viewportRevision &+= 1
        }
        let pending = deferredViewportImages
        deferredViewportImages = [:]
        for (photoID, image) in pending {
            _ = publishViewportImage(image, for: photoID)
        }
        neighborsArmed = false
        pumpEnhanceQueue()
        scheduleNeighborArm()
    }

    private func scheduleNeighborArm() {
        neighborArmWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, !self.motionLocked else { return }
                self.neighborsArmed = true
                self.pumpEnhanceQueue()
            }
        }
        neighborArmWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + neighborArmDelay, execute: work)
    }

    /// First-paint buffer while motion-locked — flushed once per run-loop turn.
    private var coalescedViewportImages: [String: NSImage] = [:]
    private var viewportFlushScheduled = false

    @discardableResult
    func setViewportImage(_ image: NSImage, for photoID: String, allowDowngrade: Bool = false) -> Bool {
        let newEdge = pixelLongEdge(image)
        if let existing = viewportImages[photoID] {
            let oldEdge = pixelLongEdge(existing)
            if !allowDowngrade, newEdge + 1 < oldEdge { return false }
            if abs(newEdge - oldEdge) < 1, existing === image { return false }
        }
        if motionLocked {
            // First paint must land mid-flip, but coalesce into one @Published hit per
            // run-loop turn — otherwise fast coasts flood MainActor and starve key input
            // (star-layer hops feel dead). Soft→full upgrades still wait for endMotion.
            if viewportImages[photoID] == nil, coalescedViewportImages[photoID] == nil {
                coalescedViewportImages[photoID] = image
                scheduleViewportFlush()
                return true
            }
            deferredViewportImages[photoID] = image
            return false
        }
        deferredViewportImages.removeValue(forKey: photoID)
        coalescedViewportImages.removeValue(forKey: photoID)
        return publishViewportImage(image, for: photoID)
    }

    private func scheduleViewportFlush() {
        guard !viewportFlushScheduled else { return }
        viewportFlushScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.viewportFlushScheduled = false
            let batch = self.coalescedViewportImages
            self.coalescedViewportImages = [:]
            guard !batch.isEmpty else { return }
            var next = self.viewportImages
            for (photoID, image) in batch where next[photoID] == nil {
                next[photoID] = image
            }
            self.viewportImages = next
            self.viewportRevision &+= 1
        }
    }

    @discardableResult
    private func publishViewportImage(_ image: NSImage, for photoID: String) -> Bool {
        var next = viewportImages
        next[photoID] = image
        viewportImages = next
        viewportRevision &+= 1
        return true
    }

    /// Ask for a Cover Flow preview. Queues a **display-sized** CIRAW render (focus first, then neighbors).
    func request(
        _ photo: PhotoItem,
        priority: PreviewPriority = .normal,
        updateViewport: Bool = true,
        completion: (@MainActor (NSImage?) -> Void)? = nil
    ) {
        if priority == .focused {
            focusPhotoID = photo.id
            promotePending(photoID: photo.id)
        }

        let gen = generation
        let url = photo.url
        let id = photo.id

        if let rendered = renderedImages[id] {
            if updateViewport { _ = setViewportImage(rendered, for: id) }
            completion?(rendered)
            return
        }

        if let embedded = embeddedImages[id] {
            if updateViewport { _ = setViewportImage(embedded, for: id) }
            completion?(embedded)
            enqueueEnhance(
                EnhanceJob(
                    photo: photo,
                    url: url,
                    current: embedded,
                    generation: gen,
                    priority: priority,
                    tier: .display,
                    boostAmount: DevelopPrefs.baseBoost,
                    completion: completion
                )
            )
            return
        }

        // Already decoding this file — bump priority so focus isn't stuck behind neighbors.
        if embeddedInFlight.contains(id) {
            if priority == .focused, let op = embeddedOps[id], !op.isFinished {
                op.queuePriority = .veryHigh
            }
            return
        }

        embeddedInFlight.insert(id)
        let op = BlockOperation()
        op.queuePriority = priority == .focused ? .veryHigh : .normal
        op.addExecutionBlock { [weak self, weak op] in
            guard let op, !op.isCancelled else {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.embeddedInFlight.remove(id)
                    self.embeddedOps.removeValue(forKey: id)
                }
                return
            }
            if priority == .focused {
                Thread.current.qualityOfService = .userInitiated
            }
            let started = CFAbsoluteTimeGetCurrent()
            let embedded = Self.decodeBestEmbedded(url: url, maxPixelSize: 1600)
            let ms = (CFAbsoluteTimeGetCurrent() - started) * 1000

            DispatchQueue.main.async {
                guard let self else { return }
                self.embeddedInFlight.remove(id)
                self.embeddedOps.removeValue(forKey: id)
                guard self.generation == gen else { return }
                // Cancelled after start — still keep the bitmap for backtrack, skip viewport chase.
                let cancelled = op.isCancelled

                if let embedded {
                    self.embeddedRetryAttempt.removeValue(forKey: id)
                    self.rememberEmbedded(embedded, id: id)
                    LatencyProbe.shared.recordDecode(
                        ms: ms,
                        fileName: url.lastPathComponent,
                        focused: priority == .focused
                    )
                    if updateViewport, !cancelled {
                        self.setViewportImage(embedded, for: id)
                    }
                    if !cancelled {
                        completion?(embedded)
                    }
                    // Only demosaic after embedded proves the file is locally readable.
                    // CIRAW on a Drive placeholder can hang the process for minutes.
                    // Skip while flipping — otherwise every coasted-past file piles into the
                    // serial enhance queue and settle feels wedged for minutes.
                    if !cancelled, !self.motionLocked {
                        self.enqueueEnhance(
                            EnhanceJob(
                                photo: photo,
                                url: url,
                                current: embedded,
                                generation: gen,
                                priority: priority,
                                tier: .display,
                                boostAmount: DevelopPrefs.baseBoost,
                                completion: nil
                            )
                        )
                    }
                } else if !cancelled {
                    Self.debugLog("embedded miss \(id) — will retry (Drive hydrate?)")
                    let retrying = self.scheduleEmbeddedRetry(
                        photo,
                        priority: priority,
                        updateViewport: updateViewport,
                        generation: gen
                    )
                    if !retrying {
                        completion?(nil)
                    }
                }
            }
        }
        embeddedOps[id] = op
        embeddedQueue.addOperation(op)
    }

    /// Drop queued (not yet running) embeds outside the keep set so forward focus isn't starved.
    private func cancelStaleEmbedded(keeping keepIDs: Set<String>) {
        for (id, op) in embeddedOps {
            guard !keepIDs.contains(id) else { continue }
            guard !op.isExecuting, !op.isFinished else { continue }
            op.cancel()
            embeddedOps.removeValue(forKey: id)
            embeddedInFlight.remove(id)
        }
    }

    /// Drop pending CIRAW jobs outside the keep window (in-flight demosaic runs to completion).
    private func pruneEnhance(keeping keepIDs: Set<String>) {
        guard !pendingOrder.isEmpty else { return }
        pendingOrder.removeAll { id in
            if keepIDs.contains(id) { return false }
            pendingJobs.removeValue(forKey: id)
            return true
        }
    }

    /// Drop every queued demosaic and every non-keep embed so UI (layer hops, settle) isn't starved.
    func cancelNonEssentialWork(keeping keepIDs: Set<String> = []) {
        pendingOrder.removeAll()
        pendingJobs.removeAll()
        for (id, op) in embeddedOps {
            if keepIDs.contains(id) { continue }
            op.cancel()
            if !op.isExecuting {
                embeddedOps.removeValue(forKey: id)
                embeddedInFlight.remove(id)
            }
        }
        // Clear enhance chrome for anything not actually running.
        enhancingPhotoIDs = enhancingPhotoIDs.intersection(enhanceInFlight)
    }

    /// Back off and retry embedded decode while CloudStorage hydrates the file.
    @discardableResult
    private func scheduleEmbeddedRetry(
        _ photo: PhotoItem,
        priority: PreviewPriority,
        updateViewport: Bool,
        generation gen: UInt64
    ) -> Bool {
        let id = photo.id
        let attempt = embeddedRetryAttempt[id, default: 0]
        guard attempt < 10 else {
            Self.debugLog("embedded give up \(id) after \(attempt) tries")
            return false
        }
        embeddedRetryAttempt[id] = attempt + 1
        let delay = min(20.0, 0.4 * pow(1.7, Double(attempt)))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.generation == gen else { return }
            guard self.embeddedImages[id] == nil, self.renderedImages[id] == nil else { return }
            self.request(photo, priority: priority, updateViewport: updateViewport, completion: nil)
        }
        return true
    }

    /// Decode full-resolution demosaic for Space 1:1 (does not push into Cover Flow side cards).
    func requestFullResolution(_ photo: PhotoItem, completion: (@MainActor (NSImage?) -> Void)? = nil) {
        focusPhotoID = photo.id
        promotePending(photoID: photo.id)

        let id = photo.id
        if let full = fullImages[id] {
            loadingFullResolutionIDs.remove(id)
            completion?(full)
            return
        }

        // Need a local embedded/rendered first — full CIRAW on a cold Drive file freezes the app.
        guard renderedImages[id] != nil || embeddedImages[id] != nil else {
            loadingFullResolutionIDs.insert(id)
            request(photo, priority: .focused, updateViewport: true) { [weak self] image in
                guard let self else { return }
                if image != nil
                    || self.embeddedImages[id] != nil
                    || self.renderedImages[id] != nil {
                    self.requestFullResolution(photo, completion: completion)
                } else {
                    self.loadingFullResolutionIDs.remove(id)
                    completion?(nil)
                }
            }
            return
        }

        loadingFullResolutionIDs.insert(id)
        enqueueEnhance(
            EnhanceJob(
                photo: photo,
                url: photo.url,
                current: renderedImages[id] ?? embeddedImages[id],
                generation: generation,
                priority: .focused,
                tier: .full,
                boostAmount: DevelopPrefs.baseBoost,
                completion: completion
            )
        )
    }

    /// Warm nearby embeds/proxies. `aheadBias` > 0 pulls more work forward (fast flip direction);
    /// negative biases backward. Cancels queued embeds outside the window so focus isn't starved.
    func prefetch(around index: Int, in photos: [PhotoItem], radius: Int = 8, aheadBias: Int = 0) {
        guard !photos.isEmpty, photos.indices.contains(index) else { return }
        let ahead = max(1, radius + max(0, aheadBias))
        let behind = max(1, radius + max(0, -aheadBias) - max(0, aheadBias))
        var keepIDs = Set<String>()

        request(photos[index], priority: .focused, updateViewport: true, completion: nil)
        keepIDs.insert(photos[index].id)

        // Prefer the scroll-ahead side first so the 2-wide embed queue fills forward.
        // Keep PreviewPriority.focused on the real center only (don't steal focusPhotoID).
        for distance in 1...ahead {
            let i = index + distance
            guard photos.indices.contains(i) else { continue }
            let id = photos[i].id
            keepIDs.insert(id)
            request(photos[i], priority: .normal, updateViewport: true, completion: nil)
            if distance <= 4, let op = embeddedOps[id], !op.isFinished {
                op.queuePriority = .high
            }
        }
        for distance in 1...behind {
            let i = index - distance
            guard photos.indices.contains(i) else { continue }
            keepIDs.insert(photos[i].id)
            request(photos[i], priority: .normal, updateViewport: true, completion: nil)
            if let op = embeddedOps[photos[i].id], !op.isFinished, op.queuePriority == .normal {
                op.queuePriority = .low
            }
        }

        cancelStaleEmbedded(keeping: keepIDs)
        pruneEnhance(keeping: keepIDs)
    }

    func invalidate() {
        generation &+= 1
        embeddedQueue.cancelAllOperations()
        embeddedOps.removeAll()
        enhanceInFlight.removeAll()
        embeddedInFlight.removeAll()
        embeddedRetryAttempt.removeAll()
        pendingOrder.removeAll()
        pendingJobs.removeAll()
        enhanceBusy = false
        focusPhotoID = nil
        enhancingPhotoIDs.removeAll()
        embeddedImages = [:]
        embeddedOrder = []
        renderedImages = [:]
        renderedOrder = []
        renderedIDs.removeAll()
        fullImages = [:]
        fullOrder = []
        fullDecodedIDs.removeAll()
        fullPixelSizes.removeAll()
        loadingFullResolutionIDs.removeAll()
        fullResolutionRevision = 0
        deferredViewportImages = [:]
        coalescedViewportImages = [:]
        viewportFlushScheduled = false
        motionLocked = false
        neighborsArmed = true
        neighborArmWorkItem?.cancel()
        neighborArmWorkItem = nil
        clearViewport()
    }

    // MARK: - Enhance priority queue

    private func enqueueEnhance(_ job: EnhanceJob) {
        let id = job.photo.id
        // Mid-flip: don't stockpile display demosaics for photos already behind us.
        if motionLocked, job.tier == .display { return }
        if job.tier == .display, renderedIDs.contains(id) { return }
        if job.tier == .full, fullDecodedIDs.contains(id) {
            if fullImages[id] != nil {
                loadingFullResolutionIDs.remove(id)
            }
            return
        }
        guard !enhanceInFlight.contains(id) else {
            // If a display job is flying and we need full, queue full to follow.
            if job.tier == .full, pendingJobs[id] == nil {
                pendingJobs[id] = job
                pendingOrder.insert(id, at: 0)
            }
            return
        }

        if let existing = pendingJobs[id] {
            let priority = min(job.priority, existing.priority)
            let tier = min(job.tier, existing.tier)
            pendingJobs[id] = EnhanceJob(
                photo: job.photo,
                url: job.url,
                current: job.current ?? existing.current,
                generation: job.generation,
                priority: priority,
                tier: tier,
                boostAmount: job.boostAmount,
                completion: job.completion ?? existing.completion
            )
            if priority == .focused || tier == .full {
                promotePending(photoID: id)
            }
        } else {
            pendingJobs[id] = job
            if job.priority == .focused || id == focusPhotoID || job.tier == .full {
                pendingOrder.insert(id, at: 0)
            } else {
                pendingOrder.append(id)
            }
        }
        pumpEnhanceQueue()
    }

    private func promotePending(photoID: String) {
        guard let idx = pendingOrder.firstIndex(of: photoID), idx > 0 else { return }
        pendingOrder.remove(at: idx)
        pendingOrder.insert(photoID, at: 0)
        if var job = pendingJobs[photoID] {
            job.priority = .focused
            pendingJobs[photoID] = job
        }
    }

    private func isFocusJob(_ job: EnhanceJob, id: String) -> Bool {
        job.priority == .focused || id == focusPhotoID || job.tier == .full
    }

    private func pumpEnhanceQueue() {
        guard !enhanceBusy, !motionLocked else { return }
        if let focusPhotoID,
           let focusIdx = pendingOrder.firstIndex(of: focusPhotoID),
           focusIdx > 0 {
            pendingOrder.remove(at: focusIdx)
            pendingOrder.insert(focusPhotoID, at: 0)
        }
        guard let id = pendingOrder.first, let job = pendingJobs[id] else { return }

        if !isFocusJob(job, id: id), !neighborsArmed {
            return
        }

        pendingJobs.removeValue(forKey: id)
        pendingOrder.removeFirst()

        if job.tier == .display, renderedIDs.contains(id) {
            pumpEnhanceQueue()
            return
        }
        if job.tier == .full, fullDecodedIDs.contains(id) {
            if fullImages[id] != nil {
                loadingFullResolutionIDs.remove(id)
            }
            pumpEnhanceQueue()
            return
        }

        enhanceBusy = true
        enhanceInFlight.insert(id)
        if !motionLocked {
            enhancingPhotoIDs.insert(id)
        }
        let maxPixel: CGFloat? = job.tier == .display ? displayMaxPixelSize : nil
        Self.debugLog(
            "enhance start \(id) tier=\(job.tier) priority=\(job.priority) max=\(maxPixel.map { Int($0) } ?? -1)"
        )

        let gen = job.generation
        enhanceQueue.async { [weak self] in
            let started = CFAbsoluteTimeGetCurrent()
            let result = RAWRender.demosaicResult(
                url: job.url,
                maxPixelSize: maxPixel,
                boostAmount: job.boostAmount
            )
            let ms = (CFAbsoluteTimeGetCurrent() - started) * 1000

            Task { @MainActor in
                guard let self else { return }
                self.enhanceInFlight.remove(id)
                self.enhanceBusy = false

                guard self.generation == gen else {
                    self.enhancingPhotoIDs.remove(id)
                    if job.tier == .full {
                        self.loadingFullResolutionIDs.remove(id)
                    }
                    self.pumpEnhanceQueue()
                    return
                }

                guard let result else {
                    Self.debugLog("enhance failed \(id) tier=\(job.tier)")
                    if job.tier == .display {
                        self.renderedIDs.insert(id)
                    } else {
                        self.fullDecodedIDs.insert(id)
                        self.loadingFullResolutionIDs.remove(id)
                    }
                    self.enhancingPhotoIDs.remove(id)
                    job.completion?(nil)
                    self.pumpEnhanceQueue()
                    return
                }

                let upgraded = result.image
                // Always cache the true full-res pixel size from this demosaic (extent/scale).
                // Avoid CIRAWFilter.nativeSize — it can disagree with the rendered bitmap and
                // cause a 2-step size jump when Space zoom swaps proxy → full.
                let sizeChanged = self.fullPixelSizes[id].map {
                    $0.width != result.fullWidth || $0.height != result.fullHeight
                } ?? true
                self.fullPixelSizes[id] = (result.fullWidth, result.fullHeight)
                if sizeChanged {
                    self.fullResolutionRevision &+= 1
                }

                let currentEdge = job.current.map { self.pixelLongEdge($0) } ?? 0
                let upgradedEdge = self.pixelLongEdge(upgraded)
                if job.tier == .display, currentEdge >= upgradedEdge, self.renderedImages[id] != nil {
                    Self.debugLog("enhance discard \(id) current=\(Int(currentEdge)) upgraded=\(Int(upgradedEdge))")
                    self.renderedIDs.insert(id)
                    self.enhancingPhotoIDs.remove(id)
                    self.pumpEnhanceQueue()
                    return
                }

                LatencyProbe.shared.recordDecode(
                    ms: ms,
                    fileName: job.url.lastPathComponent,
                    focused: job.priority == .focused || id == self.focusPhotoID
                )

                let applied: Bool
                if job.tier == .full {
                    self.rememberFull(upgraded, id: id)
                    self.fullDecodedIDs.insert(id)
                    self.loadingFullResolutionIDs.remove(id)
                    self.fullResolutionRevision &+= 1
                    // Keep Cover Flow on the display proxy; zoom reads fullImages directly.
                    applied = false
                } else {
                    self.rememberRendered(upgraded, id: id)
                    self.renderedIDs.insert(id)
                    // Same rendered look for focus and neighbors (motion may defer the paint).
                    applied = self.setViewportImage(upgraded, for: id)
                }

                self.enhancingPhotoIDs.remove(id)
                Self.debugLog(
                    "enhance apply \(id) tier=\(job.tier) \(Int(currentEdge))→\(Int(upgradedEdge)) full=\(result.fullWidth)x\(result.fullHeight) viewport=\(applied) rev=\(self.viewportRevision)"
                )
                job.completion?(upgraded)
                self.pumpEnhanceQueue()
            }
        }
    }

    private func rememberEmbedded(_ image: NSImage, id: String) {
        if embeddedImages[id] == nil { embeddedOrder.append(id) }
        embeddedImages[id] = image
        trim(&embeddedOrder, limit: embeddedLimit, store: &embeddedImages)
    }

    private func rememberRendered(_ image: NSImage, id: String) {
        if renderedImages[id] == nil { renderedOrder.append(id) }
        renderedImages[id] = image
        trim(&renderedOrder, limit: renderedLimit, store: &renderedImages)
        if let focusPhotoID, renderedImages[focusPhotoID] != nil {
            renderedOrder.removeAll { $0 == focusPhotoID }
            renderedOrder.append(focusPhotoID)
        }
    }

    private func rememberFull(_ image: NSImage, id: String) {
        if fullImages[id] == nil { fullOrder.append(id) }
        fullImages[id] = image
        fullPixelSizes[id] = Self.pixelSize(image)
        trim(&fullOrder, limit: fullLimit, store: &fullImages)
        if let focusPhotoID, fullImages[focusPhotoID] != nil {
            fullOrder.removeAll { $0 == focusPhotoID }
            fullOrder.append(focusPhotoID)
        }
    }

    private func trim(_ order: inout [String], limit: Int, store: inout [String: NSImage]) {
        while order.count > limit {
            let evicted = order.removeFirst()
            if evicted != focusPhotoID {
                store.removeValue(forKey: evicted)
            } else {
                order.append(evicted)
                break
            }
        }
    }

    private func pixelLongEdge(_ image: NSImage) -> CGFloat {
        Self.pixelLongEdge(image)
    }

    nonisolated static func pixelLongEdge(_ image: NSImage) -> CGFloat {
        let size = pixelSize(image)
        return CGFloat(max(size.width, size.height))
    }

    nonisolated static func pixelSize(_ image: NSImage) -> (width: Int, height: Int) {
        var bestW = 0
        var bestH = 0
        for rep in image.representations {
            let w: Int
            let h: Int
            if let bitmap = rep as? NSBitmapImageRep {
                w = bitmap.pixelsWide
                h = bitmap.pixelsHigh
            } else {
                w = Int(rep.pixelsWide)
                h = Int(rep.pixelsHigh)
            }
            if w * h > bestW * bestH {
                bestW = w
                bestH = h
            }
        }
        if bestW > 0, bestH > 0 { return (bestW, bestH) }
        return (max(1, Int(image.size.width)), max(1, Int(image.size.height)))
    }

    nonisolated private static func debugLog(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Flipgrade/launch.log")
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    nonisolated private static func nsImage(from cg: CGImage) -> NSImage {
        let rep = NSBitmapImageRep(cgImage: cg)
        let image = NSImage(size: NSSize(width: rep.pixelsWide, height: rep.pixelsHigh))
        image.addRepresentation(rep)
        return image
    }

    nonisolated static func decodeBestEmbeddedPublic(url: URL, maxPixelSize: CGFloat) -> NSImage? {
        decodeBestEmbedded(url: url, maxPixelSize: maxPixelSize)
    }

    nonisolated private static func decodeBestEmbedded(url: URL, maxPixelSize: CGFloat) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let count = max(CGImageSourceGetCount(source), 1)
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        var best: CGImage?
        var bestEdge = 0
        for index in 0..<count {
            guard let cg = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else { continue }
            let edge = max(cg.width, cg.height)
            if edge > bestEdge {
                best = cg
                bestEdge = edge
            }
        }
        guard let best else { return nil }
        return nsImage(from: best)
    }

    /// Fast metadata read of the file's native pixel size (no demosaic).
    nonisolated static func readNativePixelSize(url: URL) -> (width: Int, height: Int)? {
        // Prefer a cheap display demosaic size prediction only when needed elsewhere.
        // Zoom layout must use sizes from RAWRenderResult, not filter.nativeSize.
        if let filter = CIRAWFilter(imageURL: url) {
            let native = filter.nativeSize
            let width = Int(native.width.rounded())
            let height = Int(native.height.rounded())
            if width > 1, height > 1 { return (width, height) }
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }
        let width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue
            ?? (props[kCGImagePropertyPixelWidth] as? Int)
        let height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
            ?? (props[kCGImagePropertyPixelHeight] as? Int)
        guard let width, let height, width > 1, height > 1 else { return nil }
        return (width, height)
    }
}

@MainActor
final class LatencyProbe: ObservableObject {
    static let shared = LatencyProbe()

    @Published private(set) var lastFlipMS: Double = 0
    @Published private(set) var lastDecodeMS: Double = 0
    @Published private(set) var lastFile: String = "—"
    @Published private(set) var avgDecodeMS: Double = 0

    private var decodeSamples: [Double] = []
    private var flipStarted: CFAbsoluteTime?

    func beginFlip() {
        flipStarted = CFAbsoluteTimeGetCurrent()
    }

    func endFlip() {
        guard let flipStarted else { return }
        lastFlipMS = (CFAbsoluteTimeGetCurrent() - flipStarted) * 1000
        self.flipStarted = nil
    }

    func recordDecode(ms: Double, fileName: String, focused: Bool) {
        guard focused else { return }
        lastDecodeMS = ms
        lastFile = fileName
        decodeSamples.append(ms)
        if decodeSamples.count > 40 { decodeSamples.removeFirst() }
        avgDecodeMS = decodeSamples.reduce(0, +) / Double(decodeSamples.count)
    }
}
