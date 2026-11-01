import AppKit
import Foundation

struct RecentFolderRecord: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var displayName: String
    var path: String
    var bookmarkData: Data?
    var photoCount: Int
    var ratedCount: Int
    var lastEdited: Date
    /// Filename under Application Support/Flipgrade/RecentThumbs/
    var thumbnailFileName: String?

    var subtitlePhotos: String {
        if ratedCount > 0 {
            return "\(photoCount) photos (\(ratedCount) rated)"
        }
        return "\(photoCount) photos"
    }

    var subtitleEdited: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        let relative = formatter.localizedString(for: lastEdited, relativeTo: Date())
        return "Last edited \(relative)"
    }
}

/// Persists recently opened cull folders (bookmark + lightweight stats + thumb).
@MainActor
final class RecentFoldersStore: ObservableObject {
    @Published private(set) var folders: [RecentFolderRecord] = []

    private let limit = 24
    private let defaultsKey = "flipgrade.recentFolders.v1"

    private var thumbsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("Flipgrade/RecentThumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var storeURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("Flipgrade", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("recents.json")
    }

    init() {
        load()
        migrateLegacySingleFolderIfNeeded()
    }

    func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let decoded = try? JSONDecoder().decode([RecentFolderRecord].self, from: data)
        else {
            folders = []
            return
        }
        folders = decoded.sorted { $0.lastEdited > $1.lastEdited }
    }

    func thumbnail(for record: RecentFolderRecord) -> NSImage? {
        guard let name = record.thumbnailFileName else { return nil }
        let url = thumbsDirectory.appendingPathComponent(name)
        return NSImage(contentsOf: url)
    }

    func resolveURL(for record: RecentFolderRecord) -> URL? {
        if let data = record.bookmarkData {
            var isStale = false
            for options: URL.BookmarkResolutionOptions in [[.withSecurityScope], []] {
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
                    return url
                }
            }
        }
        let path = record.path
        if path.contains("/CloudStorage/") || path.contains("/GoogleDrive") {
            return nil
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Call after a folder successfully opens (and whenever ratings/counts change).
    func remember(
        url: URL,
        photoCount: Int,
        ratedCount: Int,
        thumbnail: NSImage? = nil
    ) {
        let path = url.path
        let bookmark = bookmarkData(for: url)
        let existingIndex = folders.firstIndex { $0.path == path }
        var record = existingIndex.map { folders[$0] } ?? RecentFolderRecord(
            id: UUID().uuidString,
            displayName: url.lastPathComponent,
            path: path,
            bookmarkData: bookmark,
            photoCount: photoCount,
            ratedCount: ratedCount,
            lastEdited: Date(),
            thumbnailFileName: nil
        )
        record.displayName = url.lastPathComponent
        record.path = path
        record.bookmarkData = bookmark ?? record.bookmarkData
        record.photoCount = photoCount
        record.ratedCount = ratedCount
        record.lastEdited = Date()

        if let thumbnail, let fileName = writeThumbnail(thumbnail, id: record.id) {
            record.thumbnailFileName = fileName
        }

        if let existingIndex {
            folders.remove(at: existingIndex)
        }
        folders.insert(record, at: 0)
        if folders.count > limit {
            let removed = folders.suffix(from: limit)
            for old in removed {
                removeThumbnailFile(old.thumbnailFileName)
            }
            folders = Array(folders.prefix(limit))
        }
        persist()
    }

    func remove(_ record: RecentFolderRecord) {
        folders.removeAll { $0.id == record.id }
        removeThumbnailFile(record.thumbnailFileName)
        persist()
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(folders)
            try data.write(to: storeURL, options: .atomic)
        } catch {
            NSLog("Flipgrade: failed to save recents: \(error)")
        }
    }

    private func bookmarkData(for url: URL) -> Data? {
        let scoped = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        if let scoped { return scoped }
        return try? url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    private func writeThumbnail(_ image: NSImage, id: String) -> String? {
        let fileName = "\(id).jpg"
        let url = thumbsDirectory.appendingPathComponent(fileName)
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.82])
        else { return nil }
        do {
            try jpeg.write(to: url, options: .atomic)
            return fileName
        } catch {
            return nil
        }
    }

    private func removeThumbnailFile(_ name: String?) {
        guard let name else { return }
        let url = thumbsDirectory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
    }

    /// Seed recents from the pre-library single-folder bookmark/path.
    private func migrateLegacySingleFolderIfNeeded() {
        guard folders.isEmpty else { return }
        let bookmark = UserDefaults.standard.data(forKey: "flipgrade.folderBookmark")
        let path = UserDefaults.standard.string(forKey: "flipgrade.lastFolderPath")
        guard bookmark != nil || (path != nil && !(path?.isEmpty ?? true)) else { return }

        var url: URL?
        if let bookmark {
            url = resolveURL(for: RecentFolderRecord(
                id: "legacy",
                displayName: "",
                path: path ?? "",
                bookmarkData: bookmark,
                photoCount: 0,
                ratedCount: 0,
                lastEdited: Date(),
                thumbnailFileName: nil
            ))
        }
        if url == nil, let path, !path.contains("/CloudStorage/"), !path.contains("/GoogleDrive") {
            url = URL(fileURLWithPath: path, isDirectory: true)
        }
        guard let url else { return }

        let photos = (try? FolderIndex.loadPhotos(in: url)) ?? []
        let ratings = RatingStore.loadRatings(from: url)
        let rated = ratings.values.filter { $0 > 0 }.count
        remember(url: url, photoCount: photos.count, ratedCount: rated, thumbnail: nil)
    }
}
