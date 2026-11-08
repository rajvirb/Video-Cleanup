import AVFoundation
import Photos
import SiftCore
import VideoToolbox

enum CompressionError: LocalizedError {
    case notAvailable, noVideo, failed(String), notSmaller, wrongLength

    var errorDescription: String? {
        switch self {
        case .notAvailable: "Photos couldn't provide the original (it may need downloading from iCloud while you're online)."
        case .noVideo: "It has no video track Sift can read."
        case .failed(let why): why
        case .notSmaller: "The copy wouldn't have been much smaller, so it was left as it is."
        case .wrongLength: "The copy came out a different length, so it wasn't kept."
        }
    }
}

/// Makes a smaller HEVC copy of a video with AVFoundation (the Mac's hardware encoder),
/// keeping its metadata, and saves it into Photos next to the original.
final class VideoCompressor: @unchecked Sendable {
    static let albumCopies = "Sift - Compressed Versions"
    static let albumOriginals = "Sift - Original Videos"
    static let albumCompare = "Sift - Original & Compressed Comparison"

    private var cancelled = false
    private var writer: AVAssetWriter?
    private var reader: AVAssetReader?

    /// Stops the copy being made. Reading stops, so the encoder winds down normally and the
    /// half-made copy is thrown away (cancelling the writer itself mid-way can leave it waiting).
    func cancel() {
        cancelled = true
        reader?.cancelReading()
    }

    /// What happened to one video's copy.
    struct Made {
        let photosID: String?       // the copy in Photos, if it was saved there
        let size: Int64
        let file: URL?              // the copy in the comparison folder, if it was saved there
    }

    /// The copy's name: the original's, with " - sift compression" before the extension.
    static func copyName(_ original: String) -> String {
        let url = URL(fileURLWithPath: original)
        let ext = url.pathExtension.isEmpty ? "mov" : url.pathExtension
        return "\(url.deletingPathExtension().lastPathComponent) - sift compression.\(ext)"
    }

    /// Makes the copy, and saves it to Photos and/or into `folder` next to a copy of the
    /// original. `progress` goes from 0 to 1 (downloading from iCloud counts as the first tenth).
    func compress(_ id: String, mode: CompressionMode, toPhotos: Bool, folder: URL?, library: PhotoLibrary,
                  progress: @escaping @Sendable (Double) -> Void) async throws -> Made {
        guard let original = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject,
              let asset = await originalAsset(original, progress: { progress($0 * 0.1) }) else {
            throw CompressionError.notAvailable
        }
        let originalName = PHAssetResource.assetResources(for: original).first { $0.type == .video }?.originalFilename ?? "Video.mov"
        let name = Self.copyName(originalName)
        let workDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        let url = workDir.appendingPathComponent(name)
        defer { try? FileManager.default.removeItem(at: workDir) }
        let sourceSize = (try? (asset as? AVURLAsset)?.url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }
        try await encode(asset, to: url, mode: mode) { progress(0.1 + $0 * 0.85) }

        // check the result before trusting it
        let copy = AVURLAsset(url: url)
        let (inLength, outLength) = (try await asset.load(.duration).seconds, try await copy.load(.duration).seconds)
        if abs(inLength - outLength) > max(0.6, 0.01 * inLength) { throw CompressionError.wrongLength }
        let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        if let sourceSize, Double(size) > 0.85 * Double(sourceSize) { throw CompressionError.notSmaller }

        // into the comparison folder: the copy, next to a copy of the original
        var file: URL?
        if let folder {
            let destination = PhotoLibrary.unused(folder.appendingPathComponent(name))
            try FileManager.default.copyItem(at: url, to: destination)
            file = destination
            _ = try await library.exportOriginal(id, to: folder)
        }
        let newID = toPhotos ? try await save(url, like: original, name: name) : nil
        progress(1)
        return Made(photosID: newID, size: size, file: file)
    }

    /// Makes a smaller copy of a video file and saves it next to the original, named
    /// "<name> - sift compression.<ext>".
    func compressFile(_ source: URL, mode: CompressionMode, progress: @escaping @Sendable (Double) -> Void) async throws -> Made {
        let asset = AVURLAsset(url: source)
        let name = Self.copyName(source.lastPathComponent)
        let workDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        let url = workDir.appendingPathComponent(name)
        defer { try? FileManager.default.removeItem(at: workDir) }
        try await encode(asset, to: url, mode: mode) { progress($0 * 0.95) }

        let copy = AVURLAsset(url: url)
        let (inLength, outLength) = (try await asset.load(.duration).seconds, try await copy.load(.duration).seconds)
        if abs(inLength - outLength) > max(0.6, 0.01 * inLength) { throw CompressionError.wrongLength }
        let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let sourceSize = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if sourceSize > 0, Double(size) > 0.85 * Double(sourceSize) { throw CompressionError.notSmaller }

        let destination = PhotoLibrary.unused(source.deletingLastPathComponent().appendingPathComponent(name))
        try FileManager.default.copyItem(at: url, to: destination)
        progress(1)
        return Made(photosID: nil, size: size, file: destination)
    }

