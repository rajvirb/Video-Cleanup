import SiftCore
import SwiftUI

/// Choosing what to scan and how strict to be.
struct StartView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 72, height: 72)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Sift").font(.largeTitle.bold())
                    Text("Finds duplicate photos and similar shots, and makes bulky videos smaller. "
                         + "Nothing is deleted unless you choose to.")
                        .foregroundStyle(.secondary)
                }
            }

            Picker("What would you like to do?", selection: $model.job) {
                Text("Find Duplicate Photos").tag(AppModel.Job.photos)
                Text("Make Videos Smaller").tag(AppModel.Job.videos)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 420)

            if model.job == .photos {
                photoOptions
            } else {
                GroupBox {
                    Text("Sift finds videos stored in older, bulkier formats or at higher bitrates than they need, "
                         + "and makes smaller HEVC copies of the ones you choose, keeping each video's date, place, "
                         + "camera and lens. The copies go into Photos next to the originals, so you can compare "
                         + "them before deleting the originals. Your originals are never changed.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                } label: {
                    Text("Making videos smaller").font(.headline)
                }
            }

            Spacer(minLength: 0)
            HStack {
                Text(model.job == .photos ? "Finding duplicate videos is coming in a later version." : "")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(model.job == .photos ? "Scan Photos" : "Find Videos to Shrink") { model.startJob() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.job == .photos && !model.canScan)
            }
        }
        .padding(28)
        .frame(maxWidth: 760, maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var photoOptions: some View {

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("What to scan", selection: $model.scope) {
                        Text("Everything in my library (\(Format.plural(model.totalPhotos, "photo")))")
                            .tag(AppModel.Scope.everything)
                        Text("Only the albums and folders I tick").tag(AppModel.Scope.albums)
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                    if model.scope == .albums {
                        AlbumPicker()
                            .frame(minHeight: 160, maxHeight: 260)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            } label: {
                Text("What to scan").font(.headline)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("How strict", selection: $model.strictness) {
                        ForEach(Strictness.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 360)
                    Text(model.strictness.photoSummary)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            } label: {
                Text("How strict").font(.headline)
            }
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
                Text("Reading your albums…").foregroundStyle(.secondary)
            }
            .padding(.vertical, 8)
        } else if model.albums.isEmpty {
            Text("Your library has no albums with photos in them.").foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                List {
                    OutlineGroup(model.albums, children: \.children) { node in
                        Toggle(isOn: binding(node)) {
                            HStack {
                                Image(systemName: node.isFolder ? "folder" : "rectangle.stack")
                                    .foregroundStyle(.secondary)
                                Text(node.title).fontWeight(node.isFolder ? .semibold : .regular)
                                Text(node.photoIDs.count.formatted()).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .listStyle(.bordered(alternatesRowBackgrounds: false))
                Text(model.chosenPhotoIDs.isEmpty ? "Tick at least one album or folder."
                     : "\(Format.plural(model.chosenPhotoIDs.count, "photo")) chosen")
                    .font(.callout)
                    .foregroundStyle(.secondary)
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
            Text(model.stepTitle).font(.title2.bold())
            if model.stepTotal > 0 {
                ProgressView(value: Double(model.stepDone), total: Double(model.stepTotal))
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            Text(model.stepDetail.isEmpty ? " " : model.stepDetail)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            HStack {
                Text("A big library can take a while the first time. Later scans are much quicker.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { model.cancelScan() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.top, 8)
        }
        .padding(40)
        .frame(maxWidth: 680)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
