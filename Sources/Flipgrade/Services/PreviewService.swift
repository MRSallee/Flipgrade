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

/// Progressive preview loader — one full-res asset per photo:
/// 1) Embedded JPEG (fast) → viewport + cache
/// 2) Native CIRAW / ImageIO demosaic (serial queue; focused photo first) → cache + viewport
@MainActor
final class PreviewService: ObservableObject {
    static let shared = PreviewService()

    private let cache = NSCache<NSString, NSImage>()
    private let quickQueue = DispatchQueue(label: "com.flipgrade.preview.quick", qos: .userInitiated, attributes: .concurrent)
    private let enhanceQueue = DispatchQueue(label: "com.flipgrade.preview.enhance", qos: .utility)

    private var generation: UInt64 = 0
    private var fullyDecodedIDs: Set<String> = []
    private var enhanceInFlight: Set<String> = []
    private var pendingOrder: [String] = []
    private var pendingJobs: [String: EnhanceJob] = [:]
    private var enhanceBusy = false
    private var focusPhotoID: String?
    /// Strong refs for native demosaics so Space 1:1 isn't stuck on a tiny embedded proxy
    /// when NSCache evicts under pressure.
    private var nativeImages: [String: NSImage] = [:]
    private var nativeOrder: [String] = []
    private let nativeLimit = 24

    @Published private(set) var enhancingPhotoIDs: Set<String> = []
    @Published private(set) var viewportImages: [String: NSImage] = [:]
    @Published private(set) var viewportRevision: UInt64 = 0

    private let embeddedMaxPixelSize: CGFloat = 1600

    private struct EnhanceJob {
        let photo: PhotoItem
        let url: URL
        let current: NSImage?
        let generation: UInt64
        var priority: PreviewPriority
        let completion: (@MainActor (NSImage?) -> Void)?
    }

    init() {
        cache.countLimit = 24
        cache.totalCostLimit = 1024 * 1024 * 1024
    }

    func image(for photo: PhotoItem) -> NSImage? {
        nativeImages[photo.id] ?? cache.object(forKey: photo.id as NSString)
    }

    func clearViewport() {
        viewportImages = [:]
        viewportRevision &+= 1
    }

    @discardableResult
    func setViewportImage(_ image: NSImage, for photoID: String) -> Bool {
        let newEdge = pixelLongEdge(image)
        if let existing = viewportImages[photoID] {
            let oldEdge = pixelLongEdge(existing)
            if newEdge + 1 < oldEdge { return false }
            if abs(newEdge - oldEdge) < 1, existing === image { return false }
        }
        return publishViewportImage(image, for: photoID)
    }

    @discardableResult
    private func publishViewportImage(_ image: NSImage, for photoID: String) -> Bool {
        var next = viewportImages
        next[photoID] = image
        viewportImages = next
        viewportRevision &+= 1
        return true
    }

    /// Ask for a preview. Same full-res pipeline for every photo; `priority` only affects decode order.
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

        if let cached = nativeImages[id] ?? cache.object(forKey: id as NSString) {
            if updateViewport {
                _ = setViewportImage(cached, for: id)
            }
            completion?(cached)
            // Recover if NSCache/native was lost after we marked fully decoded.
            if nativeImages[id] == nil, fullyDecodedIDs.contains(id),
               pixelLongEdge(cached) <= embeddedMaxPixelSize + 50 {
                fullyDecodedIDs.remove(id)
            }
            if nativeImages[id] == nil, !fullyDecodedIDs.contains(id) {
                enqueueEnhance(
                    EnhanceJob(
                        photo: photo,
                        url: url,
                        current: cached,
                        generation: gen,
                        priority: priority,
                        completion: completion
                    )
                )
            }
            return
        }

