import Foundation

/// A photo in the library, with what Sift needs to compare it and choose between copies.
public struct PhotoItem: Identifiable, Hashable, Sendable {
    public let id: String                 // the Photos library's identifier
    public var name: String
    public var date: Date?
    public var width: Int
    public var height: Int
    public var size: Int64                // bytes, or 0 if unknown
    public var favorite = false
    public var edited = false
    public var live = false
    public var burst = false
    public var raw = false
    public var screenshot = false
    public var cloudOnly = false
    public var hash: [UInt64]?            // its Fingerprint, once made

    public init(id: String, name: String, date: Date?, width: Int, height: Int, size: Int64,
                favorite: Bool = false, edited: Bool = false, live: Bool = false, burst: Bool = false,
                raw: Bool = false, screenshot: Bool = false, cloudOnly: Bool = false, hash: [UInt64]? = nil) {
        self.id = id; self.name = name; self.date = date; self.width = width; self.height = height
        self.size = size; self.favorite = favorite; self.edited = edited; self.live = live
        self.burst = burst; self.raw = raw; self.screenshot = screenshot; self.cloudOnly = cloudOnly
        self.hash = hash
    }

    public var pixels: Int { width * height }
}

/// How alike photos must be to count. Strict only finds copies; balanced and loose also
/// find similar shots taken within `window` seconds of each other (bursts, retakes) whose
/// fingerprints differ by at most `similarBits`.
public enum Strictness: String, CaseIterable, Identifiable, Sendable {
    case strict, balanced, loose

    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
    public var similarBits: Int {
        switch self { case .strict: 0; case .balanced: 40; case .loose: 64 }
    }
    public var window: TimeInterval {
        switch self { case .strict: 0; case .balanced: 600; case .loose: 3600 }
    }
    public var photoSummary: String {
        switch self {
        case .strict: "Only copies of the same photo: identical files, and re-saved or resized copies."
        case .balanced: "Copies, plus near-identical shots taken within 10 minutes, such as bursts and retakes."
        case .loose: "Copies, plus similar-looking shots taken within an hour. More to review."
        }
    }
}

public enum MatchKind: String, Sendable {
    case identical   // same file size and dimensions, and looks the same
    case same        // looks the same and was taken at the same moment (re-saved or resized)
    case similar     // looks alike and was taken within the strictness window (bursts, retakes)
    case lookalike   // looks the same but was taken at a very different time (or has no date)
}

public struct Match: Hashable, Sendable {
    public let a: Int, b: Int             // indexes into the items, a < b
    public let kind: MatchKind
}

public enum Suggestion: String, Sendable {
    case keep, delete, review
}

public struct SetMember: Hashable, Sendable {
    public let index: Int
    public let suggestion: Suggestion
    public let reason: String
}

/// A group of photos that look alike: the one to keep first, then the copies to delete
/// (largest first), then the ones to review.
public struct DuplicateSet: Identifiable, Hashable, Sendable {
    public let members: [SetMember]
    public init(members: [SetMember]) { self.members = members }
    public var id: Int { members[0].index }
    public var keeper: Int { members[0].index }

    /// The space freed by deleting the copies Sift suggests deleting.
    public func saving(_ items: [PhotoItem]) -> Int64 {
        members.filter { $0.suggestion == .delete }.reduce(0) { $0 + items[$1.index].size }
    }
}
