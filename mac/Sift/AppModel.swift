import AppKit
import Photos
import SiftCore
import SwiftUI

/// What the window is showing, and everything the screens share.
@MainActor
final class AppModel: ObservableObject {
    enum Stage { case welcome, noAccess, start, scanning, results }
    enum Scope: Hashable { case everything, albums }
    enum SortOrder: String, CaseIterable, Identifiable {
        case space = "Most space saved first", count = "Largest sets first"
        case oldest = "Oldest first", newest = "Newest first"
        var id: String { rawValue }
    }

    let library = PhotoLibrary()

    @Published var stage: Stage = .welcome
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

    /// Deletes photos (macOS asks to confirm), then takes them out of the results.
    func delete(_ ids: Set<String>) async {
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
