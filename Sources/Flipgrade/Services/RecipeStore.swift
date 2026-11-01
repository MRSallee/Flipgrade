import Foundation

/// Persists per-photo `EditRecipe` under `_flipgrade/recipes/<filename>.json`.
@MainActor
final class RecipeStore: ObservableObject {
    private var recipes: [String: EditRecipe] = [:]

    private var folderURL: URL?
    private var saveTasks: [String: Task<Void, Never>] = [:]

    private var recipesDirectory: URL? {
        folderURL?
            .appendingPathComponent("_flipgrade", isDirectory: true)
            .appendingPathComponent("recipes", isDirectory: true)
    }

    func load(for folder: URL) {
        folderURL = folder
        recipes = [:]
        guard let dir = recipesDirectory,
              let files = try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
              )
        else {
            objectWillChange.send()
            return
        }

        for file in files where file.pathExtension.lowercased() == "json" {
            let id = file.deletingPathExtension().lastPathComponent
            guard let data = try? Data(contentsOf: file),
                  let recipe = try? JSONDecoder().decode(EditRecipe.self, from: data)
            else { continue }
            recipes[id] = recipe
        }
        objectWillChange.send()
    }

    func clear() {
        folderURL = nil
        recipes = [:]
        saveTasks.values.forEach { $0.cancel() }
        saveTasks.removeAll()
        objectWillChange.send()
    }

    func recipe(for photo: PhotoItem) -> EditRecipe {
        recipes[photo.id] ?? .identity
    }

    func setRecipe(_ recipe: EditRecipe, for photo: PhotoItem) {
        // Quiet update — Grade already publishes `gradeRecipe` each scrub tick.
        // Publishing here would double-refresh the whole app on every slider sample.
        if recipe.isIdentity {
            recipes.removeValue(forKey: photo.id)
            removeFile(for: photo.id)
        } else {
            recipes[photo.id] = recipe
            scheduleSave(recipe, id: photo.id)
        }
    }

    private func scheduleSave(_ recipe: EditRecipe, id: String) {
        saveTasks[id]?.cancel()
        saveTasks[id] = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            saveNow(recipe, id: id)
        }
    }

    private func saveNow(_ recipe: EditRecipe, id: String) {
        guard let dir = recipesDirectory else { return }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("\(id).json")
            let data = try JSONEncoder().encode(recipe)
            let tmp = url.appendingPathExtension("tmp")
            try data.write(to: tmp, options: .atomic)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            try FileManager.default.moveItem(at: tmp, to: url)
        } catch {
            NSLog("Flipgrade: failed to save recipe \(id): \(error)")
        }
    }

    private func removeFile(for id: String) {
        guard let dir = recipesDirectory else { return }
        let url = dir.appendingPathComponent("\(id).json")
        try? FileManager.default.removeItem(at: url)
    }
}
