import Foundation

enum CullDecision: String, Codable, CaseIterable, Sendable {
    case undecided
    case keeper
    case archive
    case reject

    var label: String {
        switch self {
        case .undecided: "—"
        case .keeper: "Keeper"
        case .archive: "Archive"
        case .reject: "Reject"
        }
    }

    var shortKey: String {
        switch self {
        case .undecided: ""
        case .keeper: "P"
        case .archive: "A"
        case .reject: "X"
        }
    }
}
