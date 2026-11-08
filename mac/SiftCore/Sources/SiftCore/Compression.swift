import Foundation

/// A video in the library, with what Sift needs to decide whether a smaller copy is worth making.
public struct VideoItem: Identifiable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var date: Date?
    public var width: Int
    public var height: Int
    public var size: Int64           // bytes, or 0 if unknown
    public var duration: Double      // seconds
    public var fps: Double = 0       // 0 if not known yet (it's only known once the file is opened)
    public var favorite = false
    public var slowMo = false
    public var timeLapse = false
    public var edited = false

    public init(id: String, name: String, date: Date?, width: Int, height: Int, size: Int64, duration: Double,
                fps: Double = 0, favorite: Bool = false, slowMo: Bool = false, timeLapse: Bool = false, edited: Bool = false) {
        self.id = id; self.name = name; self.date = date; self.width = width; self.height = height
        self.size = size; self.duration = duration; self.fps = fps; self.favorite = favorite
        self.slowMo = slowMo; self.timeLapse = timeLapse; self.edited = edited
    }

    public var shortSide: Int { min(width, height) }
}

public enum CompressionMode: String, CaseIterable, Identifiable, Sendable {
    case sameResolution, cap1080p
    public var id: String { rawValue }
    public var title: String { self == .sameResolution ? "Same resolution" : "Cap at 1080p" }
    public var summary: String {
        self == .sameResolution
            ? "Re-saved in the HEVC format iPhones use now, at the same resolution. No visible difference."
            : "Re-saved as HEVC and capped at 1080p. Fine on a phone or laptop, a little less sharp on a big 4K TV."
    }
}

public struct CompressionPlan: Hashable, Sendable {
    public let mode: CompressionMode
    public let shortSide: Int          // the copy's shorter dimension
    public let kbps: Int               // its video bitrate
    public let estimatedSize: Int64
    public let label: String           // "4K → 1080p", "HEVC at a standard bitrate"…

    public func saving(_ video: VideoItem) -> Int64 { max(0, video.size - estimatedSize) }
}

/// When a smaller copy of a video is worth making, and how: the same rules as the
/// Python version (sift.py's plan_compression).
public enum Compression {
    public static let audioKbps = 256
    public static let minSaving: Int64 = 15_000_000     // don't bother for less than 15 MB

    /// Roughly the bitrate an iPhone uses for HEVC at this size and frame rate
    /// (1080p30 ≈ 60 MB a minute, 4K30 ≈ 170 MB, 4K60 ≈ 400 MB).
    public static func targetKbps(shortSide: Int, fps: Double) -> Int {
        let high = (fps > 0 ? fps : 30) > 40
        switch shortSide {
        case ...540: return high ? 3500 : 2500
        case ...720: return high ? 7000 : 5000
        case ...1080: return high ? 12000 : 8000
        case ...1440: return high ? 24000 : 14000
        default: return high ? 45000 : 23000
        }
    }

    /// The plan for a smaller copy, or nil if it isn't worth it: re-saving would lose a
    /// slo-mo, time-lapse or edit, the video is already efficiently stored, or it would save
    /// less than 15 MB.
    public static func plan(_ video: VideoItem, mode: CompressionMode) -> CompressionPlan? {
        guard video.duration > 0, video.size > 0, video.width > 0, video.height > 0 else { return nil }
        if video.slowMo || video.timeLapse || video.edited || video.fps > 65 { return nil }
        let short = video.shortSide
        let newShort = mode == .cap1080p ? min(short, 1080) : short
        let kbps = targetKbps(shortSide: newShort, fps: video.fps)
        let estimate = Int64(Double(kbps + audioKbps) * 1000 / 8 * video.duration)
        let currentKbps = Double(video.size) * 8 / video.duration / 1000
        if currentKbps < 1.5 * Double(kbps + audioKbps) || video.size - estimate < minSaving { return nil }
        let label = newShort < short ? "\(resolution(short)) → \(resolution(newShort)) HEVC" : "HEVC at a standard bitrate"
        return CompressionPlan(mode: mode, shortSide: newShort, kbps: kbps, estimatedSize: estimate, label: label)
    }

    public static func resolution(_ shortSide: Int) -> String {
        shortSide >= 2000 ? "4K" : "\(shortSide)p"
    }

    /// The copy's width and height: scaled to the plan's shorter side, kept even (HEVC needs that).
    public static func outputSize(width: Int, height: Int, shortSide: Int) -> (width: Int, height: Int) {
        let short = min(width, height)
        guard shortSide < short else { return (width - width % 2, height - height % 2) }
        let scale = Double(shortSide) / Double(short)
        func even(_ v: Double) -> Int { max(2, Int((v / 2).rounded()) * 2) }
        return (even(Double(width) * scale), even(Double(height) * scale))
    }
}