    // MARK: getting the original

    private func originalAsset(_ original: PHAsset, progress: @escaping @Sendable (Double) -> Void) async -> AVAsset? {
        let options = PHVideoRequestOptions()
        options.version = .original
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true                 // download it from iCloud if need be
        options.progressHandler = { value, _, _, _ in progress(value) }
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestAVAsset(forVideo: original, options: options) { asset, _, _ in
                continuation.resume(returning: asset)
            }
        }
    }

    // MARK: re-encoding

    private func encode(_ asset: AVAsset, to url: URL, mode: CompressionMode,
                        progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else { throw CompressionError.noVideo }
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let duration = try await asset.load(.duration).seconds
        let natural = try await videoTrack.load(.naturalSize)
        let fps = Double(try await videoTrack.load(.nominalFrameRate))
        let format = try await videoTrack.load(.formatDescriptions).first

        // 10-bit (HDR) video stays 10-bit, with its colour information
        let bits = format.flatMap { CMFormatDescriptionGetExtension($0, extensionKey: kCMFormatDescriptionExtension_BitsPerComponent) as? Int }
        let transfer = format.flatMap { CMFormatDescriptionGetExtension($0, extensionKey: kCVImageBufferTransferFunctionKey) as? String }
        let tenBit = bits == 10 || [kCVImageBufferTransferFunction_ITU_R_2100_HLG, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ]
            .map { $0 as String }.contains(transfer ?? "")

        let width = Int(abs(natural.width)), height = Int(abs(natural.height))
        let short = mode == .cap1080p ? min(min(width, height), 1080) : min(width, height)
        let out = Compression.outputSize(width: width, height: height, shortSide: short)
        let kbps = Compression.targetKbps(shortSide: short, fps: fps)

        let mp4 = ["mp4", "m4v"].contains(url.pathExtension.lowercased())
        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: url, fileType: mp4 ? .mp4 : .mov)
        self.reader = reader
        self.writer = writer
        writer.metadata = metadata(try await asset.load(.metadata))   // camera make and model, place, date

        let pixelFormat = tenBit ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let videoOut = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat])
        videoOut.alwaysCopiesSampleData = false
        reader.add(videoOut)

        var settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: out.width,
            AVVideoHeightKey: out.height,
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspectFill,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: kbps * 1000,
                AVVideoExpectedSourceFrameRateKey: fps > 0 ? fps : 30,
                AVVideoProfileLevelKey: (tenBit ? kVTProfileLevel_HEVC_Main10_AutoLevel : kVTProfileLevel_HEVC_Main_AutoLevel) as String,
            ] as [String: Any],
        ]
        if let format, let primaries = CMFormatDescriptionGetExtension(format, extensionKey: kCVImageBufferColorPrimariesKey),
           let transfer = CMFormatDescriptionGetExtension(format, extensionKey: kCVImageBufferTransferFunctionKey),
           let matrix = CMFormatDescriptionGetExtension(format, extensionKey: kCVImageBufferYCbCrMatrixKey) {
            settings[AVVideoColorPropertiesKey] = [AVVideoColorPrimariesKey: primaries, AVVideoTransferFunctionKey: transfer,
                                                   AVVideoYCbCrMatrixKey: matrix]
        }
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        videoIn.transform = try await videoTrack.load(.preferredTransform)       // keeps portrait videos upright
        videoIn.metadata = metadata(try await videoTrack.load(.metadata))  // the lens
        videoIn.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoIn) else { throw CompressionError.failed("The Mac's HEVC encoder couldn't take this video.") }
        writer.add(videoIn)

        // sound is copied as it is
        var audioPairs: [(AVAssetReaderTrackOutput, AVAssetWriterInput)] = []
        for track in audioTracks {
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            let hint = try await track.load(.formatDescriptions).first
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: hint)
            input.expectsMediaDataInRealTime = false
            if reader.canAdd(output) && writer.canAdd(input) {
                reader.add(output)
                writer.add(input)
                audioPairs.append((output, input))
            }
        }

        if !writer.startWriting() {
            // an MP4 can't always hold an iPhone's QuickTime metadata: try once more without it
            guard mp4, !writer.metadata.isEmpty else {
                throw CompressionError.failed(writer.error?.localizedDescription ?? "Couldn't start writing.")
            }
            try? FileManager.default.removeItem(at: url)
            return try await encodeWithoutMetadata(asset, to: url, mode: mode, progress: progress)
        }
        guard reader.startReading() else { throw CompressionError.failed(reader.error?.localizedDescription ?? "Couldn't read the video.") }
        writer.startSession(atSourceTime: .zero)

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await Self.pump(videoOut, into: videoIn, label: "video") { time in
                if duration > 0 { progress(min(1, time / duration)) }
            } }
            for (output, input) in audioPairs {
                group.addTask { await Self.pump(output, into: input, label: "audio") { _ in } }
            }
        }

        if cancelled {
            writer.cancelWriting()
            throw CancellationError()
        }
        if reader.status == .failed { throw CompressionError.failed(reader.error?.localizedDescription ?? "Reading the video failed.") }
        await writer.finishWriting()
        if writer.status != .completed {
            throw CompressionError.failed(writer.error?.localizedDescription ?? "Writing the copy failed.")
        }
    }

    private var skipMetadata = false

    private func encodeWithoutMetadata(_ asset: AVAsset, to url: URL, mode: CompressionMode,
                                       progress: @escaping @Sendable (Double) -> Void) async throws {
        skipMetadata = true
        defer { skipMetadata = false }
        try await encode(asset, to: url, mode: mode, progress: progress)
    }

    /// The metadata a QuickTime file can hold (which is all of an iPhone video's).
    private static func quickTime(_ items: [AVMetadataItem]) -> [AVMetadataItem] {
        items.filter { $0.keySpace == .quickTimeMetadata || $0.keySpace == .quickTimeUserData }
    }

    private func metadata(_ items: [AVMetadataItem]) -> [AVMetadataItem] {
        skipMetadata ? [] : Self.quickTime(items)
    }

    /// Feeds one track's samples from the reader to the writer until it runs out.
    private static func pump(_ output: AVAssetReaderTrackOutput, into input: AVAssetWriterInput, label: String,
                             progress: @escaping (Double) -> Void) async {
        let queue = DispatchQueue(label: "sift.\(label)")
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var finished = false
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData && !finished {
                    if let sample = output.copyNextSampleBuffer() {
                        if !input.append(sample) {
                            finished = true
                        } else {
                            progress(CMSampleBufferGetPresentationTimeStamp(sample).seconds)
                        }
                    } else {
                        finished = true
                    }
                }
                if finished {
                    input.markAsFinished()
                    continuation.resume()
                }
            }
        }
    }

    // MARK: saving to Photos

    /// Adds the copy to Photos with the original's date, place and favourite status, in the
    /// same albums, and in Sift's albums for comparing (the original goes in those too).
    private func save(_ url: URL, like original: PHAsset, name: String) async throws -> String {
        let copies = try await album(Self.albumCopies)
        let originals = try await album(Self.albumOriginals)
        let compare = try await album(Self.albumCompare)
        let theirAlbums = PHAssetCollection.fetchAssetCollectionsContaining(original, with: .album, options: nil)
        var newID = ""
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.shouldMoveFile = false             // the folder copy may still need it
            options.originalFilename = name             // "IMG_1234 - sift compression.MOV"
            request.addResource(with: .video, fileURL: url, options: options)
            request.creationDate = original.creationDate
            request.location = original.location
            request.isFavorite = original.isFavorite
            guard let placeholder = request.placeholderForCreatedAsset else { return }
            newID = placeholder.localIdentifier
            theirAlbums.enumerateObjects { album, _, _ in
                if album.canPerform(.addContent) {
                    PHAssetCollectionChangeRequest(for: album)?.addAssets([placeholder] as NSArray)
                }
            }
            PHAssetCollectionChangeRequest(for: copies)?.addAssets([placeholder] as NSArray)
            PHAssetCollectionChangeRequest(for: originals)?.addAssets([original] as NSArray)
            // added as a pair, so each original sits next to its copy
            PHAssetCollectionChangeRequest(for: compare)?.addAssets([original, placeholder] as NSArray)
        }
        return newID
    }

    /// An album of Sift's, made if it isn't there yet.
    private func album(_ title: String) async throws -> PHAssetCollection {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "title == %@", title)
        if let found = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: options).firstObject {
            return found
        }
        var id = ""
        try await PHPhotoLibrary.shared().performChanges {
            id = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title)
                .placeholderForCreatedAssetCollection.localIdentifier
        }
        guard let made = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject else {
            throw CompressionError.failed("Couldn't make the album “\(title)”.")
        }
        return made
    }
}
