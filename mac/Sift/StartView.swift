import SiftCore
import SwiftUI

/// Choosing what to do, what to scan and how strict to be.
struct StartView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header
                HStack(spacing: 14) {
                    JobCard(job: .photos, symbol: "square.on.square", title: "Find duplicate photos",
                            detail: "Copies and similar shots, to compare side by side and delete.")
                    JobCard(job: .videoDuplicates, symbol: "film.stack", title: "Find duplicate videos",
                            detail: "Copies, re-saved versions and trimmed clips of the same video.")
                    JobCard(job: .videoCompression, symbol: "arrow.down.right.and.arrow.up.left", title: "Make videos smaller",
                            detail: "Smaller HEVC copies of bulky videos, with their dates, places and cameras.")
                }
                scopeOptions
                if model.job == .videoCompression { videoOptions } else { strictnessOptions }
                HStack(alignment: .center) {
                    Text("Nothing is deleted unless you choose to, and Sift asks you twice first.")
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
                .frame(width: 68, height: 68)
            VStack(alignment: .leading, spacing: 6) {
                Eyebrow(text: "Photos & videos")
                Text("Sift").font(Theme.display(40))
                Text("Clear out duplicates and make bulky videos smaller. Nothing is deleted unless you choose to.")
                    .foregroundStyle(Theme.ink2)
            }
        }
    }

    private var buttonTitle: String {
        switch model.job {
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
            if model.job == .videoDuplicates {
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
                "The copies go into Photos next to the originals, with the same date, place, favourite and albums.",
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

/// One of the two things Sift does, as a card to pick.
struct JobCard: View {
    @EnvironmentObject var model: AppModel
    let job: AppModel.Job
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        let chosen = model.job == job
        Button { model.job = job } label: {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(chosen ? Theme.accent : Theme.muted)
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: 9).fill(chosen ? Theme.accentSoft : Theme.surface3))
                Text(title).font(Theme.display(16, bold: false)).foregroundStyle(Theme.ink)
                Text(detail).font(.callout).foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(RoundedRectangle(cornerRadius: Theme.radiusLarge).fill(chosen ? Theme.accentSoft : Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusLarge)
                .strokeBorder(chosen ? Theme.accent.opacity(0.55) : Theme.border, lineWidth: chosen ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
