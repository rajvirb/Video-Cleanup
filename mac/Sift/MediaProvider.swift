import AppKit
import AVFoundation
import Photos
import SiftCore

/// Where the photos and videos on screen come from (Apple Photos, folders on this Mac or
/// Google Photos), as the screens need it.
protocol MediaProvider: AnyObject {
    /// A thumbnail. `done` may be called more than once (rough, then sharp), on the main
    /// thread. Returns something that cancels it.
    func thumbnail(_ id: String, side: CGFloat, done: @escaping (NSImage?) -> Void) -> (() -> Void)?
    /// The photo in full quality, and whether it really is full quality.
    func fullImage(_ id: String, progress: @escaping (Double) -> Void) async -> (NSImage?, Bool)
    /// Something to play a video with.
    func playerItem(_ id: String) async -> AVPlayerItem?
    /// Deletes items: false if the person cancelled, it failed, or this source can't delete.
    func delete(_ ids: [String]) async -> Bool
    /// Whether Sift can delete from this source.
    var canDelete: Bool { get }
    /// Where deleted items go, for the summary before deleting.
    var deleteNote: String { get }
}

extension PhotoLibrary: MediaProvider {
    func thumbnail(_ id: String, side: CGFloat, done: @escaping (NSImage?) -> Void) -> (() -> Void)? {
        let request: PHImageRequestID? = thumbnail(id, side: side, done)
        guard let request else { return nil }
        return { [weak self] in self?.cancel(request) }
    }

    func playerItem(_ id: String) async -> AVPlayerItem? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { return nil }
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .automatic
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestPlayerItem(forVideo: asset, options: options) { item, _ in
                continuation.resume(returning: item)
            }
        }
    }

    var canDelete: Bool { true }
    var deleteNote: String {
        "macOS will ask you to confirm next. Deleted items stay in Photos' Recently Deleted album for 30 days, so you can still get them back."
    }
}

/// Fingerprints of frames taken through a video, for finding copies of it.
enum VideoFrames {
    static func hashes(_ video: AVAsset, duration: Double) async -> [UInt64] {
        let generator = AVAssetImageGenerator(asset: video)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 96, height: 96)
        let tolerance = CMTime(seconds: 0.1, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        let times = VideoMatcher.frameTimes(duration: duration).map { CMTime(seconds: $0, preferredTimescale: 600) }
        var hashes: [UInt64] = []
        for await result in generator.images(for: times) {
            guard let image = try? result.image, let gray = PhotoLibrary.gray(image, maxSide: 96),
                  let hash = Fingerprint.frameHash(gray: gray.pixels, width: gray.width, height: gray.height) else { continue }
            hashes.append(hash)
        }
        return hashes
    }
}
