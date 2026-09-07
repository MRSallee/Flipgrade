import AppKit
import Foundation
import SwiftUI

struct StarFlash: Equatable {
    enum Kind: Equatable {
        case rating(Int)
        case layer(RatingLayer)
    }

    let kind: Kind
    let id: UUID

    static func rating(_ stars: Int) -> StarFlash {
        StarFlash(kind: .rating(stars), id: UUID())
    }

    static func layer(_ layer: RatingLayer) -> StarFlash {
        StarFlash(kind: .layer(layer), id: UUID())
    }
}

struct DepartingCard: Identifiable, Equatable {
    let id: String
    let photo: PhotoItem
    /// Offset from focus at the moment of departure/arrival (frozen for the lift).
    let offset: CGFloat
    /// Already grayed with the pack — slide/fade only (used for deferred center discard).
    let skipGray: Bool
}

@MainActor
final class FlipSession: ObservableObject {
    @Published var folderURL: URL?
    @Published var photos: [PhotoItem] = []
    @Published private(set) var activePhotos: [PhotoItem] = []
    @Published var selectionIndex: Int = 0
    @Published var ratingLayer: RatingLayer = .all
    @Published private(set) var liftingIDs: Set<String> = []
    /// Cards still drawn while lifting out (removed from `activePhotos` already).
    @Published private(set) var departingCards: [DepartingCard] = []
    /// Returners dropping in on restore (also in `activePhotos`, but drawn via this overlay).
    @Published private(set) var arrivingCards: [DepartingCard] = []
    /// True while playing the expand (layer-up) sequence: reverse fan, then reverse lift.
    @Published private(set) var cullReversed: Bool = false
    @Published private(set) var starFlash: StarFlash?
    /// Photo IDs that keep their Cover Flow slot across a cull — no fan-in.
    @Published private(set) var fanStableIDs: Set<String> = []
    /// Survivors that change slot: animate from this prior offset (not from off-screen).
    @Published private(set) var fanFromOffsets: [String: CGFloat] = [:]
    /// True while survivors should hold start poses (during lift, before L1/L2 fan).
    @Published private(set) var fanArmed: Bool = false
    /// Bumped when L1/L2 fan-in should start.
    @Published private(set) var fanInToken: UInt = 0
    @Published var statusMessage: String = "Open a folder of photos to start culling."
    @Published var isLoading = false
    /// Spacebar 1:1 pixel zoom with mouse-linked pan.
    @Published var isPixelZoom = false

    let ratingStore = RatingStore()
    let previews = PreviewService.shared
    let latency = LatencyProbe.shared

    private var liftTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    /// Gray hold + slide + fade-at-top for leavers / reverse drop-in.
    private let liftDuration: Duration = .milliseconds(240)
    /// L1 then L2 (or reverse L2 then L1).
    private let fanDuration: Duration = .milliseconds(180)

    var currentPhoto: PhotoItem? {
        guard activePhotos.indices.contains(selectionIndex) else { return nil }
        return activePhotos[selectionIndex]
    }

    /// True while a former focus is flying out from screen center — keep camera there.
    var isDepartingFromCenter: Bool {
        departingCards.contains { abs($0.offset) < 0.5 }
    }

    var isCullBusy: Bool {
        !liftingIDs.isEmpty || !arrivingCards.isEmpty || cullReversed
    }

    func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Open"
        panel.message = "Choose a folder of RAW/JPEG photos to cull."

