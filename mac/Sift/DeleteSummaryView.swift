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
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "trash.circle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Delete \(Format.plural(count, noun.0, noun.1))?").font(.title2.bold())
                    Text(size > 0 ? "This frees \(Format.size(size)) once they leave Recently Deleted." : "")
                        .foregroundStyle(.secondary)
                    Text("macOS will ask you to confirm next. Deleted items stay in Photos' Recently Deleted album "
                         + "for 30 days, so you can still get them back.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            let notes = warnings
            if !notes.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(notes, id: \.self) { note in
                        Label(note, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(note.hasPrefix("In ") ? .red : .orange)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.1)))
            }

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 10)], spacing: 10) {
                    ForEach(pending.entries) { entry in
                        VStack(alignment: .leading, spacing: 3) {
                            Thumbnail(id: entry.id, side: 110)
                                .frame(height: 76)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .overlay(alignment: .topTrailing) {
                                    if entry.favorite {
                                        Text("♥").font(.caption2).padding(3)
                                            .background(Circle().fill(.black.opacity(0.6))).foregroundStyle(.white).padding(3)
                                    }
                                }
                            Text(entry.name).font(.caption2).lineLimit(1)
                            if entry.size > 0 { Text(Format.size(entry.size)).font(.caption2).foregroundStyle(.secondary) }
                        }
                    }
                }
                .padding(2)
            }
            .frame(minHeight: 120, maxHeight: 300)

            HStack {
                Spacer()
                Button("Cancel") { model.pendingDelete = nil }
                    .keyboardShortcut(.cancelAction)         // deleting always takes a click
                Button(role: .destructive) {
                    Task { await model.confirmDelete(pending) }
                } label: {
                    Text("Delete \(Format.plural(count, noun.0, noun.1))…")
                }
                .tint(.red)
            }
        }
        .padding(22)
        .frame(width: 620)
    }

    private var warnings: [String] {
        var notes: [String] = []
        if pending.nothingKept > 0 {
            notes.append("In \(Format.plural(pending.nothingKept, "set")) every photo is marked, so none of them would be kept.")
        }
        let favourites = pending.entries.filter(\.favorite).count
        if favourites > 0 { notes.append("\(favourites.formatted()) \(favourites == 1 ? "is a favourite" : "are favourites").") }
        let edited = pending.entries.filter(\.edited).count
        if edited > 0 { notes.append("\(edited.formatted()) \(edited == 1 ? "has" : "have") edits you made in Photos.") }
        let live = pending.entries.filter(\.live).count
        if live > 0 { notes.append("\(live.formatted()) \(live == 1 ? "is a Live Photo" : "are Live Photos").") }
        let raw = pending.entries.filter(\.raw).count
        if raw > 0 { notes.append("\(raw.formatted()) \(raw == 1 ? "has a RAW original" : "have RAW originals").") }
        return notes
    }
}
