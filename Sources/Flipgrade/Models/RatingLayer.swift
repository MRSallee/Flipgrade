import Foundation

/// Minimum stars required to appear in a Flip layer. `all` is every photo (rating 0–3).
enum RatingLayer: Int, CaseIterable, Identifiable, Sendable {
    case all = 0
    case onePlus = 1
    case twoPlus = 2
    case three = 3

    var id: Int { rawValue }

    var minimumRating: Int { rawValue }

    var title: String {
        switch self {
        case .all: "ALL"
        case .onePlus, .twoPlus, .three: ""
        }
    }
}

enum StarRating {
    static let maxStars = 3
    static func clamp(_ value: Int) -> Int { Swift.min(maxStars, Swift.max(0, value)) }
}
