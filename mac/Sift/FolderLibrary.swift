import AppKit
import AVFoundation
import ImageIO
import QuickLookThumbnailing
import SiftCore
import UniformTypeIdentifiers

/// Folders of photos and videos on this Mac, an external drive, a Google Takeout export or
/// a Google Drive folder, chosen by the person. Items are identified by their file path.
/// Deleting moves files to the Bin.
final class FolderLibrary: @unchecked Sendable {
    private(set) var folders: [URL] = []
    private static let bookmarksKey = "folderBookmarks"
    private let cacheDir: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sift", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    init() {
        restore()
    }

    // MARK: the chosen folders

    func add(_ url: URL) {
        guard !folders.contains(url) else { return }
        _ = url.startAccessingSecurityScopedResource()       // kept open while Sift runs
        folders.append(url)
        save()
    }

    func remove(_ url: URL) {
        url.stopAccessingSecurityScopedResource()
        folders.removeAll { $0 == url }
        save()
    }

    private func save() {
        let bookmarks = folders.compactMap {
            try? $0.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        }
        UserDefaults.standard.set(bookmarks, forKey: Self.bookmarksKey)
    }

    private func restore() {
        let bookmarks = UserDefaults.standard.array(forKey: Self.bookmarksKey) as? [Data] ?? []
        for data in bookmarks {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil,
                                  bookmarkDataIsStale: &stale) {
                _ = url.startAccessingSecurityScopedResource()
                folders.append(url)
            }
        }
    }

    // MARK: finding files

    enum Kind { case images, videos }

    /// Every image (or video) file in the chosen folders and the folders inside them.
    func files(_ kind: Kind, in only: [URL]? = nil) -> [URL] {
        let type: UTType = kind == .images ? .image : .movie
        var found: [URL] = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentTypeKey]
        for folder in only ?? folders {
            guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys,
                                                              options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in walker {
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                      let content = values.contentType, content.conforms(to: type) else { continue }
                found.append(url)
            }
        }
        return found
    }

    // MARK: photos

    /// The photos in the chosen folders, with their fingerprints (remembered between scans).
    func photoItems(progress: @escaping (Int, Int) -> Void) -> [PhotoItem] {
        let files = files(.images)
        var cache = load([String: [UInt64]].self, "folder-fingerprints.json") ?? [:]
        var items = [PhotoItem?](repeating: nil, count: files.count)
        var hashes = [String: [UInt64]]()
        let lock = NSLock()
        var done = 0
        let snapshot = cache
        DispatchQueue.concurrentPerform(iterations: files.count) { i in
            let url = files[i]
            let key = Self.key(url)
            var item = Self.photoItem(url)
            if var made = item {
                if let cached = snapshot[key] { made.hash = cached } else {
                    made.hash = Self.photoHash(url)
                    if let hash = made.hash { lock.lock(); hashes[key] = hash; lock.unlock() }
                }
                item = made
            }
            lock.lock()
            items[i] = item
            done += 1
            let finished = done
            lock.unlock()
            if finished % 25 == 0 || finished == files.count { progress(finished, files.count) }
        }
        cache.merge(hashes) { _, new in new }
        store(cache, "folder-fingerprints.json")
        return items.compactMap { $0 }
    }

    private static func photoItem(_ url: URL) -> PhotoItem? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        var width = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        var height = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        if let orientation = props[kCGImagePropertyOrientation] as? Int, (5...8).contains(orientation) {
            swap(&width, &height)                                  // stored on its side
        }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let taken = captureDate(exif?[kCGImagePropertyExifDateTimeOriginal] as? String,
                                subseconds: exif?[kCGImagePropertyExifSubsecTimeOriginal] as? String)
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey, .contentTypeKey])
        return PhotoItem(
            id: url.path,
            name: url.lastPathComponent,
            date: taken ?? values?.creationDate,
            width: width,
            height: height,
            size: Int64(values?.fileSize ?? 0),
            raw: values?.contentType?.conforms(to: .rawImage) ?? false
        )
    }

    private static func photoHash(_ url: URL) -> [UInt64]? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 256,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let gray = PhotoLibrary.gray(thumb, maxSide: 160) else { return nil }
        return Fingerprint.hash(gray: gray.pixels, width: gray.width, height: gray.height)
    }

    /// "2024:07:14 18:22:05" (and ".37") from a photo's metadata, in this Mac's time zone.
    private static func captureDate(_ text: String?, subseconds: String?) -> Date? {
        guard let text else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        guard let date = formatter.date(from: text) else { return nil }
        if let subseconds, let fraction = Double("0." + subseconds) { return date.addingTimeInterval(fraction) }
        return date
    }

    // MARK: videos

    /// The videos in the chosen folders.
    func videoItems(progress: @escaping (Int, Int) -> Void) async -> [VideoItem] {
        let files = files(.videos)
        var items: [VideoItem] = []
        for (k, url) in files.enumerated() {
            let asset = AVURLAsset(url: url)
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey])
            let duration = (try? await asset.load(.duration).seconds) ?? 0
            var width = 0, height = 0
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let size = try? await track.load(.naturalSize), let transform = try? await track.load(.preferredTransform) {
                let shown = size.applying(transform)
                width = Int(abs(shown.width)); height = Int(abs(shown.height))
            }
            let made = (try? await asset.load(.creationDate))?.dateValue
            items.append(VideoItem(id: url.path, name: url.lastPathComponent, date: made ?? values?.creationDate,
                                   width: width, height: height, size: Int64(values?.fileSize ?? 0), duration: duration))
            if (k + 1) % 10 == 0 || k + 1 == files.count { progress(k + 1, files.count) }
        }
        return items
    }

    /// Fingerprints of frames through each video, remembered between scans.
    func videoFingerprints(_ ids: [String], progress: @escaping (Int, Int) -> Void) async -> [String: (frames: [UInt64], poster: UInt64?)] {
        var cache = load([String: [UInt64]].self, "folder-video-fingerprints.json") ?? [:]
        var results: [String: (frames: [UInt64], poster: UInt64?)] = [:]
        var todo: [URL] = []
        for id in ids {
            let url = URL(fileURLWithPath: id)
            if let cached = cache[Self.key(url)] { results[id] = (cached, nil) } else { todo.append(url) }
        }
        var done = 0
        await withTaskGroup(of: (URL, [UInt64]).self) { group in
            var next = 0
            func start() {
                guard next < todo.count else { return }
                let url = todo[next]
                next += 1
                group.addTask {
                    let asset = AVURLAsset(url: url)
                    let duration = (try? await asset.load(.duration).seconds) ?? 0
                    return (url, await VideoFrames.hashes(asset, duration: duration))
                }
            }
            for _ in 0..<4 { start() }
            for await (url, frames) in group {
                results[url.path] = (frames, nil)
                cache[Self.key(url)] = frames
                done += 1
                progress(done, todo.count)
                start()
            }
        }
        store(cache, "folder-video-fingerprints.json")
        return results
    }

    // MARK: caches

    /// A file's cache key: its path, size and when it last changed.
    private static func key(_ url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return "\(url.path)|\(values?.fileSize ?? 0)|\(Int(values?.contentModificationDate?.timeIntervalSince1970 ?? 0))"
    }

    private func load<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        guard let data = try? Data(contentsOf: cacheDir.appendingPathComponent(name)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func store<T: Encodable>(_ value: T, _ name: String) {
        if let data = try? JSONEncoder().encode(value) {
            try? data.write(to: cacheDir.appendingPathComponent(name), options: .atomic)
        }
    }
}

