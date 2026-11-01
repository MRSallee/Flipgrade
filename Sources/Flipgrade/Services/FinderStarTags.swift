import Darwin
import Foundation

/// Maps Flipgrade star ratings onto macOS Finder color tags (Get Info → Tags).
/// 1★ Orange · 2★ Yellow · 3★ Green · 0★ clears those managed tags.
///
/// Never overrides a user-set label/tag outside {none, Orange, Yellow, Green}.
enum FinderStarTags {
    /// Star-mapped tag names Flipgrade may add or remove.
    nonisolated private static let managedNames: Set<String> = [
        "Orange", "Yellow", "Green"
    ]

    /// Finder color indices we are allowed to replace: 0 none · 2 green · 5 yellow · 6 orange.
    nonisolated private static let ownedColorIndices: Set<Int> = [0, 2, 5, 6]

    /// Other standard Finder color names — treat as user-owned if present.
    nonisolated private static let foreignColorNames: Set<String> = [
        "Red", "Blue", "Purple", "Gray", "Grey"
    ]

    nonisolated private static let userTagsXAttr = "com.apple.metadata:_kMDItemUserTags"

    nonisolated static func tagName(forStars stars: Int) -> String? {
        switch StarRating.clamp(stars) {
        case 1: return "Orange"
        case 2: return "Yellow"
        case 3: return "Green"
        default: return nil
        }
    }

    /// Finder tag / label color index: 0 none · 2 green · 5 yellow · 6 orange
    nonisolated static func colorIndex(forStars stars: Int) -> Int {
        switch StarRating.clamp(stars) {
        case 1: return 6
        case 2: return 5
        case 3: return 2
        default: return 0
        }
    }

    /// Writes tags via xattr (works on macOS 14+; `URLResourceValues.tagNames` setter is 26+).
    /// No-ops when the file already has a non-owned Finder label/tag.
    nonisolated static func apply(stars: Int, to url: URL) {
        let existing = readUserTags(from: url)
        if hasForeignLabel(on: url, tags: existing) {
            return
        }

        let clamped = StarRating.clamp(stars)
        var tags = existing.filter { !managedNames.contains($0.name) }
        if let name = tagName(forStars: clamped) {
            tags.append((name: name, color: colorIndex(forStars: clamped)))
        }

        do {
            try writeUserTags(tags, to: url)
        } catch {
            NSLog(
                "Flipgrade: failed to set Finder tag on %@: %@",
                url.lastPathComponent,
                String(describing: error)
            )
            return
        }

        // Legacy label bit — helps some Finder views pick up the color.
        var mutableURL = url
        var values = URLResourceValues()
        values.labelNumber = colorIndex(forStars: clamped)
        try? mutableURL.setResourceValues(values)
    }

    /// True when the user (or another app) set a color outside Flipgrade’s star palette.
    nonisolated private static func hasForeignLabel(
        on url: URL,
        tags: [(name: String, color: Int)]
    ) -> Bool {
        if let values = try? url.resourceValues(forKeys: [.labelNumberKey]),
           let label = values.labelNumber,
           !ownedColorIndices.contains(label) {
            return true
        }

        for tag in tags {
            if foreignColorNames.contains(tag.name) {
                return true
            }
            // Any non-zero color outside our palette (custom colored tags, etc.).
            if tag.color != 0, !ownedColorIndices.contains(tag.color) {
                return true
            }
        }
        return false
    }

    // MARK: - xattr

    nonisolated private static func readUserTags(from url: URL) -> [(name: String, color: Int)] {
        let path = url.path
        let size = getxattr(path, userTagsXAttr, nil, 0, 0, 0)
        guard size > 0 else { return [] }

        var buffer = [UInt8](repeating: 0, count: Int(size))
        let capacity = buffer.count
        let read = buffer.withUnsafeMutableBytes { raw in
            getxattr(path, userTagsXAttr, raw.baseAddress, capacity, 0, 0)
        }
        guard read > 0 else { return [] }

        let data = Data(buffer)
        guard let plist = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String] else {
            return []
        }

        return plist.map { entry in
            let parts = entry.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            let name = String(parts[0])
            let color = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
            return (name: name, color: color)
        }
    }

    nonisolated private static func writeUserTags(
        _ tags: [(name: String, color: Int)],
        to url: URL
    ) throws {
        let path = url.path
        if tags.isEmpty {
            if getxattr(path, userTagsXAttr, nil, 0, 0, 0) >= 0 {
                guard removexattr(path, userTagsXAttr, 0) == 0 else {
                    throw POSIXError(POSIXError.Code(rawValue: errno) ?? .EPERM)
                }
            }
            return
        }

        let payload = tags.map { "\($0.name)\n\($0.color)" }
        let data = try PropertyListSerialization.data(
            fromPropertyList: payload,
            format: .binary,
            options: 0
        )
        let result = data.withUnsafeBytes { raw -> Int32 in
            guard let base = raw.baseAddress else { return -1 }
            return setxattr(path, userTagsXAttr, base, data.count, 0, 0)
        }
        guard result == 0 else {
            throw POSIXError(POSIXError.Code(rawValue: errno) ?? .EPERM)
        }
    }
}
