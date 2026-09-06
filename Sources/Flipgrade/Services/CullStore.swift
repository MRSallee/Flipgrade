import Foundation

struct CullIndexFile: Codable {
    var version: Int = 1
    var decisions: [String: CullDecision]
}

@MainActor
final class CullStore: ObservableObject {
    @Published private(set) var decisions: [String: CullDecision] = [:]

    private var folderURL: URL?
    private var saveTask: Task<Void, Never>?

    var packageURL: URL? {
        folderURL?.appendingPathComponent("_flipgrade", isDirectory: true)
    }

    var indexURL: URL? {
        packageURL?.appendingPathComponent("index.json")
    }

    func load(for folder: URL) {
        folderURL = folder
        decisions = [:]

        guard let indexURL,
              FileManager.default.fileExists(atPath: indexURL.path),
              let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode(CullIndexFile.self, from: data)
        else { return }

        decisions = decoded.decisions
    }

    func decision(for photo: PhotoItem) -> CullDecision {
        decisions[photo.id] ?? .undecided
    }

    func set(_ decision: CullDecision, for photo: PhotoItem) {
        if decision == .undecided {
            decisions.removeValue(forKey: photo.id)
        } else {
            decisions[photo.id] = decision
        }
        scheduleSave()
    }

    func counts(in photos: [PhotoItem]) -> (keepers: Int, archive: Int, rejects: Int, undecided: Int) {
        var keepers = 0, archive = 0, rejects = 0, undecided = 0
        for photo in photos {
            switch decision(for: photo) {
            case .keeper: keepers += 1
            case .archive: archive += 1
            case .reject: rejects += 1
            case .undecided: undecided += 1
            }
        }
        return (keepers, archive, rejects, undecided)
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
            let payload = CullIndexFile(decisions: decisions)
            let data = try JSONEncoder().encode(payload)
            let tmp = indexURL.appendingPathExtension("tmp")
            try data.write(to: tmp, options: .atomic)
            if FileManager.default.fileExists(atPath: indexURL.path) {
                try FileManager.default.removeItem(at: indexURL)
            }
            try FileManager.default.moveItem(at: tmp, to: indexURL)
        } catch {
            NSLog("Flipgrade: failed to save cull index: \(error)")
        }
    }
}
