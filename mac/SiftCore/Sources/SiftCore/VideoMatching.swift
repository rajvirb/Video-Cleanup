import Foundation

/// A video, with what Sift needs to find copies of it.
public struct VideoClip: Identifiable, Hashable, Sendable {
    public let id: String
    public var size: Int64
    public var duration: Double
    public var width: Int
    public var height: Int
    public var favorite: Bool
    public var cloudOnly: Bool
    public var frames: [UInt64]     // fingerprints of frames throughout it (empty if it couldn't be opened)
    public var poster: UInt64?      // a fingerprint of Photos' preview image

    public init(id: String, size: Int64, duration: Double, width: Int, height: Int, favorite: Bool = false,
                cloudOnly: Bool = false, frames: [UInt64] = [], poster: UInt64? = nil) {
        self.id = id; self.size = size; self.duration = duration; self.width = width; self.height = height
        self.favorite = favorite; self.cloudOnly = cloudOnly; self.frames = frames; self.poster = poster
    }
}

/// Finds videos that are copies of each other, trimmed from each other, or (unless strict)
/// just alike. The same rules as the Python version (sift.py's find_matches).
public enum VideoMatcher {
    public static let framesPerSecond = 4.0     // frames fingerprinted per second of video…
    public static let maxFrames = 160            // …up to this many
    static let queryFrames = 24                  // frames of each video looked up in the others
    static let minInformative = 3                // need this many usable frames to compare by content

    /// When to take a frame for fingerprinting, in seconds.
    public static func frameTimes(duration: Double) -> [Double] {
        guard duration > 0 else { return [0] }
        let rate = min(framesPerSecond, Double(maxFrames) / max(duration, 1))
        let count = max(1, min(maxFrames, Int(duration * rate)))
        return (0..<count).map { (Double($0) + 0.5) / rate }
    }

    public static func findMatches(_ clips: [VideoClip], strictness: Strictness,
                                   progress: (@Sendable (Int, Int) -> Void)? = nil) -> [Match] {
        let rank: [MatchKind: Int] = [.similar: 0, .trimmed: 1, .same: 2, .identical: 3]
        var edges: [Pair: MatchKind] = [:]
        func add(_ i: Int, _ j: Int, _ kind: MatchKind) {
            let key = Pair(min(i, j), max(i, j))
            if let old = edges[key], rank[old]! >= rank[kind]! { return }
            edges[key] = kind
        }

        // 1. identical: same byte size and length
        var bySignature: [String: [Int]] = [:]
        for (i, c) in clips.enumerated() where c.size > 0 {
            bySignature["\(c.size)|\((c.duration * 10).rounded())", default: []].append(i)
        }
        for group in bySignature.values where group.count > 1 {
            for other in group.dropFirst() { add(group[0], other, .identical) }
        }

        // 2. the same poster and nearly the same length: re-saved copies, even of videos
        //    whose originals are only in iCloud
        let withPoster = clips.indices.filter { clips[$0].poster != nil && clips[$0].duration > 0 }
        for (k, i) in withPoster.enumerated() {
            for j in withPoster[(k + 1)...] {
                let a = clips[i], b = clips[j]
                let tolerance = max(1, 0.03 * max(a.duration, b.duration))
                if (a.poster! ^ b.poster!).nonzeroBitCount <= strictness.posterBits && abs(a.duration - b.duration) <= tolerance {
                    add(i, j, .same)
                }
            }
        }

        // 3. content: the share of one video's frames that turn up in the other
        let cover = coverage(clips, strictness: strictness, progress: progress)
        for (pair, _) in cover {
            let (i, j) = (pair.a, pair.b)
            let a = clips[i], b = clips[j]
            let back = cover[Pair(j, i)] ?? 0
            if back >= strictness.cover && closeDurations(a.duration, b.duration) {
                add(i, j, .same)
            } else if a.duration > 0 && b.duration > 0 && a.duration < 0.9 * b.duration {
                add(i, j, .trimmed)                       // i is a shorter piece of j
            } else if strictness.videoSimilar {
                add(i, j, .similar)
            }
        }
        return edges.map { Match(a: $0.key.a, b: $0.key.b, kind: $0.value) }
    }

    struct Pair: Hashable { let a: Int, b: Int; init(_ a: Int, _ b: Int) { self.a = a; self.b = b } }

