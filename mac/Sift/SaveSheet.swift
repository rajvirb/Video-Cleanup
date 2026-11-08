import Photos
import SiftCore
import SwiftUI
import UniformTypeIdentifiers

extension PhotoLibrary {
    /// Adds items already in the library to an album (made if needed), optionally inside a
    /// Photos folder (made if needed).
    func addToAlbum(_ ids: [String], album: String, folder: String?) async throws {
        let target = try await findOrMakeAlbum(album, in: folder)
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCollectionChangeRequest(for: target)?.addAssets(assets)
        }
    }

    /// Imports files into Photos, into an album (made if needed), optionally inside a folder.
    func importToAlbum(_ files: [URL], album: String, folder: String?) async throws {
        let target = try await findOrMakeAlbum(album, in: folder)
        try await PHPhotoLibrary.shared().performChanges {
            var placeholders: [PHObjectPlaceholder] = []
            for file in files {
                let request = PHAssetCreationRequest.forAsset()
                let isVideo = UTType(filenameExtension: file.pathExtension)?.conforms(to: .movie) ?? false
                request.addResource(with: isVideo ? .video : .photo, fileURL: file, options: nil)
                if let placeholder = request.placeholderForCreatedAsset { placeholders.append(placeholder) }
            }
            PHAssetCollectionChangeRequest(for: target)?.addAssets(placeholders as NSArray)
        }
    }

    private func findOrMakeAlbum(_ title: String, in folderTitle: String?) async throws -> PHAssetCollection {
        let folder = try await folderTitle.flatMap { $0.isEmpty ? nil : $0 }.asyncMap { try await self.findOrMakeFolder($0) }
        let collections: PHFetchResult<PHCollection> = folder.map { PHCollection.fetchCollections(in: $0, options: nil) }
            ?? PHCollectionList.fetchTopLevelUserCollections(with: nil)
        var found: PHAssetCollection?
        collections.enumerateObjects { collection, _, stop in
            if let album = collection as? PHAssetCollection, album.localizedTitle == title { found = album; stop.pointee = true }
        }
        if let found { return found }
        var id = ""
        try await PHPhotoLibrary.shared().performChanges {
            let placeholder = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title)
                .placeholderForCreatedAssetCollection
            id = placeholder.localIdentifier
            if let folder { PHCollectionListChangeRequest(for: folder)?.addChildCollections([placeholder] as NSArray) }
        }
        guard let made = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject else {
            throw CocoaError(.fileWriteUnknown)
        }
        return made
    }

    private func findOrMakeFolder(_ title: String) async throws -> PHCollectionList {
        var found: PHCollectionList?
        PHCollectionList.fetchTopLevelUserCollections(with: nil).enumerateObjects { collection, _, stop in
            if let list = collection as? PHCollectionList, list.localizedTitle == title { found = list; stop.pointee = true }
        }
        if let found { return found }
        var id = ""
        try await PHPhotoLibrary.shared().performChanges {
            id = PHCollectionListChangeRequest.creationRequestForCollectionList(withTitle: title)
                .placeholderForCreatedCollectionList.localIdentifier
        }
        guard let made = PHCollectionList.fetchCollectionLists(withLocalIdentifiers: [id], options: nil).firstObject else {
            throw CocoaError(.fileWriteUnknown)
        }
        return made
    }
}

private extension Optional {
    func asyncMap<T>(_ transform: (Wrapped) async throws -> T) async rethrows -> T? {
        guard let value = self else { return nil }
        return try await transform(value)
    }
}

/// What to save, and where: an album (and folder) in Photos, and/or a folder on this Mac.
struct SaveRequest: Identifiable {
    let id = UUID()
    let ids: [String]
}

struct SaveSheet: View {
    @EnvironmentObject var model: AppModel
    let request: SaveRequest
    @State private var toAlbum = true
    @State private var album = "Sift Picks"
    @State private var photosFolder = ""
    @State private var toMacFolder = false
    @State private var macFolder: URL?
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Eyebrow(text: "Save")
                Text("Save \(Format.plural(request.ids.count, model.noun))").font(Theme.display(26))
                Text("Copies are saved; nothing is moved or deleted.").foregroundStyle(Theme.muted)
            }
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Add to an album in Photos", isOn: $toAlbum)
                if toAlbum {
                    TextField("Album name", text: $album).textFieldStyle(.roundedBorder)
                    TextField("Inside a Photos folder (optional)", text: $photosFolder).textFieldStyle(.roundedBorder)
                    Text("Albums and folders that don't exist yet are made for you.").font(.callout).foregroundStyle(Theme.muted)
                }
            }
            .card(padding: 14, radius: Theme.radius)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Toggle("Copy the originals to a folder on this Mac", isOn: $toMacFolder)
                    Spacer()
                    if toMacFolder {
                        Button(macFolder == nil ? "Choose Folder…" : macFolder!.lastPathComponent) { chooseFolder() }
                            .buttonStyle(.secondary)
                    }
                }
            }
            .card(padding: 14, radius: Theme.radius)
            HStack(spacing: 10) {
                Spacer()
                Button("Cancel") { model.saving = nil }
                    .buttonStyle(.secondary)
                    .keyboardShortcut(.cancelAction)
                Button(saving ? "Saving…" : "Save") {
                    saving = true
                    Task {
                        await model.save(request.ids, album: toAlbum ? album : nil,
                                         photosFolder: photosFolder, macFolder: toMacFolder ? macFolder : nil)
                        saving = false
                    }
                }
                .buttonStyle(.primary)
                .keyboardShortcut(.defaultAction)
                .disabled(saving || (!toAlbum && !toMacFolder) || (toAlbum && album.isEmpty) || (toMacFolder && macFolder == nil))
            }
        }
        .padding(26)
        .frame(width: 520)
        .background(Theme.surface)
        .foregroundStyle(Theme.ink)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        if panel.runModal() == .OK { macFolder = panel.url }
    }
}
