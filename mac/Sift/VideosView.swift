import SiftCore
import SwiftUI

/// The videos a smaller copy is worth making of, to tick and shrink.
struct VideosView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Eyebrow(text: "Make videos smaller")
                        Text(model.candidates.isEmpty ? "Your videos are already efficiently stored"
                             : "About \(Format.size(model.compressionSaving)) could be saved")
                            .font(Theme.display(30))
                    }
                    Spacer()
                    Button("Back") { model.stage = .start }.buttonStyle(.secondary)
                }
                if !model.candidates.isEmpty {
                    HStack(spacing: 14) {
                        Picker("Setting", selection: $model.compressionMode) {
                            ForEach(CompressionMode.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 300)
                        Text(model.compressionMode.summary)
                            .font(.callout)
                            .foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("Slo-mo, time-lapse and edited videos are left out, because re-saving them would lose those effects.")
                        .font(.callout)
                        .foregroundStyle(Theme.muted)
                    outputOptions
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
            Rectangle().fill(Theme.border).frame(height: 1)
            if model.candidates.isEmpty {
                Text("None of your videos would get much smaller by re-saving them.")
                    .foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack {
                    Text(Format.plural(model.candidates.count, "video") + " could be smaller").foregroundStyle(Theme.muted)
                    Spacer()
                    Picker("Sort", selection: $model.videoSort) {
                        ForEach(AppModel.VideoSort.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 200)
                }
                .padding(.horizontal, 24)
                .padding(.top, 14)
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(model.sortedCandidates) { VideoRow(candidate: $0) }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                }
                Rectangle().fill(Theme.border).frame(height: 1)
                HStack(spacing: 10) {
                    Button("Select All") { model.chosenVideos = Set(model.candidates.map(\.id)) }.buttonStyle(.secondary)
                    Button("Select None") { model.chosenVideos = [] }.buttonStyle(.secondary)
                    Spacer()
                    Text("Each copy is named like “IMG_1234 - sift compression.MOV”.")
                        .font(.callout)
                        .foregroundStyle(Theme.muted)
                    Button("Make \(Format.plural(model.videosToCompress.count, "Smaller Copy", "Smaller Copies"))") {
                        model.compressVideos()
                    }
                    .buttonStyle(.primary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canCompress)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
                .background(Theme.surface)
            }
        }
    }
}

extension VideosView {
    /// Where the copies go: into Photos, and/or a folder where each sits next to a copy of
    /// its original, for comparing in the Finder.
    var outputOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Import the copies into Photos, with each original's date, place, favourite and albums",
                   isOn: $model.importToPhotos)
            HStack(spacing: 10) {
                Toggle("Also save each copy in a folder, next to a copy of its original", isOn: $model.saveToFolder)
                    .onChange(of: model.saveToFolder) { _, on in
                        if on && model.comparisonFolder == nil { model.chooseComparisonFolder() }
                        if model.comparisonFolder == nil { model.saveToFolder = false }
                    }
                Button(model.comparisonFolder == nil ? "Choose Folder…" : "Change…") { model.chooseComparisonFolder() }
                    .buttonStyle(.secondary)
                    .controlSize(.small)
                if let folder = model.comparisonFolder {
                    Label(folder.lastPathComponent, systemImage: "folder")
                        .font(.callout)
                        .foregroundStyle(Theme.muted)
                        .help(folder.path)
                }
            }
            if !model.importToPhotos && !model.saveToFolder {
                Text("Choose at least one place for the copies.").font(.callout).foregroundStyle(Theme.danger)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.radius).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.border))
    }
}

struct VideoRow: View {
    @EnvironmentObject var model: AppModel
    let candidate: VideoCandidate

    var body: some View {
        let plan = candidate.plan(model.compressionMode)
        let video = candidate.video
        HStack(spacing: 14) {
            Toggle("", isOn: Binding(
                get: { model.chosenVideos.contains(video.id) },
                set: { on in if on { model.chosenVideos.insert(video.id) } else { model.chosenVideos.remove(video.id) } }
            ))
            .labelsHidden()
            .disabled(plan == nil)
            Thumbnail(id: video.id, side: 100)
                .frame(width: 104, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSmall))
                .overlay(alignment: .bottomTrailing) {
                    Text(duration(video.duration))
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 4).fill(.black.opacity(0.6)))
                        .foregroundStyle(.white)
                        .padding(4)
                }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(video.name).fontWeight(.medium).lineLimit(1)
                    if video.favorite { Text("♥").foregroundStyle(Theme.accent) }
                }
                HStack(spacing: 6) {
                    if let date = video.date { Text(date.formatted(date: .abbreviated, time: .omitted)) }
                    Text("·")
                    Text(Compression.resolution(video.shortSide))
                    if let plan { Pill(text: plan.label, color: Theme.ink2, background: Theme.surface3) }
                }
                .font(.callout)
                .foregroundStyle(Theme.muted)
            }
            Spacer()
            if let plan {
                VStack(alignment: .trailing, spacing: 3) {
                    Text("\(Format.size(video.size)) → about \(Format.size(plan.estimatedSize))").monospacedDigit()
                    Text("saves \(Format.size(plan.saving(video)))").font(.callout.weight(.medium)).foregroundStyle(Theme.success)
                }
            } else {
                Text("Not worth it at this setting").font(.callout).foregroundStyle(Theme.muted)
            }
        }
        .card(padding: 12, radius: Theme.radius)
        .opacity(plan == nil ? 0.6 : 1)
    }
}

