import AppKit
import Photos
import SiftCore
import SwiftUI

/// What the window is showing, and everything the screens share.
@MainActor
final class AppModel: ObservableObject {
    enum Stage { case welcome, noAccess, start, scanning, results, videos, compressing, compressed }
    enum Job: Hashable { case photos, videos }
    enum Scope: Hashable { case everything, albums }
    enum SortOrder: String, CaseIterable, Identifiable {
        case space = "Most space saved first", count = "Largest sets first"
        case oldest = "Oldest first", newest = "Newest first"
        var id: String { rawValue }
    }

    let library = PhotoLibrary()

    @Published var stage: Stage = .welcome
    @Published var job: Job = .photos
    // what to scan
    @Published var totalPhotos = 0
    @Published var albums: [AlbumNode] = []
    @Published var loadingAlbums = false
    @Published var scope: Scope = .everything
    @Published var chosenAlbums: Set<String> = []
    @Published var strictness: Strictness = .balanced
    // scanning
    @Published var stepTitle = ""
    @Published var stepDone = 0
    @Published var stepTotal = 0
    @Published var stepDetail = ""
    private var stepStarted = Date()
    private var scanTask: Task<Void, Never>?
    // results
    @Published var items: [PhotoItem] = []
    @Published var sets: [DuplicateSet] = []
    @Published var marked: Set<String> = []
    @Published var sortOrder: SortOrder = .space { didSet { sortSets() } }
    @Published var message: String?           // a note at the top of the results, after deleting
    @Published var comparing: Int?            // the set open in the compare view
    @Published var deleting = false
    // Sift's own summary, shown before macOS's confirmation whenever something is to be deleted
    @Published var pendingDelete: PendingDelete?
    // videos to make smaller
    @Published var candidates: [VideoCandidate] = []
    @Published var compressionMode: CompressionMode = .sameResolution
    @Published var chosenVideos: Set<String> = []
    @Published var compressName = ""
    @Published var compressIndex = 0
    @Published var compressTotal = 0
    @Published var compressFraction = 0.0
    @Published var compressDetail = ""
    @Published var compressResults: [CompressResult] = []
    @Published var originalsDeleted = false
    private var compressor: VideoCompressor?
    private var compressStarted = Date()

    // MARK: getting started

    func begin() async {
        var status = library.status
        if status == .notDetermined { status = await library.requestAccess() }
        guard status == .authorized || status == .limited else {
            stage = .noAccess
            return
        }
        totalPhotos = library.allPhotos().count
        stage = .start
        loadingAlbums = true
        let library = self.library
        let found = await Task.detached(priority: .userInitiated) { library.albums() }.value
        albums = found
        loadingAlbums = false
    }

    var chosenPhotoIDs: Set<String> {
        var ids = Set<String>()
        func walk(_ nodes: [AlbumNode]) {
            for node in nodes {
                if chosenAlbums.contains(node.id) { ids.formUnion(node.photoIDs) } else { walk(node.children ?? []) }
            }
        }
        walk(albums)
        return ids
    }

    var canScan: Bool { scope == .everything || !chosenPhotoIDs.isEmpty }

    // MARK: scanning

    func scan() {
        stage = .scanning
        message = nil
        let library = self.library
        let only = scope == .albums ? chosenPhotoIDs : nil
        let strictness = self.strictness
        scanTask = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.step("Reading your library…")
            var items = library.items(for: library.allPhotos(), only: only) { done, total in
                Task { @MainActor in self?.progress(done, total, "Reading") }
            }
            if Task.isCancelled { return }
            await self?.step("Fingerprinting \(Format.plural(items.count, "photo"))…")
            library.fingerprint(&items) { done, total in
                Task { @MainActor in self?.progress(done, total, "Fingerprinting") }
            }
            if Task.isCancelled { return }
            await self?.step("Looking for duplicates and similar shots…")
            let matches = Matcher.findPhotoMatches(items, strictness: strictness) { done, total in
                Task { @MainActor in self?.progress(done, total, "Comparing") }
            }
            let sets = Grouping.buildSets(items, matches: matches)
            if Task.isCancelled { return }
            await self?.finish(items: items, sets: sets)
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        stage = .start
    }

    func startJob() {
        if job == .photos { scan() } else { findVideos() }
    }

    private func step(_ title: String) {
        stepTitle = title
        stepDone = 0
        stepTotal = 0
        stepDetail = ""
        stepStarted = Date()
    }

    private func progress(_ done: Int, _ total: Int, _ label: String) {
        guard stage == .scanning else { return }
        stepDone = done
        stepTotal = total
        var detail = "\(label) · \(done.formatted()) of \(total.formatted())"
        if let left = Format.timeLeft(spent: Date().timeIntervalSince(stepStarted), done: done, total: total) {
            detail += " · \(left)"
        }
        stepDetail = detail
    }

