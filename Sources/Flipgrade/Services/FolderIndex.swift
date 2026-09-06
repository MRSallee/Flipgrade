import Foundation

enum FolderIndex {
    private static let imageExtensions: Set<String> = [
        "orf", "arw", "cr2", "cr3", "nef", "raf", "rw2", "dng",
        "jpg", "jpeg", "heic", "png", "tif", "tiff"
    ]

    static func loadPhotos(in folder: URL) throws -> [PhotoItem] {
        let fm = FileManager.default
        let contents = try fm.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        return contents
            .filter { url in
                guard url.lastPathComponent != "_flipgrade" else { return false }
                guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true else {
                    return false
                }
                return imageExtensions.contains(url.pathExtension.lowercased())
            }
            .map(PhotoItem.init)
            .sorted { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }
    }
}
