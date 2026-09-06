import Foundation

struct PhotoItem: Identifiable, Hashable, Sendable {
    let id: String
    let url: URL
    let fileName: String

    init(url: URL) {
        self.url = url
        self.fileName = url.lastPathComponent
        self.id = url.lastPathComponent
    }
}
