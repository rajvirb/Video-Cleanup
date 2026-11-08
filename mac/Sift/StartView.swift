import SiftCore
import SwiftUI

/// Choosing what to do, what to scan and how strict to be.
struct StartView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header
                switch model.source {
                case .photos: scopeOptions
                case .folders: FolderSourceCard()
                case .google: GoogleSourceCard()
                }
                if model.job == .videoCompression { videoOptions } else { strictnessOptions }
                HStack(alignment: .center) {
                    Text(model.source == .google ? "Sift only looks at Google Photos. Deleting happens in Google Photos, by you."
                         : "Nothing is deleted unless you choose to, and Sift asks you twice first.")
                        .font(.callout)
                        .foregroundStyle(Theme.muted)
                    Spacer()
                    Button(buttonTitle) { model.startJob() }
                        .buttonStyle(.primary)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!model.canScan)
                }
            }
            .padding(36)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private var header: some View {
        HStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 60, height: 60)
            VStack(alignment: .leading, spacing: 6) {
                Eyebrow(text: sourceName)
                Text(jobTitle).font(Theme.display(34))
                Text(jobDetail).foregroundStyle(Theme.ink2)
            }
        }
    }

    private var sourceName: String {
        switch model.source {
        case .photos: "Apple Photos"
        case .folders: "Folders on this Mac"
        case .google: "Google Photos"
        }
    }

    private var jobTitle: String {
        switch model.job {
        case .photos: "Duplicate photos"
        case .videoDuplicates: "Duplicate videos"
        case .videoCompression: "Make videos smaller"
        }
    }

    private var jobDetail: String {
        switch model.job {
        case .photos: "Copies and similar shots, to compare side by side and clear out."
        case .videoDuplicates: "Copies, re-saved versions and trimmed clips of the same video."
        case .videoCompression: "Smaller HEVC copies of bulky videos, with their dates, places and cameras."
        }
    }

    private var buttonTitle: String {
        if model.source == .google { return model.googleSignedIn ? "Pick Photos in Google…" : "Sign In First" }
        return switch model.job {
        case .photos: "Scan Photos"
        case .videoDuplicates: "Scan Videos"
        case .videoCompression: "Find Videos to Shrink"
        }
    }

    private var scopeOptions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What to scan").font(Theme.display(17, bold: false))
            Picker("What to scan", selection: $model.scope) {
                Text("Everything in my library (\(Format.plural(model.total, model.noun)))")
                    .tag(AppModel.Scope.everything)
                Text("Only the albums and folders I tick").tag(AppModel.Scope.albums)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            if model.scope == .albums {
                AlbumPicker().frame(minHeight: 160, maxHeight: 260)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var strictnessOptions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("How strict").font(Theme.display(17, bold: false))
            Picker("How strict", selection: $model.strictness) {
                ForEach(Strictness.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 360)
            Text(model.job == .photos ? model.strictness.photoSummary : model.strictness.videoSummary)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            if model.job == .videoDuplicates && model.source == .photos {
                Text("Videos stored only in iCloud are compared by their preview and length, which finds copies but not trimmed clips.")
                    .font(.callout)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var videoOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("How it works").font(Theme.display(17, bold: false))
            ForEach(Array([
                "Sift finds videos stored in older, bulkier formats, or at higher bitrates than they need.",
                "You choose which to shrink, at the same resolution or capped at 1080p.",
                model.source == .folders
                    ? "Each copy is saved next to its original, named “<name> - sift compression”, with the same date and place."
                    : "The copies go into Photos next to the originals, with the same date, place, favourite and albums.",
                "When you're happy with them, Sift can delete the originals, after asking you twice.",
            ].enumerated()), id: \.offset) { k, line in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(k + 1)").font(Theme.display(14, bold: false)).foregroundStyle(Theme.accentText)
                    Text(line).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

/// The folders Sift looks through, with Add and Remove.
struct FolderSourceCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Folders to look through").font(Theme.display(17, bold: false))
                Spacer()
                Button("Add Folder…") { model.addFolder() }.buttonStyle(.secondary)
            }
            if model.folderList.isEmpty {
                Text("Add folders of photos and videos: on this Mac, an external drive, a Google Takeout export, "
                     + "or a synced Google Drive or Dropbox folder. Folders inside them are included.")
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 0) {
                    ForEach(model.folderList, id: \.self) { url in
                        HStack(spacing: 10) {
                            Image(systemName: "folder").foregroundStyle(Theme.muted)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(url.lastPathComponent)
                                Text(url.deletingLastPathComponent().path(percentEncoded: false))
                                    .font(.caption).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            Button { model.removeFolder(url) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                                .help("Stop looking in this folder (nothing in it is changed)")
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 10)
                        if url != model.folderList.last { Divider() }
                    }
                }
                .background(RoundedRectangle(cornerRadius: Theme.radius).fill(Theme.bg2))
                Text("Anything you delete is moved to the Bin, so you can put it back.")
                    .font(.callout).foregroundStyle(Theme.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

/// Signing in to Google, and how picking works.
struct GoogleSourceCard: View {
    @EnvironmentObject var model: AppModel
    @State private var signingIn = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your Google account").font(Theme.display(17, bold: false))
            if !model.google.isConfigured {
                Text("Google sign-in hasn't been set up in this copy of Sift. See “Google Photos” in mac/README.md.")
                    .foregroundStyle(Theme.muted)
            } else if model.googleSignedIn {
                HStack {
                    Image(systemName: "person.crop.circle.badge.checkmark").foregroundStyle(Theme.success)
                    Text(model.googleEmail ?? "Signed in")
                    Spacer()
                    Button("Sign Out") { model.signOutOfGoogle() }.buttonStyle(.secondary)
                }
            } else {
                HStack {
                    Text("Sign in so Sift can see the photos you pick.").foregroundStyle(Theme.ink2)
                    Spacer()
                    Button(signingIn ? "Signing In…" : "Sign In with Google") {
                        signingIn = true
                        Task { await model.signInToGoogle(); signingIn = false }
                    }
                    .buttonStyle(.primary)
                    .disabled(signingIn)
                }
            }
            if let error = model.googleError {
                Text(error).font(.callout).foregroundStyle(Theme.danger)
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("How it works").font(.headline)
                Text("Google only lets apps see the photos you pick in Google's own window, up to 2,000 at a time, and "
                     + "never lets apps delete from Google Photos. So Sift opens Google Photos in your browser, you pick "
                     + "the photos to check (a day, a trip, an album), and Sift shows you the duplicates. You then delete "
                     + "them in Google Photos, with a list Sift copies for you.")
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Only photos are compared; videos picked are skipped.")
                    .font(.callout).foregroundStyle(Theme.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

/// The library's albums and folders, with tick boxes. Ticking a folder includes
/// everything in it.
struct AlbumPicker: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if model.loadingAlbums {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading your albums…").foregroundStyle(Theme.muted)
            }
            .padding(.vertical, 8)
        } else if model.albums.isEmpty {
            Text("Your library has no albums with \(model.noun)s in them.").foregroundStyle(Theme.muted)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                List {
                    OutlineGroup(model.albums, children: \.children) { node in
                        Toggle(isOn: binding(node)) {
                            HStack {
                                Image(systemName: node.isFolder ? "folder" : "rectangle.stack")
                                    .foregroundStyle(Theme.muted)
                                Text(node.title).fontWeight(node.isFolder ? .semibold : .regular)
                                Text(node.photoIDs.count.formatted()).foregroundStyle(Theme.muted)
                            }
                        }
                    }
                }
                .listStyle(.bordered(alternatesRowBackgrounds: false))
                .scrollContentBackground(.hidden)
                .background(RoundedRectangle(cornerRadius: Theme.radius).fill(Theme.bg2))
                Text(model.chosenIDs.isEmpty ? "Tick at least one album or folder."
                     : "\(Format.plural(model.chosenIDs.count, model.noun)) chosen")
                    .font(.callout)
                    .foregroundStyle(Theme.muted)
            }
        }
    }

    private func binding(_ node: AlbumNode) -> Binding<Bool> {
        Binding(
            get: { model.chosenAlbums.contains(node.id) },
            set: { on in
                if on { model.chosenAlbums.insert(node.id) } else { model.chosenAlbums.remove(node.id) }
            }
        )
    }
}

struct ScanningView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Eyebrow(text: model.job == .photos ? "Scanning photos" : model.job == .videoDuplicates ? "Scanning videos" : "Finding videos")
            Text(model.stepTitle).font(Theme.display(26))
            if model.stepTotal > 0 {
                ProgressView(value: Double(model.stepDone), total: Double(model.stepTotal))
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            Text(model.stepDetail.isEmpty ? " " : model.stepDetail)
                .foregroundStyle(Theme.muted)
                .monospacedDigit()
            HStack {
                Text("A big library can take a while the first time. Later scans are much quicker.")
                    .font(.callout)
                    .foregroundStyle(Theme.muted)
                Spacer()
                Button("Cancel") { model.cancelScan() }
                    .buttonStyle(.secondary)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: 600, alignment: .leading)
        .card(padding: 30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
