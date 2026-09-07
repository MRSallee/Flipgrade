import Foundation

struct RatingIndexFile: Codable {
    var version: Int = 2
    /// filename → 0…3 stars (0 / missing = unrated)
    var ratings: [String: Int]
}

@MainActor
final class RatingStore: ObservableObject {
    @Published private(set) var ratings: [String: Int] = [:]

    private var folderURL: URL?
    private var saveTask: Task<Void, Never>?

    var packageURL: URL? {
        folderURL?.appendingPathComponent("_flipgrade", isDirectory: true)
    }

    var indexURL: URL? {
        packageURL?.appendingPathComponent("index.json")
    }

    /// Disk read — call from a background task, then `applyLoaded` on the main actor.
    nonisolated static func loadRatings(from folder: URL) -> [String: Int] {
        let indexURL = folder
            .appendingPathComponent("_flipgrade", isDirectory: true)
            .appendingPathComponent("index.json")
        guard FileManager.default.fileExists(atPath: indexURL.path),
              let data = try? Data(contentsOf: indexURL),
              let v2 = try? JSONDecoder().decode(RatingIndexFile.self, from: data),
              v2.version >= 2
        else { return [:] }
        return v2.ratings.mapValues { StarRating.clamp($0) }
    }

    func applyLoaded(ratings: [String: Int], folder: URL) {
        folderURL = folder
        self.ratings = ratings
    }

    func load(for folder: URL) {
        applyLoaded(ratings: Self.loadRatings(from: folder), folder: folder)
    }

    func rating(for photo: PhotoItem) -> Int {
        StarRating.clamp(ratings[photo.id] ?? 0)
    }

    func setRating(_ rating: Int, for photo: PhotoItem) {
        let clamped = StarRating.clamp(rating)
        if clamped == 0 {
            ratings.removeValue(forKey: photo.id)
        } else {
            ratings[photo.id] = clamped
        }
        scheduleSave()
    }

    func counts(in photos: [PhotoItem]) -> (zero: Int, one: Int, two: Int, three: Int) {
        var zero = 0, one = 0, two = 0, three = 0
        for photo in photos {
            switch rating(for: photo) {
            case 1: one += 1
            case 2: two += 1
            case 3: three += 1
            default: zero += 1
            }
        }
        return (zero, one, two, three)
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            saveNow()
        }
    }

    private func saveNow() {
        guard let packageURL, let indexURL else { return }
        do {
            try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
            let payload = RatingIndexFile(ratings: ratings)
            let data = try JSONEncoder().encode(payload)
            let tmp = indexURL.appendingPathExtension("tmp")
            try data.write(to: tmp, options: .atomic)
            if FileManager.default.fileExists(atPath: indexURL.path) {
                try FileManager.default.removeItem(at: indexURL)
            }
            try FileManager.default.moveItem(at: tmp, to: indexURL)
        } catch {
            NSLog("Flipgrade: failed to save rating index: \(error)")
        }
    }
}