struct CompressingView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Eyebrow(text: "Make videos smaller")
            Text("Making smaller copies…").font(Theme.display(26))
            ProgressView(value: (Double(max(0, model.compressIndex - 1)) + model.compressFraction) / Double(max(1, model.compressTotal)))
            Text(model.compressDetail).foregroundStyle(Theme.muted).monospacedDigit()
            VStack(alignment: .leading, spacing: 7) {
                Text(model.compressName).fontWeight(.medium).lineLimit(1)
                ProgressView(value: model.compressFraction)
                Text(model.compressFraction < 0.1 ? "Getting the original (from iCloud if need be)…" : "Re-saving as HEVC…")
                    .font(.callout)
                    .foregroundStyle(Theme.muted)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: Theme.radius).fill(Theme.bg2))
            HStack {
                Text("Your originals aren't changed. You can keep using your Mac while this runs.")
                    .font(.callout)
                    .foregroundStyle(Theme.muted)
                Spacer()
                Button("Stop") { model.cancelCompressing() }
                    .buttonStyle(.secondary)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: 620, alignment: .leading)
        .card(padding: 30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct CompressedView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let ok = model.compressedOK
        let inPhotos = model.compressedInPhotos
        let inFolder = ok.contains { $0.file != nil }
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Eyebrow(text: "Make videos smaller")
                Text(ok.isEmpty ? "No smaller copies were made"
                     : "Made \(Format.plural(ok.count, "smaller copy", "smaller copies")), saving \(Format.size(model.compressedSaving))")
                    .font(Theme.display(30))
                if !inPhotos.isEmpty {
                    Text("They're in Photos with the same dates, places, favourites and albums as the originals. To compare "
                         + "them, open the album “\(VideoCompressor.albumCompare)”, where each original sits next to its copy.")
                        .foregroundStyle(Theme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if inFolder, let folder = model.lastFolderUsed {
                    Text("They're also in “\(folder.lastPathComponent)”, each next to a copy of its original, named like "
                         + "“IMG_1234 - sift compression.MOV”.")
                        .foregroundStyle(Theme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !inPhotos.isEmpty {
                Label(model.originalsDeleted ? (model.message ?? "Originals deleted.")
                      : "When you're happy with the copies, delete the originals to free the space.",
                      systemImage: model.originalsDeleted ? "checkmark.circle" : "info.circle")
                    .foregroundStyle(model.originalsDeleted ? Theme.success : Theme.accentText)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: Theme.radius)
                        .fill(model.originalsDeleted ? Theme.successSoft : Theme.accentSoft))
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.compressResults) { result in
                        HStack(spacing: 10) {
                            Image(systemName: result.newID == nil ? "exclamationmark.triangle" : "checkmark.circle.fill")
                                .foregroundStyle(result.newID == nil ? Theme.warning : Theme.success)
                            Text(result.video.name).lineLimit(1)
                            Spacer()
                            if let size = result.newSize {
                                Text("\(Format.size(result.video.size)) → \(Format.size(size))").monospacedDigit()
                            } else {
                                Text(result.problem ?? "Skipped").font(.callout).foregroundStyle(Theme.muted).lineLimit(2)
                            }
                        }
                        .padding(.vertical, 9)
                        .padding(.horizontal, 12)
                        Rectangle().fill(Theme.border).frame(height: 1)
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: Theme.radius).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.border))
            HStack(spacing: 10) {
                Button("Done") { model.stage = .start }.buttonStyle(.secondary)
                Spacer()
                if inFolder {
                    Button("Show in Finder") { model.openComparisonFolder() }.buttonStyle(.secondary)
                }
                Button("Open Photos") { model.openPhotos() }.buttonStyle(.secondary)
                if !inPhotos.isEmpty && !model.originalsDeleted {
                    Button("Delete \(Format.plural(inPhotos.count, "Original"))…") { model.requestDeleteOriginals() }
                        .buttonStyle(.danger)
                        .disabled(model.deleting)
                }
            }
        }
        .padding(28)
    }
}

func duration(_ seconds: Double) -> String {
    let s = Int(seconds.rounded())
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
}
