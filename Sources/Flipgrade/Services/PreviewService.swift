import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Progressive preview loader: prefer embedded thumbnails, avoid full RAW demosaic while culling.
@MainActor
final class PreviewService: ObservableObject {
    static let shared = PreviewService()

    private let cache = NSCache<NSString, NSImage>()
    private let queue = DispatchQueue(label: "com.flipgrade.preview", qos: .userInitiated, attributes: .concurrent)
    private var generation: UInt64 = 0

    private let centerMaxPixelSize: CGFloat = 2400
    private let neighborMaxPixelSize: CGFloat = 720

    init() {
        cache.countLimit = 80
    }

    func image(for photo: PhotoItem, neighbor: Bool = false) -> NSImage? {
        let key = cacheKey(photo, neighbor: neighbor)
        return cache.object(forKey: key as NSString)
    }

    func request(_ photo: PhotoItem, neighbor: Bool = false, completion: (@MainActor (NSImage?) -> Void)? = nil) {
        let key = cacheKey(photo, neighbor: neighbor)
        if let cached = cache.object(forKey: key as NSString) {
            completion?(cached)
            return
        }

        let maxSize = neighbor ? neighborMaxPixelSize : centerMaxPixelSize
        let url = photo.url
        let gen = generation

        queue.async { [weak self] in
            let started = CFAbsoluteTimeGetCurrent()
            let image = Self.decodePreview(url: url, maxPixelSize: maxSize)
            let ms = (CFAbsoluteTimeGetCurrent() - started) * 1000

            Task { @MainActor in
                guard let self, self.generation == gen else { return }
                if let image {
                    self.cache.setObject(image, forKey: key as NSString)
                }
                LatencyProbe.shared.recordDecode(ms: ms, fileName: url.lastPathComponent, neighbor: neighbor)
                completion?(image)
            }
        }
    }

    func prefetch(around index: Int, in photos: [PhotoItem], radius: Int = 8) {
        guard !photos.isEmpty else { return }
        let start = max(0, index - radius)
        let end = min(photos.count - 1, index + radius)
        for i in start...end {
            let neighbor = i != index
            request(photos[i], neighbor: neighbor)
        }
    }

    func invalidate() {
        generation &+= 1
        cache.removeAllObjects()
    }

    private func cacheKey(_ photo: PhotoItem, neighbor: Bool) -> String {
        "\(photo.id)#\(neighbor ? "n" : "c")"
    }

    /// Prefer embedded JPEG/thumbnail. Only fall back to a downscaled decode if needed.
    nonisolated private static func decodePreview(url: URL, maxPixelSize: CGFloat) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }

        // 1) Embedded / existing thumbnail path (no forced full-image decode)
        let embeddedOptions: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        if let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, embeddedOptions as CFDictionary) {
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }

        // 2) Fallback: create thumbnail from image if absent (may demosaic — last resort)
        let fallbackOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        if let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, fallbackOptions as CFDictionary) {
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }
        return nil
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

    func recordDecode(ms: Double, fileName: String, neighbor: Bool) {
        guard !neighbor else { return }
        lastDecodeMS = ms
        lastFile = fileName
        decodeSamples.append(ms)
        if decodeSamples.count > 40 { decodeSamples.removeFirst() }
        avgDecodeMS = decodeSamples.reduce(0, +) / Double(decodeSamples.count)
    }
}