    private func finish(items: [PhotoItem], sets: [DuplicateSet]) {
        self.items = items
        self.sets = sets
        marked = []
        sortSets()
        stage = .results
    }

    // MARK: results

    var savingSuggested: Int64 { sets.reduce(0) { $0 + $1.saving(items) } }
    var deleteSuggested: Int { sets.reduce(0) { $0 + $1.members.filter { $0.suggestion == .delete }.count } }
    var reviewSuggested: Int { sets.reduce(0) { $0 + $1.members.filter { $0.suggestion == .review }.count } }
    var markedSize: Int64 { items.filter { marked.contains($0.id) }.reduce(0) { $0 + $1.size } }

    func toggle(_ id: String) {
        if marked.contains(id) { marked.remove(id) } else { marked.insert(id) }
    }

    /// Marks the copies Sift is sure about. Ones it only marked for review (bursts,
    /// look-alikes) are never selected for you.
    func selectSuggested(in only: [DuplicateSet]? = nil) {
        for set in only ?? sets {
            for member in set.members where member.suggestion == .delete { marked.insert(items[member.index].id) }
        }
    }

    func keepAll(_ set: DuplicateSet) {
        for member in set.members { marked.remove(items[member.index].id) }
    }

    func keepOnly(_ index: Int, in set: DuplicateSet) {
        for member in set.members {
            if member.index == index { marked.remove(items[index].id) } else { marked.insert(items[member.index].id) }
        }
    }

    /// Sets where every photo is marked, so none would be kept.
    func setsWithNothingKept(_ ids: Set<String>) -> Int {
        sets.filter { set in set.members.allSatisfy { ids.contains(items[$0.index].id) } }.count
    }

    /// Shows Sift's summary of what's about to be deleted. Nothing happens until the person
    /// confirms it, and then macOS asks them to confirm as well.
    func requestDelete(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        let entries = items.filter { ids.contains($0.id) }.map {
            DeleteEntry(id: $0.id, name: $0.name, size: $0.size, favorite: $0.favorite, edited: $0.edited,
                        live: $0.live, raw: $0.raw, isVideo: false)
        }
        pendingDelete = PendingDelete(kind: .photos, entries: entries, nothingKept: setsWithNothingKept(ids))
    }

    func confirmDelete(_ pending: PendingDelete) async {
        pendingDelete = nil
        switch pending.kind {
        case .photos: await delete(Set(pending.entries.map(\.id)))
        case .videoOriginals: await deleteOriginals(Set(pending.entries.map(\.id)))
        }
    }

    /// Deletes photos (macOS asks to confirm), then takes them out of the results.
    private func delete(_ ids: Set<String>) async {
        guard !ids.isEmpty else { return }
        deleting = true
        defer { deleting = false }
        let size = items.filter { ids.contains($0.id) }.reduce(Int64(0)) { $0 + $1.size }
        guard await library.delete(Array(ids)) else { return }
        marked.subtract(ids)
        sets = sets.compactMap { set -> DuplicateSet? in
            let left = set.members.filter { !ids.contains(items[$0.index].id) }
            return left.count > 1 ? DuplicateSet(members: left) : nil   // sets of one are done
        }
        if let open = comparing, open >= sets.count { comparing = sets.isEmpty ? nil : sets.count - 1 }
        message = "Deleted \(Format.plural(ids.count, "photo")) (\(Format.size(size))). They're in Recently Deleted "
            + "in Photos for 30 days. To free the space now, empty Recently Deleted."
    }

    // MARK: videos

