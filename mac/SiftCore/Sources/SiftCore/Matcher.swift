import Foundation

/// Finds photos that look alike. A photo is only called a copy (to delete) when there's
/// evidence: the identical file, or the same picture taken at the same moment. Bursts and
/// retakes look just as alike, so everything else is only for review.
public enum Matcher {
    /// Photos whose fingerprints differ by at most this look the same.
    public static let sameBits = 24
    /// …and are copies if they were also taken this close together.
    public static let copySeconds: TimeInterval = 0.5

    public static func findPhotoMatches(_ items: [PhotoItem], strictness: Strictness,
                                        progress: (@Sendable (Int, Int) -> Void)? = nil) -> [Match] {
        let idx = items.indices.filter { items[$0].hash?.count == 4 }
        let n = idx.count
        guard n > 1 else { return [] }
        var hashes = [UInt64](repeating: 0, count: n * 4)
        var times = [Double](repeating: .nan, count: n)
        for (k, i) in idx.enumerated() {
            for w in 0..<4 { hashes[k * 4 + w] = items[i].hash![w] }
            times[k] = items[i].date?.timeIntervalSinceReferenceDate ?? .nan
        }
        let limit = max(sameBits, strictness.similarBits)
        let window = strictness.window
        let lock = NSLock()
        var matches: [Match] = []
        var done = 0
        let chunk = max(1, n / 64)
        let chunks = (n + chunk - 1) / chunk

        hashes.withUnsafeBufferPointer { h in
            times.withUnsafeBufferPointer { t in
                DispatchQueue.concurrentPerform(iterations: chunks) { c in
                    var found: [Match] = []
                    for r in (c * chunk)..<min(n, (c + 1) * chunk) {
                        let a0 = h[r * 4], a1 = h[r * 4 + 1], a2 = h[r * 4 + 2], a3 = h[r * 4 + 3]
                        var s = r + 1
                        while s < n {
                            let d = (a0 ^ h[s * 4]).nonzeroBitCount + (a1 ^ h[s * 4 + 1]).nonzeroBitCount
                                + (a2 ^ h[s * 4 + 2]).nonzeroBitCount + (a3 ^ h[s * 4 + 3]).nonzeroBitCount
                            if d <= limit,
                               let kind = classify(items[idx[r]], items[idx[s]], distance: d,
                                                   apart: abs(t[r] - t[s]), window: window) {
                                found.append(Match(a: idx[r], b: idx[s], kind: kind))
                            }
                            s += 1
                        }
                    }
                    lock.lock()
                    matches += found
                    done += 1
                    let finished = done
                    lock.unlock()
                    progress?(finished, chunks)
                }
            }
        }
        return matches
    }

    /// What two photos that look alike are to each other, if anything. `apart` is the
    /// time between them in seconds (NaN if either has no date).
    static func classify(_ a: PhotoItem, _ b: PhotoItem, distance: Int, apart: Double, window: Double) -> MatchKind? {
        let soon = apart <= window                       // false when NaN
        if distance <= sameBits {
            if a.size > 0 && a.size == b.size && a.width == b.width && a.height == b.height { return .identical }
            if apart <= copySeconds && !(a.burst || b.burst) { return .same }
            if soon { return .similar }
            if !(apart <= 3600) { return .lookalike }   // far apart in time, or no date
            return nil
        }
        return soon ? .similar : nil
    }
}
