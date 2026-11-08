import SiftCore
import SwiftUI

/// The videos a smaller copy is worth making of, to tick and shrink.
struct VideosView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(model.candidates.isEmpty ? "Your videos are already efficiently stored"
                         : "About \(Format.size(model.compressionSaving)) could be saved")
                        .font(.title.bold())
                    Spacer()
                    Button("Back") { model.stage = .start }
                }
                if !model.candidates.isEmpty {
                    Picker("Setting", selection: $model.compressionMode) {
                        ForEach(CompressionMode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 320)
                    Text(model.compressionMode.summary + " Slo-mo, time-lapse and edited videos are left out, "
                         + "because re-saving them would lose those effects. Your originals aren't changed.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(20)
            Divider()
            if model.candidates.isEmpty {
                Text("None of your videos would get much smaller by re-saving them.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(model.candidates) { candidate in
                        VideoRow(candidate: candidate)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                Divider()
                HStack {
                    Button("Select All") { model.chosenVideos = Set(model.candidates.map(\.id)) }
                    Button("Select None") { model.chosenVideos = [] }
                    Spacer()
                    Text("Each copy goes into Photos with the original's date, place, favourite and albums.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("Make \(Format.plural(model.videosToCompress.count, "Smaller Copy", "Smaller Copies"))") {
                        model.compressVideos()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.videosToCompress.isEmpty)
                }
                .padding(14)
            }
        }
    }
}

struct VideoRow: View {
    @EnvironmentObject var model: AppModel
    let candidate: VideoCandidate

    var body: some View {
        let plan = candidate.plan(model.compressionMode)
        let video = candidate.video
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(
                get: { model.chosenVideos.contains(video.id) },
                set: { on in if on { model.chosenVideos.insert(video.id) } else { model.chosenVideos.remove(video.id) } }
            ))
            .labelsHidden()
            .disabled(plan == nil)
            Thumbnail(id: video.id, side: 90)
                .frame(width: 96, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .bottomTrailing) {
                    Text(duration(video.duration))
                        .font(.caption2.monospacedDigit())
                        .padding(.horizontal, 4)
                        .background(RoundedRectangle(cornerRadius: 3).fill(.black.opacity(0.6)))
                        .foregroundStyle(.white)
                        .padding(3)
                }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(video.name).fontWeight(.medium).lineLimit(1)
                    if video.favorite { Text("♥").foregroundStyle(.pink) }
                }
                Text([video.date?.formatted(date: .abbreviated, time: .omitted),
                      "\(Compression.resolution(video.shortSide))", plan?.label].compactMap { $0 }.joined(separator: " · "))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let plan {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(Format.size(video.size)) → about \(Format.size(plan.estimatedSize))").monospacedDigit()
                    Text("saves \(Format.size(plan.saving(video)))").font(.callout).foregroundStyle(.green)
                }
            } else {
                Text("Not worth it at this setting").font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

struct CompressingView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Making smaller copies…").font(.title2.bold())
            ProgressView(value: (Double(max(0, model.compressIndex - 1)) + model.compressFraction) / Double(max(1, model.compressTotal)))
            Text(model.compressDetail).foregroundStyle(.secondary).monospacedDigit()
            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.compressName).fontWeight(.medium).lineLimit(1)
                    ProgressView(value: model.compressFraction)
                    Text(model.compressFraction < 0.1 ? "Getting the original (from iCloud if need be)…" : "Re-saving as HEVC…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(6)
            }
            HStack {
                Text("Your originals aren't changed. You can keep using your Mac while this runs.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Stop") { model.cancelCompressing() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(40)
        .frame(maxWidth: 680)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct CompressedView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let ok = model.compressedOK
        VStack(alignment: .leading, spacing: 14) {
            Text(ok.isEmpty ? "No smaller copies were made"
                 : "Made \(Format.plural(ok.count, "smaller copy", "smaller copies")), saving \(Format.size(model.compressedSaving))")
                .font(.title.bold())
            if !ok.isEmpty {
                Text("They're in Photos with the same dates, places, favourites and albums as the originals. To compare "
                     + "them, open the album “\(VideoCompressor.albumCompare)”, where each original sits next to its copy.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(model.originalsDeleted
                     ? (model.message ?? "")
                     : "When you're happy with the copies, delete the originals to free the space.")
                    .fontWeight(model.originalsDeleted ? .regular : .medium)
                    .fixedSize(horizontal: false, vertical: true)
            }
            List(model.compressResults) { result in
                HStack {
                    Image(systemName: result.newID == nil ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(result.newID == nil ? .orange : .green)
                    Text(result.video.name).lineLimit(1)
                    Spacer()
                    if let size = result.newSize {
                        Text("\(Format.size(result.video.size)) → \(Format.size(size))").monospacedDigit()
                    } else {
                        Text(result.problem ?? "Skipped").font(.callout).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            HStack {
                Button("Done") { model.stage = .start }
                Spacer()
                Button("Open Photos") { model.openPhotos() }
                if !ok.isEmpty && !model.originalsDeleted {
                    Button("Delete \(Format.plural(ok.count, "Original"))…") { model.requestDeleteOriginals() }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .disabled(model.deleting)
                }
            }
        }
        .padding(24)
    }
}

func duration(_ seconds: Double) -> String {
    let s = Int(seconds.rounded())
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
}
