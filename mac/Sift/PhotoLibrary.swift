import AppKit
import Photos
import SiftCore
import UniformTypeIdentifiers

/// An album or folder in the Photos library, with the photos in it (a folder holds
/// everything in its albums and subfolders).
struct AlbumNode: Identifiable, Hashable {
    let id: String
    let title: String
    let isFolder: Bool
    var children: [AlbumNode]?
    var photoIDs: Set<String>
}

/// Sift's view of the Photos library, through PhotoKit: no Full Disk Access or AppleScript
/// needed, so it works inside the App Store's sandbox.
final class PhotoLibrary: @unchecked Sendable {
    private let manager = PHImageManager.default()
    private let cacheURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sift", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("fingerprints.json")
    }()

    // MARK: permission

    var status: PHAuthorizationStatus { PHPhotoLibrary.authorizationStatus(for: .readWrite) }

    func requestAccess() async -> PHAuthorizationStatus {
        await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    // MARK: reading the library

    private var imagesOnly: PHFetchOptions {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        options.includeAssetSourceTypes = [.typeUserLibrary]     // not shared albums: they don't use your storage
        options.includeAllBurstAssets = true                     // burst leftovers are worth finding
        return options
    }

    /// Every photo in the library, as Photos assets.
    func allPhotos() -> PHFetchResult<PHAsset> {
        PHAsset.fetchAssets(with: imagesOnly)
    }

    /// The details Sift compares photos by. Reading each photo's files' details is the slow
    /// part, so `progress` is called as it goes.
    func items(for assets: PHFetchResult<PHAsset>, only: Set<String>? = nil,
               progress: @escaping (Int, Int) -> Void) -> [PhotoItem] {
        var list: [PHAsset] = []
        assets.enumerateObjects { asset, _, _ in
            if only == nil || only!.contains(asset.localIdentifier) { list.append(asset) }
        }
        var items = [PhotoItem?](repeating: nil, count: list.count)
        let lock = NSLock()
        var done = 0
        DispatchQueue.concurrentPerform(iterations: list.count) { i in
            let item = Self.item(for: list[i])
            lock.lock()
            items[i] = item
            done += 1
            let finished = done
            lock.unlock()
            if finished % 100 == 0 || finished == list.count { progress(finished, list.count) }
        }
        return items.compactMap { $0 }
    }

    private static func item(for asset: PHAsset) -> PhotoItem {
        let resources = PHAssetResource.assetResources(for: asset)
        let original = resources.first { $0.type == .photo } ?? resources.first
        let size = (original?.value(forKey: "fileSize") as? Int64)
            ?? (original?.value(forKey: "fileSize") as? Int).map(Int64.init) ?? 0
        let isRAW = resources.contains { $0.type == .alternatePhoto }
            || (original.map { UTType($0.uniformTypeIdentifier)?.conforms(to: .rawImage) ?? false } ?? false)
        return PhotoItem(
            id: asset.localIdentifier,
            name: original?.originalFilename ?? "Photo",
            date: asset.creationDate,
            width: asset.pixelWidth,
            height: asset.pixelHeight,
            size: size,
            favorite: asset.isFavorite,
            edited: resources.contains { $0.type == .fullSizePhoto || $0.type == .adjustmentData },
            live: asset.mediaSubtypes.contains(.photoLive),
            burst: asset.burstIdentifier != nil,
            raw: isRAW,
            screenshot: asset.mediaSubtypes.contains(.photoScreenshot)
        )
    }

    /// The library's albums and folders that have photos in them, as Photos' sidebar
    /// shows them (folders first, then albums, alphabetically).
    func albums() -> [AlbumNode] {
        nodes(in: PHCollectionList.fetchTopLevelUserCollections(with: nil))
    }

    private func nodes(in collections: PHFetchResult<PHCollection>) -> [AlbumNode] {
        var folders: [AlbumNode] = [], albums: [AlbumNode] = []
        collections.enumerateObjects { collection, _, _ in
            if let list = collection as? PHCollectionList {
                let children = self.nodes(in: PHCollection.fetchCollections(in: list, options: nil))
                let ids = children.reduce(into: Set<String>()) { $0.formUnion($1.photoIDs) }
                if !ids.isEmpty {
                    folders.append(AlbumNode(id: list.localIdentifier, title: list.localizedTitle ?? "Folder",
                                             isFolder: true, children: children, photoIDs: ids))
                }
            } else if let album = collection as? PHAssetCollection {
                var ids = Set<String>()
                PHAsset.fetchAssets(in: album, options: self.imagesOnly).enumerateObjects { a, _, _ in
                    ids.insert(a.localIdentifier)
                }
                if !ids.isEmpty {
                    albums.append(AlbumNode(id: album.localIdentifier, title: album.localizedTitle ?? "Album",
                                            isFolder: false, children: nil, photoIDs: ids))
                }
            }
        }
        let byTitle = { (a: AlbumNode, b: AlbumNode) in a.title.localizedStandardCompare(b.title) == .orderedAscending }
        return folders.sorted(by: byTitle) + albums.sorted(by: byTitle)
    }

    // MARK: fingerprints

    /// Gives each photo its fingerprint, from Photos' small thumbnail (which exists even for
    /// photos stored only in iCloud). Fingerprints are remembered between scans.
    func fingerprint(_ items: inout [PhotoItem], progress: @escaping (Int, Int) -> Void) {
        var cache = loadCache()
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: items.map(\.id), options: nil)
        var byID: [String: PHAsset] = [:]
        assets.enumerateObjects { a, _, _ in byID[a.localIdentifier] = a }

        func key(_ a: PHAsset) -> String {
            "\(a.localIdentifier)|\(Int(a.modificationDate?.timeIntervalSince1970 ?? 0))"
        }
        var todo: [Int] = []
        for i in items.indices {
            guard let asset = byID[items[i].id] else { continue }
            if let cached = cache[key(asset)], cached.count == 4 { items[i].hash = cached } else { todo.append(i) }
        }
        let lock = NSLock()
        var done = 0
        var results = [Int: [UInt64]]()
        DispatchQueue.concurrentPerform(iterations: todo.count) { k in
            let i = todo[k]
            let asset = byID[items[i].id]!
            let hash = self.grayThumbnail(asset).flatMap { Fingerprint.hash(gray: $0.pixels, width: $0.width, height: $0.height) }
            lock.lock()
            if let hash { results[i] = hash; cache[key(asset)] = hash }
            done += 1
            let finished = done
            lock.unlock()
            if finished % 25 == 0 || finished == todo.count { progress(finished, todo.count) }
        }
        for (i, hash) in results { items[i].hash = hash }
        saveCache(cache)
    }

    /// A small greyscale version of a photo (no more than 160 pixels across), from the
    /// thumbnails Photos keeps on this Mac. Call it off the main thread.
    private func grayThumbnail(_ asset: PHAsset) -> (pixels: [UInt8], width: Int, height: Int)? {
        var result: CGImage?
        for mode in [PHImageRequestOptionsDeliveryMode.highQualityFormat, .fastFormat] {
            let options = PHImageRequestOptions()
            options.isSynchronous = true
            options.deliveryMode = mode
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = false
            manager.requestImage(for: asset, targetSize: CGSize(width: 256, height: 256),
                                 contentMode: .aspectFit, options: options) { image, _ in
                result = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
            }
            if result != nil { break }
        }
        guard let cg = result else { return nil }
        let scale = min(1, 160 / Double(max(cg.width, cg.height)))
        let w = max(1, Int(Double(cg.width) * scale)), h = max(1, Int(Double(cg.height) * scale))
        var pixels = [UInt8](repeating: 0, count: w * h)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return drawn ? (pixels, w, h) : nil
    }

    private func loadCache() -> [String: [UInt64]] {
        guard let data = try? Data(contentsOf: cacheURL) else { return [:] }
        return (try? JSONDecoder().decode([String: [UInt64]].self, from: data)) ?? [:]
    }

    private func saveCache(_ cache: [String: [UInt64]]) {
        if let data = try? JSONEncoder().encode(cache) { try? data.write(to: cacheURL, options: .atomic) }
    }

    // MARK: pictures to show

    /// A thumbnail to show in a grid. `done` may be called twice: quickly with a rough
    /// version, then with a sharp one. Returns the request, to cancel it.
    @discardableResult
    func thumbnail(_ id: String, side: CGFloat, done: @escaping (NSImage?) -> Void) -> PHImageRequestID? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else {
            done(nil); return nil
        }
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false
        return manager.requestImage(for: asset, targetSize: CGSize(width: side, height: side),
                                    contentMode: .aspectFill, options: options) { image, _ in done(image) }
    }

    /// The photo as it looks now (edits included) in full quality, for comparing copies.
    /// Photos downloads it from iCloud first if it isn't on this Mac; `progress` follows that.
    /// The Bool says whether it really is full quality.
    func fullImage(_ id: String, progress: @escaping (Double) -> Void) async -> (NSImage?, Bool) {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else {
            return (nil, false)
        }
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        options.isNetworkAccessAllowed = true
        options.progressHandler = { value, _, _, _ in DispatchQueue.main.async { progress(value) } }
        let side = CGFloat(min(4096, max(asset.pixelWidth, asset.pixelHeight)))
        return await withCheckedContinuation { continuation in
            manager.requestImage(for: asset, targetSize: CGSize(width: side, height: side),
                                 contentMode: .aspectFit, options: options) { image, info in
                let failed = info?[PHImageErrorKey] != nil || (info?[PHImageResultIsDegradedKey] as? Bool ?? false)
                continuation.resume(returning: (image, image != nil && !failed))
            }
        }
    }

    func cancel(_ request: PHImageRequestID) {
        manager.cancelImageRequest(request)
    }

    // MARK: videos

    /// Every video in the library, with what's needed to decide whether a smaller copy is
    /// worth making. (The frame rate is only known once a file is opened, so it's left out.)
    func videos(progress: @escaping (Int, Int) -> Void) -> [VideoItem] {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue)
        options.includeAssetSourceTypes = [.typeUserLibrary]
        var list: [PHAsset] = []
        PHAsset.fetchAssets(with: options).enumerateObjects { asset, _, _ in list.append(asset) }
        var items = [VideoItem?](repeating: nil, count: list.count)
        let lock = NSLock()
        var done = 0
        DispatchQueue.concurrentPerform(iterations: list.count) { i in
            let asset = list[i]
            let resources = PHAssetResource.assetResources(for: asset)
            let original = resources.first { $0.type == .video } ?? resources.first
            let size = (original?.value(forKey: "fileSize") as? Int64)
                ?? (original?.value(forKey: "fileSize") as? Int).map(Int64.init) ?? 0
            let item = VideoItem(
                id: asset.localIdentifier,
                name: original?.originalFilename ?? "Video",
                date: asset.creationDate,
                width: asset.pixelWidth,
                height: asset.pixelHeight,
                size: size,
                duration: asset.duration,
                favorite: asset.isFavorite,
                slowMo: asset.mediaSubtypes.contains(.videoHighFrameRate),
                timeLapse: asset.mediaSubtypes.contains(.videoTimelapse),
                edited: resources.contains { $0.type == .fullSizeVideo || $0.type == .adjustmentData }
            )
            lock.lock()
            items[i] = item
            done += 1
            let finished = done
            lock.unlock()
            if finished % 50 == 0 || finished == list.count { progress(finished, list.count) }
        }
        return items.compactMap { $0 }
    }

    // MARK: deleting

    /// Deletes photos or videos. macOS asks the person to confirm first; deleted items go to
    /// Recently Deleted for 30 days. Returns false if they cancelled or it failed.
    func delete(_ ids: [String]) async -> Bool {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        guard assets.count > 0 else { return false }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(assets)
            }
            return true
        } catch {
            return false
        }
    }
}