    /// For each pair of videos (i, j): the share of i's sampled frames found in j, when it's
    /// at least the strictness's cover. Every frame of every video is checked, in parallel.
    static func coverage(_ clips: [VideoClip], strictness: Strictness,
                         progress: (@Sendable (Int, Int) -> Void)?) -> [Pair: Double] {
        let usable = clips.indices.filter { clips[$0].frames.count >= minInformative }
        guard usable.count > 1 else { return [:] }
        var all: [UInt64] = []
        var owner: [Int32] = []                           // which of `usable` each frame belongs to
        for (u, i) in usable.enumerated() {
            all += clips[i].frames
            owner += Array(repeating: Int32(u), count: clips[i].frames.count)
        }
        let bits = strictness.frameBits
        let need = strictness.cover
        let lock = NSLock()
        var found: [Pair: Double] = [:]
        var done = 0
        all.withUnsafeBufferPointer { frames in
            owner.withUnsafeBufferPointer { owners in
                DispatchQueue.concurrentPerform(iterations: usable.count) { u in
                    let queries = sample(clips[usable[u]].frames)
                    var hits = [Int32](repeating: 0, count: usable.count)      // queries found in each video
                    var seen = [Int32](repeating: -1, count: usable.count)     // last query that hit it
                    for (q, query) in queries.enumerated() {
                        for f in 0..<frames.count where (frames[f] ^ query).nonzeroBitCount <= bits {
                            let v = Int(owners[f])
                            if v != u && seen[v] != Int32(q) { seen[v] = Int32(q); hits[v] += 1 }
                        }
                    }
                    var mine: [Pair: Double] = [:]
                    for v in 0..<usable.count where v != u && hits[v] >= Int32(minInformative) {
                        let share = Double(hits[v]) / Double(queries.count)
                        if share >= need { mine[Pair(usable[u], usable[v])] = share }
                    }
                    lock.lock()
                    found.merge(mine) { a, _ in a }
                    done += 1
                    let finished = done
                    lock.unlock()
                    progress?(finished, usable.count)
                }
            }
        }
        return found
    }

    /// An evenly spread subset of a video's frames, used to look it up in the others.
    static func sample(_ frames: [UInt64]) -> [UInt64] {
        guard frames.count > queryFrames else { return frames }
        return (0..<queryFrames).map { frames[Int((Double($0) * Double(frames.count - 1) / Double(queryFrames - 1)).rounded())] }
    }

    static func closeDurations(_ a: Double, _ b: Double, tolerance: Double = 0.1) -> Bool {
        guard a > 0, b > 0 else { return false }
        return abs(a - b) <= max(1.5, tolerance * max(a, b))
    }

    public static let reasons: [MatchKind: String] = [
        .identical: "Identical copy of the one marked Keep",
        .same: "Same video as the one marked Keep, saved as a separate file",
        .trimmed: "Shorter clip — everything in it is also in the one marked Keep",
        .similar: "Looks very similar to another video here — check before deleting",
    ]

    /// Groups matching videos into sets, keeps the most complete, best-quality copy (the
    /// longest, then highest resolution; favourites and ones on this Mac win ties), and
    /// suggests deleting copies and shorter trimmed clips, unless they're favourites.
    public static func buildSets(_ clips: [VideoClip], matches: [Match]) -> [DuplicateSet] {
        var parent = Array(clips.indices)
        func find(_ x: Int) -> Int {
            var x = x
            while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }
            return x
        }
        var kinds: [Pair: MatchKind] = [:]
        for m in matches {
            parent[find(m.a)] = find(m.b)
            kinds[Pair(min(m.a, m.b), max(m.a, m.b))] = m.kind
        }
        var clusters: [Int: [Int]] = [:]
        for i in Set(matches.flatMap { [$0.a, $0.b] }).sorted() { clusters[find(i), default: []].append(i) }

        func quality(_ i: Int) -> [Double] {
            let c = clips[i]
            return [c.duration.rounded(), Double(c.width * c.height), c.favorite ? 1 : 0, c.cloudOnly ? 0 : 1, Double(c.size)]
        }
        var sets: [DuplicateSet] = []
        for members in clusters.values {
            let keeper = members.max { quality($0).lexicographicallyPrecedes(quality($1)) }!
            var rest: [SetMember] = []
            for m in members where m != keeper {
                var kind = kinds[Pair(min(m, keeper), max(m, keeper))]
                if kind == .trimmed && clips[m].duration > clips[keeper].duration { kind = .similar }
                if let k = kind, [.identical, .same, .trimmed].contains(k) {
                    rest.append(clips[m].favorite
                        ? SetMember(index: m, suggestion: .review, reason: reasons[k]! + " (but it's a favourite)")
                        : SetMember(index: m, suggestion: .delete, reason: reasons[k]!))
                } else {
                    rest.append(SetMember(index: m, suggestion: .review, reason: reasons[.similar]!))
                }
            }
            rest.sort { ($0.suggestion == .delete ? 0 : 1, -clips[$0.index].size) < ($1.suggestion == .delete ? 0 : 1, -clips[$1.index].size) }
            sets.append(DuplicateSet(members: [SetMember(index: keeper, suggestion: .keep,
                                                         reason: "Best copy: longest and highest quality")] + rest))
        }
        func saving(_ s: DuplicateSet) -> Int64 {
            s.members.filter { $0.suggestion == .delete }.reduce(0) { $0 + clips[$1.index].size }
        }
        return sets.sorted { (saving($0), $0.members.count) > (saving($1), $1.members.count) }
    }
}