        // Prefer the baked Zion folder itself so Open is one click when possible.
        if let baked = RepoPaths.defaultFolderPath {
            panel.directoryURL = URL(fileURLWithPath: baked, isDirectory: true)
        } else if let saved = UserDefaults.standard.string(forKey: Self.lastFolderPathKey), !saved.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: saved, isDirectory: true)
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }
        Self.saveFolderAccess(url)
        loadFolder(url)
    }

    /// Launch restore. CloudStorage paths often hang without a user-granted Open Panel bookmark.
    func restoreFolderIfPossible() {
        guard photos.isEmpty, !isLoading else { return }
        isLoading = true
        statusMessage = "Looking for photos…"

        loadTask?.cancel()
        let bookmarkData = UserDefaults.standard.data(forKey: Self.folderBookmarkKey)
        let savedPath = UserDefaults.standard.string(forKey: Self.lastFolderPathKey)
        let bakedPath = RepoPaths.defaultFolderPath

        let diskLoad = Task.detached(priority: .userInitiated) {
            Self.syncLoadFirstAvailableFolder(
                bookmarkData: bookmarkData,
                savedPath: savedPath,
                bakedPath: bakedPath
            )
        }

        loadTask = Task { @MainActor in
            defer {
                if Task.isCancelled, self.photos.isEmpty, self.isLoading {
                    self.isLoading = false
                    self.statusMessage = "Open a folder of photos to start culling."
                }
            }

            let outcome = await Self.race(diskLoad, timeoutSeconds: bookmarkData == nil ? 2 : 10)
            guard !Task.isCancelled else { return }
            self.applyOutcome(outcome)

            if case .notFound = outcome {
                // Don't block on a hung listing — if Drive responds later, take it.
                Task { @MainActor in
                    let late = await diskLoad.value
                    guard self.photos.isEmpty else { return }
                    if case .loaded = late {
                        self.applyOutcome(late)
                    }
                }
                // Do not auto-present Open Panel — that was added during the launch hang
                // debugging and feels like a "permission regression" on every rebuild.
            }
        }
    }

    /// Nonisolated so the timeout/load waiters are not stuck behind MainActor.
    nonisolated private static func race(
        _ load: Task<FolderLoadOutcome, Never>,
        timeoutSeconds: Double
    ) async -> FolderLoadOutcome {
        await withCheckedContinuation { continuation in
            final class Once: @unchecked Sendable {
                let lock = NSLock()
                var resumed = false
                let continuation: CheckedContinuation<FolderLoadOutcome, Never>
                init(_ continuation: CheckedContinuation<FolderLoadOutcome, Never>) {
                    self.continuation = continuation
                }
                func resume(_ outcome: FolderLoadOutcome) {
                    lock.lock()
                    defer { lock.unlock() }
                    guard !resumed else { return }
                    resumed = true
                    continuation.resume(returning: outcome)
                }
            }
            let once = Once(continuation)

            Task.detached {
                once.resume(await load.value)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds) {
                once.resume(.notFound(tried: ["(timed out after \(Int(timeoutSeconds))s)"]))
            }
        }
    }

    nonisolated private static let folderBookmarkKey = "flipgrade.folderBookmark"
    nonisolated private static let lastFolderPathKey = "flipgrade.lastFolderPath"

    nonisolated private static func syncLoadFirstAvailableFolder(
        bookmarkData: Data?,
        savedPath: String?,
        bakedPath: String?
    ) -> FolderLoadOutcome {
        Self.debugLog("restore begin bookmark=\(bookmarkData != nil) saved=\(savedPath != nil)")

        var candidates: [(label: String, url: URL)] = []

        if let bookmarkData {
            if let url = Self.resolveBookmark(bookmarkData) {
                candidates.append(("bookmark", url))
            } else {
                Self.debugLog("bookmark present but failed to resolve (re-pick folder via Open Folder)")
            }
        }

        // Raw CloudStorage paths hang or EINTR for a LaunchServices .app without a bookmark.
        // Only try path-based restore for folders outside Google Drive CloudStorage.
        for (label, path) in [("baked", bakedPath), ("saved", savedPath)] {
            guard let path, !path.isEmpty else { continue }
            if path.contains("/CloudStorage/") || path.contains("/GoogleDrive") {
                Self.debugLog("skip \(label) path on CloudStorage without bookmark")
                continue
            }
            if candidates.contains(where: { $0.url.path == path }) { continue }
            candidates.append((label, URL(fileURLWithPath: path, isDirectory: true)))
        }

        var tried: [String] = []
        for candidate in candidates {
            tried.append(candidate.label + ":" + candidate.url.path)
            Self.debugLog("trying \(candidate.label) \(candidate.url.path)")
            do {
                let items = try FolderIndex.loadPhotos(in: candidate.url)
                let ratings = RatingStore.loadRatings(from: candidate.url)
                Self.debugLog("loaded \(items.count) photos via \(candidate.label)")
                return .loaded(url: candidate.url, items: items, ratings: ratings)
            } catch {
                Self.debugLog("failed \(candidate.label): \(error)")
                continue
            }
        }
        Self.debugLog("no folder opened (tried \(tried.joined(separator: " | ")))")
        return .notFound(tried: tried)
    }

    nonisolated private static func resolveBookmark(_ data: Data) -> URL? {
        var isStale = false
        // Prefer security-scoped; fall back for non-sandbox / older bookmarks.
        let attempts: [URL.BookmarkResolutionOptions] = [[.withSecurityScope], []]
        for options in attempts {
            isStale = false
            if let url = try? URL(
                resolvingBookmarkData: data,
                options: options,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                if options.contains(.withSecurityScope) {
                    _ = url.startAccessingSecurityScopedResource()
                }
                if isStale {
                    Self.debugLog("bookmark resolved but marked stale")
                }
                return url
            }
        }
        return nil
    }

    nonisolated private static func saveFolderAccess(_ url: URL) {
        UserDefaults.standard.set(url.path, forKey: lastFolderPathKey)
        // Store security-scoped when possible; also keep a plain bookmark as fallback.
        let scoped = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let plain = try? url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        if let scoped {
            UserDefaults.standard.set(scoped, forKey: folderBookmarkKey)
        } else if let plain {
            UserDefaults.standard.set(plain, forKey: folderBookmarkKey)
        }
    }

    nonisolated private static func debugLog(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Flipgrade/launch.log")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: url.path),
               let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
        NSLog("Flipgrade: %@", message)
    }

    func openDefaultZionIfPresent() {
        restoreFolderIfPossible()
    }

    func loadFolder(_ url: URL) {
        loadTask?.cancel()
        isLoading = true
        statusMessage = "Loading \(url.lastPathComponent)…"
        resetCullStateForNewFolder()
        _ = url.startAccessingSecurityScopedResource()

        loadTask = Task { @MainActor in
            let outcome = await Task.detached(priority: .userInitiated) { () -> FolderLoadOutcome in
                do {
                    let items = try FolderIndex.loadPhotos(in: url)
                    let ratings = RatingStore.loadRatings(from: url)
                    return .loaded(url: url, items: items, ratings: ratings)
                } catch {
                    return .failed(name: url.lastPathComponent, message: error.localizedDescription)
                }
            }.value
            guard !Task.isCancelled else { return }
            self.applyOutcome(outcome)
        }
    }

    private enum FolderLoadOutcome: Sendable {
        case loaded(url: URL, items: [PhotoItem], ratings: [String: Int])
        case failed(name: String, message: String)
        case notFound(tried: [String])
    }

    private func applyOutcome(_ outcome: FolderLoadOutcome) {
        switch outcome {
        case .loaded(let url, let items, let ratings):
            resetCullStateForNewFolder()
            isPixelZoom = false
            folderURL = url
            photos = items
            ratingLayer = .all
            ratingStore.applyLoaded(ratings: ratings, folder: url)
            rebuildActivePhotos(preferringID: items.first?.id, fanIn: false)
            isLoading = false
            Self.saveFolderAccess(url)
            if items.isEmpty {
                statusMessage = "No photos found in \(url.lastPathComponent)."
            } else {
                statusMessage = "\(items.count) photos — ←/→ flip · 0–3 rate · ↑/↓ layers"
                previews.prefetch(around: 0, in: activePhotos, radius: 4)
            }
        case .failed(let name, let message):
            isLoading = false
            photos = []
            activePhotos = []
            statusMessage = "Could not open \(name): \(message)"
        case .notFound:
            isLoading = false
            photos = []
            activePhotos = []
            statusMessage = "Open Folder… to choose photos (needed once for Google Drive)."
        }
    }

    private func resetCullStateForNewFolder() {
        previews.invalidate()
        liftTask?.cancel()
        liftingIDs = []
        departingCards = []
        arrivingCards = []
        cullReversed = false
        fanArmed = false
        fanStableIDs = []
        fanFromOffsets = [:]
    }

    nonisolated private static func saveFolderURL(_ url: URL) {
        saveFolderAccess(url)
    }

    func select(index: Int) {
        guard !activePhotos.isEmpty, !isCullBusy else { return }
        let clamped = min(max(0, index), activePhotos.count - 1)
        guard clamped != selectionIndex else { return }

        latency.beginFlip()
        selectionIndex = clamped
        latency.endFlip()
        flashRating(at: clamped)
        previews.prefetch(around: clamped, in: activePhotos)
    }

    func flashRating(at index: Int) {
        guard activePhotos.indices.contains(index) else { return }
        starFlash = .rating(ratingStore.rating(for: activePhotos[index]))
    }

    func goNext() { select(index: selectionIndex + 1) }
    func goPrevious() { select(index: selectionIndex - 1) }

    func togglePixelZoom() {
        guard currentPhoto != nil else { return }
        isPixelZoom.toggle()
        if isPixelZoom, let photo = currentPhoto {
            previews.request(photo, priority: .focused)
        }
    }

    func rate(_ stars: Int, advance: Bool = false) {
        guard !isCullBusy, let photo = currentPhoto else { return }
        let clamped = StarRating.clamp(stars)
        ratingStore.setRating(clamped, for: photo)
        objectWillChange.send()
        starFlash = .rating(clamped)

        let meets = clamped >= ratingLayer.minimumRating
        if meets {
            if advance { goNext() }
            return
        }

        // Below filter: gray with the pack; fly out when L1 slides into the neighbor.
        let nextID = neighborID(afterRemoving: photo.id)
        beginLift(ids: [photo.id], thenRebuildPreferring: nextID, fanIn: true)
    }

    func goLayerDown() {
        guard !isCullBusy else { return }
        var raw = ratingLayer.rawValue + 1
        while let next = RatingLayer(rawValue: raw) {
            if isReachableLayer(next) {
                hopToLayer(next)
                return
            }
            raw += 1
        }
    }

    func goLayerUp() {
        guard !isCullBusy else { return }
        var raw = ratingLayer.rawValue - 1
        while let next = RatingLayer(rawValue: raw) {
            if isReachableLayer(next) {
                hopToLayer(next)
                return
            }
            raw -= 1
        }
    }

    func setLayer(_ layer: RatingLayer) {
        guard !isCullBusy, layer != ratingLayer, isReachableLayer(layer) else { return }
        hopToLayer(layer)
    }

    func clearFanArmed() {
        fanArmed = false
    }

    /// `ALL` is always reachable when there are photos.
    /// Star layers are reachable only if some photo has exactly that many stars —
    /// so ↓ from ALL skips ≥1★ / ≥2★ when the only rated shots are 3★.
    private func isReachableLayer(_ layer: RatingLayer) -> Bool {
        let filtered = photos.filter { ratingStore.rating(for: $0) >= layer.minimumRating }
        guard !filtered.isEmpty else { return false }
        if layer == .all { return true }
        return photos.contains { ratingStore.rating(for: $0) == layer.minimumRating }
    }

    private func hopToLayer(_ layer: RatingLayer) {
        let filtered = photos.filter { ratingStore.rating(for: $0) >= layer.minimumRating }
        guard !filtered.isEmpty else { return }

        let currentID = currentPhoto?.id
        let preferID: String? = {
            guard let currentID else { return filtered.first?.id }
            let currentMeets = photos.first(where: { $0.id == currentID }).map {
                ratingStore.rating(for: $0) >= layer.minimumRating
            } ?? false
            if currentMeets { return currentID }
            return nearestQualifyingID(from: currentID, in: filtered)
        }()

        let leavingIDs = Set(activePhotos.map(\.id)).subtracting(filtered.map(\.id))
        let enteringIDs = Set(filtered.map(\.id)).subtracting(activePhotos.map(\.id))

        starFlash = .layer(layer)
        ratingLayer = layer

        if !leavingIDs.isEmpty {
            cullReversed = false
            beginLift(ids: leavingIDs, thenRebuildPreferring: preferID, fanIn: true)
            return
        }

        if !enteringIDs.isEmpty {
            beginRestore(ids: enteringIDs, preferringID: preferID)
            return
        }

        rebuildActivePhotos(preferringID: preferID, fanIn: false)
        previews.prefetch(around: selectionIndex, in: activePhotos)
    }

    /// Expand: reverse fan (L2→L1) to open slots, then reverse lift (drop in, full color).
    private func beginRestore(ids: Set<String>, preferringID: String?) {
        guard !ids.isEmpty else {
            rebuildActivePhotos(preferringID: preferringID, fanIn: false)
            return
        }
        liftTask?.cancel()
        departingCards = []
        liftingIDs = []

        let minStars = ratingLayer.minimumRating
        let newList = photos.filter { ratingStore.rating(for: $0) >= minStars }
        let focusIndex: Int = {
            if let preferringID, let idx = newList.firstIndex(where: { $0.id == preferringID }) {
                return idx
            }
            return min(selectionIndex, max(0, newList.count - 1))
        }()
        arrivingCards = ids.compactMap { id in
            guard let idx = newList.firstIndex(where: { $0.id == id }) else { return nil }
            return DepartingCard(
                id: id,
                photo: newList[idx],
                offset: CGFloat(idx - focusIndex),
                skipGray: false
            )
        }
        cullReversed = true

        rebuildActivePhotos(preferringID: preferringID, fanIn: true, startFanImmediately: true)
        previews.prefetch(around: selectionIndex, in: activePhotos)

        liftTask = Task { @MainActor in
            try? await Task.sleep(for: self.fanDuration)
            guard !Task.isCancelled else { return }
            // Drop-in uses the same lift clock, played in reverse.
            self.liftingIDs = Set(self.arrivingCards.map(\.id))
            try? await Task.sleep(for: self.liftDuration)
            guard !Task.isCancelled else { return }
            self.arrivingCards = []
            self.liftingIDs = []
            self.cullReversed = false
            self.fanArmed = false
            self.fanStableIDs = []
            self.fanFromOffsets = [:]
        }
    }

    /// All leavers (including focus) gray→fly together; then L1/L2 fan.
    private func beginLift(ids: Set<String>, thenRebuildPreferring preferringID: String?, fanIn: Bool) {
        guard !ids.isEmpty else {
            rebuildActivePhotos(preferringID: preferringID, fanIn: fanIn, startFanImmediately: true)
            previews.prefetch(around: selectionIndex, in: activePhotos)
            return
        }

        liftTask?.cancel()
        cullReversed = false
        arrivingCards = []

        // Freeze leavers relative to the current focus so a discarded center lifts from screen center.
        let focusIndex = selectionIndex
        departingCards = ids.compactMap { id in
            guard let idx = activePhotos.firstIndex(where: { $0.id == id }) else { return nil }
            return DepartingCard(
                id: id,
                photo: activePhotos[idx],
                offset: CGFloat(idx - focusIndex),
                skipGray: false
            )
        }
        liftingIDs = ids
        rebuildActivePhotos(preferringID: preferringID, fanIn: fanIn, startFanImmediately: false)
        previews.prefetch(around: selectionIndex, in: activePhotos)

        liftTask = Task { @MainActor in
            try? await Task.sleep(for: self.liftDuration)
            guard !Task.isCancelled else { return }
            self.departingCards = []
            self.liftingIDs = []
            // Focus handoff finished during the lift — settle it before L1/L2 fan.
            if let focusID = self.currentPhoto?.id {
                self.fanFromOffsets.removeValue(forKey: focusID)
                self.fanStableIDs.insert(focusID)
            }
            if fanIn && self.fanArmed {
                self.fanInToken &+= 1
            } else {
                self.fanArmed = false
                self.fanStableIDs = []
                self.fanFromOffsets = [:]
            }
        }
    }

    /// Nearest remaining neighbor after a removal; prefer left when both sides exist.
    private func neighborID(afterRemoving id: String) -> String? {
        guard let idx = activePhotos.firstIndex(where: { $0.id == id }) else { return nil }
        let left = idx > 0 ? activePhotos[idx - 1].id : nil
        let right = idx + 1 < activePhotos.count ? activePhotos[idx + 1].id : nil
        return left ?? right
    }

    /// Nearest qualifying photo in folder order; on a tie, prefer the left (lower index).
    private func nearestQualifyingID(from currentID: String, in qualifying: [PhotoItem]) -> String? {
        guard !qualifying.isEmpty else { return nil }
        guard let currentIdx = photos.firstIndex(where: { $0.id == currentID }) else {
            return qualifying.first?.id
        }
        let indexByID = Dictionary(uniqueKeysWithValues: photos.enumerated().map { ($0.element.id, $0.offset) })
        return qualifying.min { a, b in
            let ia = indexByID[a.id] ?? Int.max
            let ib = indexByID[b.id] ?? Int.max
            let da = abs(ia - currentIdx)
            let db = abs(ib - currentIdx)
            if da != db { return da < db }
            return ia < ib
        }?.id
    }

    private func rebuildActivePhotos(
        preferringID: String?,
        fanIn: Bool,
        startFanImmediately: Bool = true,
        keepID: String? = nil
    ) {
        let minStars = ratingLayer.minimumRating
        let oldIndexByID = Dictionary(uniqueKeysWithValues: activePhotos.enumerated().map { ($0.element.id, $0.offset) })
        // Fan poses are relative to the visual center before this rebuild.
        let oldFocusIndex: Int? = activePhotos.isEmpty ? nil : selectionIndex

        let list = photos.filter { photo in
            ratingStore.rating(for: photo) >= minStars || photo.id == keepID
        }

        activePhotos = list
        if list.isEmpty {
            selectionIndex = 0
            fanStableIDs = []
            fanFromOffsets = [:]
            fanArmed = false
            return
        }
        if let preferringID, let idx = list.firstIndex(where: { $0.id == preferringID }) {
            selectionIndex = idx
        } else {
            selectionIndex = min(selectionIndex, list.count - 1)
        }

        if fanIn {
            let newFocusID = activePhotos.indices.contains(selectionIndex) ? activePhotos[selectionIndex].id : nil
            let newFocusIndex = selectionIndex
            var stable: Set<String> = []
            var fromOffsets: [String: CGFloat] = [:]
            if let oldFocusIndex {
                for (idx, photo) in list.enumerated() {
                    guard let oldIdx = oldIndexByID[photo.id] else { continue }
                    let oldOffset = oldIdx - oldFocusIndex
                    let newOffset = idx - newFocusIndex
                    if oldOffset == newOffset {
                        stable.insert(photo.id)
                    } else {
                        fromOffsets[photo.id] = CGFloat(oldOffset)
                    }
                }
            }
            // New focus is stable only if it was already center; otherwise L1 → center.
            if let newFocusID,
               let oldFocusIndex,
               let oldIdx = oldIndexByID[newFocusID],
               oldIdx == oldFocusIndex {
                stable.insert(newFocusID)
                fromOffsets.removeValue(forKey: newFocusID)
            } else if let newFocusID, oldFocusIndex == nil {
                stable.insert(newFocusID)
            }
            fanStableIDs = stable
            fanFromOffsets = fromOffsets
            fanArmed = true
            if startFanImmediately {
                fanInToken &+= 1
            }
        } else {
            fanStableIDs = []
            fanFromOffsets = [:]
            fanArmed = false
        }
    }
}
