import AppKit
import Foundation
import SwiftUI

@MainActor
final class FlipSession: ObservableObject {
    @Published var folderURL: URL?
    @Published var photos: [PhotoItem] = []
    @Published var selectionIndex: Int = 0
    @Published var statusMessage: String = "Open a folder of photos to start culling."
    @Published var isLoading = false

    let cullStore = CullStore()
    let previews = PreviewService.shared
    let latency = LatencyProbe.shared

    var currentPhoto: PhotoItem? {
        guard photos.indices.contains(selectionIndex) else { return nil }
        return photos[selectionIndex]
    }

    func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Open"
        panel.message = "Choose a folder of RAW/JPEG photos to cull."

        if let defaultZion = Self.defaultZionURL(), FileManager.default.fileExists(atPath: defaultZion.path) {
            panel.directoryURL = defaultZion.deletingLastPathComponent()
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadFolder(url)
    }

    func openDefaultZionIfPresent() {
        guard let url = Self.defaultZionURL(),
              FileManager.default.fileExists(atPath: url.path)
        else { return }
        loadFolder(url)
    }

    func loadFolder(_ url: URL) {
        isLoading = true
        statusMessage = "Loading \(url.lastPathComponent)…"
        previews.invalidate()

        do {
            let items = try FolderIndex.loadPhotos(in: url)
            folderURL = url
            photos = items
            selectionIndex = 0
            cullStore.load(for: url)
            isLoading = false

            if items.isEmpty {
                statusMessage = "No photos found in \(url.lastPathComponent)."
            } else {
                statusMessage = "\(items.count) photos — Flip with ←/→ · P keep · A archive · X reject"
                previews.prefetch(around: 0, in: items)
            }
        } catch {
            isLoading = false
            statusMessage = "Could not open folder: \(error.localizedDescription)"
        }
    }

    func select(index: Int) {
        guard !photos.isEmpty else { return }
        let clamped = min(max(0, index), photos.count - 1)
        guard clamped != selectionIndex else {
            previews.prefetch(around: clamped, in: photos)
            return
        }
        latency.beginFlip()
        // Selection updates immediately; Cover Flow animates continuous flow in the view
        // (stacked interrupts share one settle window from this keypress).
        selectionIndex = clamped
        latency.endFlip()
        previews.prefetch(around: clamped, in: photos)
    }

    func goNext() { select(index: selectionIndex + 1) }
    func goPrevious() { select(index: selectionIndex - 1) }

    func mark(_ decision: CullDecision, advance: Bool = true) {
        guard let photo = currentPhoto else { return }
        cullStore.set(decision, for: photo)
        if advance { goNext() }
    }

    private static func defaultZionURL() -> URL? {
        var roots: [URL] = []

        if let repoRootFile = Bundle.main.url(forResource: "repo-root", withExtension: "txt"),
           let contents = try? String(contentsOf: repoRootFile, encoding: .utf8) {
            let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                roots.append(URL(fileURLWithPath: trimmed))
            }
        }

        roots.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        roots.append(URL(fileURLWithPath: Bundle.main.bundlePath))

        for root in roots {
            var url = root
            for _ in 0..<10 {
                let candidate = url.appendingPathComponent("_comms/Zion", isDirectory: true)
                if FileManager.default.fileExists(atPath: candidate.path) {
                    return candidate
                }
                url.deleteLastPathComponent()
            }
        }
        return nil
    }
}