    /// Finds the videos a smaller copy is worth making of.
    func findVideos() {
        stage = .scanning
        message = nil
        originalsDeleted = false
        let library = self.library
        scanTask = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.step("Reading your videos…")
            let videos = library.videos { done, total in
                Task { @MainActor in self?.progress(done, total, "Reading") }
            }
            let candidates = videos.compactMap { video -> VideoCandidate? in
                let same = Compression.plan(video, mode: .sameResolution)
                let hd = Compression.plan(video, mode: .cap1080p)
                return same == nil && hd == nil ? nil : VideoCandidate(video: video, same: same, hd: hd)
            }
            .sorted { ($0.same ?? $0.hd!).saving($0.video) > ($1.same ?? $1.hd!).saving($1.video) }
            if Task.isCancelled { return }
            await self?.showCandidates(candidates)
        }
    }

    private func showCandidates(_ found: [VideoCandidate]) {
        candidates = found
        chosenVideos = Set(found.filter { $0.plan(compressionMode) != nil }.map(\.id))
        stage = .videos
    }

    /// The videos that will be made smaller at the chosen setting.
    var videosToCompress: [VideoCandidate] {
        candidates.filter { chosenVideos.contains($0.id) && $0.plan(compressionMode) != nil }
    }

    var compressionSaving: Int64 {
        videosToCompress.reduce(0) { $0 + ($1.plan(compressionMode)?.saving($1.video) ?? 0) }
    }

    func compressVideos() {
        let todo = videosToCompress
        guard !todo.isEmpty else { return }
        stage = .compressing
        compressResults = []
        compressTotal = todo.count
        compressStarted = Date()
        let mode = compressionMode
        let compressor = VideoCompressor()
        self.compressor = compressor
        scanTask = Task { [weak self] in
            for (k, candidate) in todo.enumerated() {
                guard let self, !Task.isCancelled else { break }
                self.compressIndex = k + 1
                self.compressName = candidate.video.name
                self.compressFraction = 0
                do {
                    let (newID, size) = try await compressor.compress(candidate.id, mode: mode) { value in
                        Task { @MainActor [weak self] in self?.updateCompressProgress(k, of: todo.count, value) }
                    }
                    self.compressResults.append(CompressResult(video: candidate.video, newID: newID, newSize: size, problem: nil))
                } catch is CancellationError {
                    break
                } catch {
                    self.compressResults.append(CompressResult(video: candidate.video, newID: nil, newSize: nil,
                                                               problem: error.localizedDescription))
                }
            }
            self?.stage = .compressed
        }
    }

    private func updateCompressProgress(_ k: Int, of total: Int, _ value: Double) {
        compressFraction = value
        let overall = (Double(k) + value) / Double(total)
        var detail = "\(compressIndex) of \(total)"
        if let left = Format.timeLeft(spent: Date().timeIntervalSince(compressStarted), done: Int(overall * 1000), total: 1000) {
            detail += " · \(left)"
        }
        compressDetail = detail
    }

    func cancelCompressing() {
        compressor?.cancel()
        scanTask?.cancel()
    }

    var compressedOK: [CompressResult] { compressResults.filter { $0.newID != nil } }
    var compressedSaving: Int64 { compressedOK.reduce(0) { $0 + max(0, $1.video.size - ($1.newSize ?? 0)) } }

    /// Shows the summary before deleting the originals of the videos that now have a smaller copy.
    func requestDeleteOriginals() {
        let entries = compressedOK.map {
            DeleteEntry(id: $0.video.id, name: $0.video.name, size: $0.video.size, favorite: $0.video.favorite,
                        edited: false, live: false, raw: false, isVideo: true)
        }
        guard !entries.isEmpty else { return }
        pendingDelete = PendingDelete(kind: .videoOriginals, entries: entries, nothingKept: 0)
    }

    private func deleteOriginals(_ ids: Set<String>) async {
        deleting = true
        defer { deleting = false }
        guard await library.delete(Array(ids)) else { return }
        originalsDeleted = true
        message = "Deleted \(Format.plural(ids.count, "original")). They're in Recently Deleted in Photos for 30 days. "
            + "To free the space now, empty Recently Deleted."
    }

    func openPhotos() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Photos") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    private func sortSets() {
        let items = self.items
        func date(_ s: DuplicateSet) -> Date {
            s.members.compactMap { items[$0.index].date }.min() ?? .distantPast
        }
        switch sortOrder {
        case .space: sets.sort { ($0.saving(items), $0.members.count) > ($1.saving(items), $1.members.count) }
        case .count: sets.sort { ($0.members.count, $0.saving(items)) > ($1.members.count, $1.saving(items)) }
        case .oldest: sets.sort { date($0) < date($1) }
        case .newest: sets.sort { date($0) > date($1) }
        }
    }

    func openPrivacySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos")!)
    }
}

struct VideoCandidate: Identifiable, Hashable {
    let video: VideoItem
    let same: CompressionPlan?
    let hd: CompressionPlan?
    var id: String { video.id }
    func plan(_ mode: CompressionMode) -> CompressionPlan? { mode == .sameResolution ? same : hd }
}

struct CompressResult: Identifiable, Hashable {
    let video: VideoItem
    let newID: String?
    let newSize: Int64?
    let problem: String?
    var id: String { video.id }
}

/// What's about to be deleted, for Sift's summary.
struct PendingDelete: Identifiable {
    enum Kind { case photos, videoOriginals }
    let id = UUID()
    let kind: Kind
    let entries: [DeleteEntry]
    let nothingKept: Int          // sets in which every photo is marked
}

struct DeleteEntry: Identifiable, Hashable {
    let id: String
    let name: String
    let size: Int64
    let favorite: Bool
    let edited: Bool
    let live: Bool
    let raw: Bool
    let isVideo: Bool
}