extension FolderLibrary: MediaProvider {
    func thumbnail(_ id: String, side: CGFloat, done: @escaping (NSImage?) -> Void) -> (() -> Void)? {
        let request = QLThumbnailGenerator.Request(fileAt: URL(fileURLWithPath: id), size: CGSize(width: side, height: side),
                                                   scale: 2, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { thumbnail, _ in
            let image = thumbnail?.nsImage
            DispatchQueue.main.async { done(image) }
        }
        return { QLThumbnailGenerator.shared.cancel(request) }
    }

    func fullImage(_ id: String, progress: @escaping (Double) -> Void) async -> (NSImage?, Bool) {
        let url = URL(fileURLWithPath: id)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return (nil, false) }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 4096,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return (nil, false) }
        return (NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)), true)
    }

    func playerItem(_ id: String) async -> AVPlayerItem? {
        AVPlayerItem(url: URL(fileURLWithPath: id))
    }

    /// Moves files to the Bin, where they can be put back.
    func delete(_ ids: [String]) async -> Bool {
        var moved = 0
        for id in ids where (try? FileManager.default.trashItem(at: URL(fileURLWithPath: id), resultingItemURL: nil)) != nil {
            moved += 1
        }
        return moved > 0
    }

    var canDelete: Bool { true }
    var deleteNote: String {
        "They'll be moved to the Bin, so you can still put them back until you empty it."
    }
}
