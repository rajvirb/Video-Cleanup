import SiftCore
import SwiftUI

/// Sift's summary of what's about to be deleted, shown before macOS's own confirmation:
/// how many and how much space, anything worth a second look (favourites, edits, Live
/// Photos, sets where nothing would be kept), and the items themselves.
struct DeleteSummaryView: View {
    @EnvironmentObject var model: AppModel
    let pending: PendingDelete

    private var noun: (String, String) {
        switch pending.kind {
        case .photos: ("photo", "photos")
        case .videoOriginals: ("original video", "original videos")
        }
    }

    var body: some View {
        let count = pending.entries.count
        let size = pending.entries.reduce(Int64(0)) { $0 + $1.size }
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Eyebrow(text: "Before deleting")
                Text("Delete \(Format.plural(count, noun.0, noun.1))?").font(Theme.display(26))
                if size > 0 {
                    Text("This frees \(Format.size(size)) once they leave Recently Deleted.").foregroundStyle(Theme.ink2)
                }
                Text("macOS will ask you to confirm next. Deleted items stay in Photos' Recently Deleted album "
                     + "for 30 days, so you can still get them back.")
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            let notes = warnings
            if !notes.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(notes, id: \.text) { note in
                        Label(note.text, systemImage: note.serious ? "exclamationmark.octagon" : "exclamationmark.triangle")
                            .foregroundStyle(note.serious ? Theme.danger : Theme.warning)
                    }
                }
                .font(.callout)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Theme.radius).fill(notes.contains(where: \.serious) ? Theme.dangerSoft : Theme.warningSoft))
            }

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 10)], spacing: 12) {
                    ForEach(pending.entries) { entry in
                        VStack(alignment: .leading, spacing: 3) {
                            Thumbnail(id: entry.id, side: 110)
                                .frame(height: 74)
                                .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSmall))
                                .overlay(alignment: .topTrailing) {
                                    if entry.favorite {
                                        Text("♥").font(.caption2).frame(width: 18, height: 18)
                                            .background(Circle().fill(.black.opacity(0.55))).foregroundStyle(.white).padding(4)
                                    }
                                }
                            Text(entry.name).font(.caption2).lineLimit(1)
                            if entry.size > 0 { Text(Format.size(entry.size)).font(.caption2).foregroundStyle(Theme.muted) }
                        }
                    }
                }
                .padding(10)
            }
            .frame(minHeight: 120, maxHeight: 300)
            .background(RoundedRectangle(cornerRadius: Theme.radius).fill(Theme.bg2))

            HStack(spacing: 10) {
                Spacer()
                Button("Cancel") { model.pendingDelete = nil }
                    .buttonStyle(.secondary)
                    .keyboardShortcut(.cancelAction)         // deleting always takes a click
                Button("Delete \(Format.plural(count, noun.0, noun.1))…") {
                    Task { await model.confirmDelete(pending) }
                }
                .buttonStyle(.danger)
            }
        }
        .padding(26)
        .frame(width: 640)
        .background(Theme.surface)
        .foregroundStyle(Theme.ink)
    }

    private var warnings: [(text: String, serious: Bool)] {
        var notes: [(String, Bool)] = []
        if pending.nothingKept > 0 {
            notes.append(("In \(Format.plural(pending.nothingKept, "set")) every photo is marked, so none of them would be kept.", true))
        }
        let favourites = pending.entries.filter(\.favorite).count
        if favourites > 0 { notes.append(("\(favourites.formatted()) \(favourites == 1 ? "is a favourite" : "are favourites").", false)) }
        let edited = pending.entries.filter(\.edited).count
        if edited > 0 { notes.append(("\(edited.formatted()) \(edited == 1 ? "has" : "have") edits you made in Photos.", false)) }
        let live = pending.entries.filter(\.live).count
        if live > 0 { notes.append(("\(live.formatted()) \(live == 1 ? "is a Live Photo" : "are Live Photos").", false)) }
        let raw = pending.entries.filter(\.raw).count
        if raw > 0 { notes.append(("\(raw.formatted()) \(raw == 1 ? "has a RAW original" : "have RAW originals").", false)) }
        return notes.map { (text: $0.0, serious: $0.1) }
    }
}