        quickQueue.async { [weak self] in
            let started = CFAbsoluteTimeGetCurrent()
            let embedded = Self.decodeBestEmbedded(url: url, maxPixelSize: 1600)
            let ms = (CFAbsoluteTimeGetCurrent() - started) * 1000

            Task { @MainActor in
                guard let self, self.generation == gen else { return }

                if let embedded {
                    self.storeCache(embedded, id: id)
                    LatencyProbe.shared.recordDecode(ms: ms, fileName: url.lastPathComponent, focused: priority == .focused)
                    if updateViewport { self.setViewportImage(embedded, for: id) }
                    completion?(embedded)
                    self.enqueueEnhance(
                        EnhanceJob(
                            photo: photo,
                            url: url,
                            current: embedded,
                            generation: gen,
                            priority: priority,
                            completion: completion
                        )
                    )
                } else {
                    self.enqueueEnhance(
                        EnhanceJob(
                            photo: photo,
                            url: url,
                            current: nil,
                            generation: gen,
                            priority: priority,
                            completion: completion
                        )
                    )
                }
            }
        }
    }

    /// Warm nearby previews into the viewport so the next flip already has bitmaps.
    func prefetch(around index: Int, in photos: [PhotoItem], radius: Int = 8) {
        guard !photos.isEmpty, photos.indices.contains(index) else { return }
        request(photos[index], priority: .focused, updateViewport: true, completion: nil)
        for distance in 1...radius {
            for i in [index - distance, index + distance] where photos.indices.contains(i) {
                request(photos[i], priority: .normal, updateViewport: true, completion: nil)
            }
        }
    }

    func invalidate() {
        generation &+= 1
        cache.removeAllObjects()
        fullyDecodedIDs.removeAll()
        enhanceInFlight.removeAll()
        pendingOrder.removeAll()
        pendingJobs.removeAll()
        enhanceBusy = false
        focusPhotoID = nil
        enhancingPhotoIDs.removeAll()
        nativeImages = [:]
        nativeOrder = []
        clearViewport()
    }

    // MARK: - Enhance priority queue

    private func enqueueEnhance(_ job: EnhanceJob) {
        let id = job.photo.id
        guard !fullyDecodedIDs.contains(id), !enhanceInFlight.contains(id) else { return }

        if var existing = pendingJobs[id] {
            // Keep the highest priority / freshest completion.
            if job.priority < existing.priority { existing.priority = job.priority }
            pendingJobs[id] = EnhanceJob(
                photo: job.photo,
                url: job.url,
                current: job.current ?? existing.current,
                generation: job.generation,
                priority: existing.priority,
                completion: job.completion ?? existing.completion
            )
            promotePending(photoID: id)
        } else {
            pendingJobs[id] = job
            if job.priority == .focused || id == focusPhotoID {
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

    private func pumpEnhanceQueue() {
        guard !enhanceBusy else { return }
        // Always prefer current focus if it's waiting.
        if let focusPhotoID,
           let focusIdx = pendingOrder.firstIndex(of: focusPhotoID),
           focusIdx > 0 {
            pendingOrder.remove(at: focusIdx)
            pendingOrder.insert(focusPhotoID, at: 0)
        }
        guard let id = pendingOrder.first, let job = pendingJobs.removeValue(forKey: id) else { return }
        pendingOrder.removeFirst()

        enhanceBusy = true
        enhanceInFlight.insert(id)
        enhancingPhotoIDs.insert(id)
        Self.debugLog("enhance start \(id) priority=\(job.priority) current=\(Int(job.current.map(pixelLongEdge) ?? 0))")

        let gen = job.generation
        enhanceQueue.async { [weak self] in
            let started = CFAbsoluteTimeGetCurrent()
            let upgraded = Self.decodeEnhanced(url: job.url, maxPixelSize: nil)
            let ms = (CFAbsoluteTimeGetCurrent() - started) * 1000

            Task { @MainActor in
                guard let self else { return }
                self.enhanceInFlight.remove(id)
                self.enhanceBusy = false

                guard self.generation == gen else {
                    self.enhancingPhotoIDs.remove(id)
                    self.pumpEnhanceQueue()
                    return
                }

                guard let upgraded else {
                    Self.debugLog("enhance failed \(id)")
                    self.fullyDecodedIDs.insert(id)
                    self.enhancingPhotoIDs.remove(id)
                    job.completion?(nil)
                    self.pumpEnhanceQueue()
                    return
                }

                let currentEdge = job.current.map { self.pixelLongEdge($0) } ?? 0
                let upgradedEdge = self.pixelLongEdge(upgraded)
                if currentEdge >= upgradedEdge {
                    Self.debugLog("enhance discard \(id) current=\(Int(currentEdge)) upgraded=\(Int(upgradedEdge))")
                    self.fullyDecodedIDs.insert(id)
                    self.enhancingPhotoIDs.remove(id)
                    self.pumpEnhanceQueue()
                    return
                }

                self.storeCache(upgraded, id: id)
                self.rememberNative(upgraded, id: id)
                self.fullyDecodedIDs.insert(id)
                LatencyProbe.shared.recordDecode(
                    ms: ms,
                    fileName: job.url.lastPathComponent,
                    focused: job.priority == .focused
                )
                let applied = self.setViewportImage(upgraded, for: id)
                self.enhancingPhotoIDs.remove(id)
                Self.debugLog(
                    "enhance apply \(id) \(Int(currentEdge))→\(Int(upgradedEdge)) viewport=\(applied) focus=\(id == self.focusPhotoID) rev=\(self.viewportRevision)"
                )
                job.completion?(upgraded)
                self.pumpEnhanceQueue()
            }
        }
    }

    private func storeCache(_ image: NSImage, id: String) {
        let size = Self.pixelSize(image)
        let cost = max(1, size.width * size.height * 4)
        cache.setObject(image, forKey: id as NSString, cost: cost)
    }

    private func rememberNative(_ image: NSImage, id: String) {
        if nativeImages[id] == nil {
            nativeOrder.append(id)
        }
        nativeImages[id] = image
        while nativeOrder.count > nativeLimit {
            let evicted = nativeOrder.removeFirst()
            if evicted != focusPhotoID {
                nativeImages.removeValue(forKey: evicted)
                fullyDecodedIDs.remove(evicted)
            } else {
                nativeOrder.append(evicted)
                break
            }
        }
        // Keep focus pinned at end so it survives trim.
        if let focusPhotoID, nativeImages[focusPhotoID] != nil {
            nativeOrder.removeAll { $0 == focusPhotoID }
            nativeOrder.append(focusPhotoID)
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

    nonisolated private static func decodeEnhanced(url: URL, maxPixelSize: CGFloat?) -> NSImage? {
        if let raw = decodeUsingRAWFilter(url: url, maxPixelSize: maxPixelSize) {
            return raw
        }
        return decodeUsingImageIOFull(url: url, maxPixelSize: maxPixelSize)
    }

    nonisolated private static func decodeUsingRAWFilter(url: URL, maxPixelSize: CGFloat?) -> NSImage? {
        guard let filter = CIRAWFilter(imageURL: url) else { return nil }
        let native = filter.nativeSize
        let longEdge = max(native.width, native.height)
        guard longEdge > 1 else { return nil }
        if let maxPixelSize, longEdge > maxPixelSize {
            filter.scaleFactor = Float(maxPixelSize / longEdge)
        } else {
            filter.scaleFactor = 1
        }
        filter.isDraftModeEnabled = false
        guard let ciImage = filter.outputImage else { return nil }
        let rect = ciImage.extent.integral
        let context = CIContext(options: [.useSoftwareRenderer: false, .cacheIntermediates: false])
        guard let cg = context.createCGImage(ciImage, from: rect) else { return nil }
        return nsImage(from: cg)
    }

    nonisolated private static func decodeUsingImageIOFull(url: URL, maxPixelSize: CGFloat?) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceShouldAllowFloat: true
        ]
        if let maxPixelSize {
            options[kCGImageSourceThumbnailMaxPixelSize] = maxPixelSize
        }
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return nsImage(from: cg)
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
