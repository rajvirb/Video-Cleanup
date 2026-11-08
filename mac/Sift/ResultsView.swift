import Photos
import SiftCore
import SwiftUI

/// What the scan found: a summary, then each set of photos that look alike, to mark
/// KEEP or DELETE.
struct ResultsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            summary
            Divider()
            if model.sets.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "checkmark.circle").font(.system(size: 44)).foregroundStyle(.green)
                    Text(model.items.isEmpty ? "No photos to check" : "Nothing left to review")
                        .font(.title2.bold())
                    Text("Sift didn't find any more duplicates or similar shots.").foregroundStyle(.secondary)
                    Button("Scan Again") { model.stage = .start }.padding(.top, 6)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 14) {
                        ForEach(Array(model.sets.enumerated()), id: \.element.id) { k, set in
                            SetRow(number: k + 1, set: set) { model.comparing = k }
                        }
                    }
                    .padding(20)
                }
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Picker("Sort", selection: $model.sortOrder) {
                    ForEach(AppModel.SortOrder.allCases) { Text($0.rawValue).tag($0) }
                }
                .help("Sort the sets")
                Button("Select Suggested") { model.selectSuggested() }
                    .help("Mark the copies Sift is sure about. Ones marked Review are left for you to decide.")
                Button("Clear") { model.marked.removeAll() }
                    .disabled(model.marked.isEmpty)
                Button(role: .destructive) {
                    model.requestDelete(model.marked)
                } label: {
                    Text(model.marked.isEmpty ? "Delete" : "Delete \(model.marked.count.formatted())")
                }
                .disabled(model.marked.isEmpty || model.deleting)
                Button("Scan Again") { model.stage = .start }
            }
        }
        .sheet(isPresented: Binding(get: { model.comparing != nil }, set: { if !$0 { model.comparing = nil } })) {
            CompareView()
                .environmentObject(model)
        }
    }

    private var summary: some View {
        HStack(alignment: .firstTextBaseline, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.deleteSuggested > 0 ? "\(Format.size(model.savingSuggested)) could be freed"
                     : "\(Format.plural(model.sets.count, "set")) to look at")
                    .font(.title.bold())
                Text([Format.plural(model.sets.count, "set") + " of duplicate or similar photos",
                      model.deleteSuggested > 0 ? "\(Format.plural(model.deleteSuggested, "copy", "copies")) to delete" : nil,
                      model.reviewSuggested > 0 ? "\(model.reviewSuggested.formatted()) to review" : nil]
                    .compactMap { $0 }.joined(separator: " · "))
                    .foregroundStyle(.secondary)
                if let message = model.message {
                    Label(message, systemImage: "trash").font(.callout).padding(.top, 4)
                }
            }
            Spacer()
            if !model.marked.isEmpty {
                Text("\(model.marked.count.formatted()) marked · \(Format.size(model.markedSize))")
                    .foregroundStyle(.red)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}

struct SetRow: View {
    @EnvironmentObject var model: AppModel
    let number: Int
    let set: DuplicateSet
    let compare: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("Set \(number)").bold()
                Text(Format.plural(set.members.count, "photo")).foregroundStyle(.secondary)
                let saving = set.saving(model.items)
                if saving > 0 { Text("Frees \(Format.size(saving))").foregroundStyle(.red) }
                Spacer()
                Button("Compare", systemImage: "arrow.up.left.and.arrow.down.right", action: compare)
                Button("Keep All") { model.keepAll(set) }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 240), spacing: 12)], alignment: .leading, spacing: 12) {
                ForEach(set.members, id: \.index) { member in
                    let item = model.items[member.index]
                    ItemTile(item: item, member: member, marked: model.marked.contains(item.id))
                        .onTapGesture { model.toggle(item.id) }
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(nsColor: .separatorColor)))
    }
}

/// One photo in a set: its thumbnail, KEEP or DELETE, and why Sift grouped it.
struct ItemTile: View {
    let item: PhotoItem
    let member: SetMember
    let marked: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .top) {
                Thumbnail(id: item.id, side: 220)
                    .frame(height: 150)
                    .clipped()
                    .opacity(marked ? 0.5 : 1)
                HStack(alignment: .top) {
                    Tag(text: marked ? "DELETE" : "KEEP", color: marked ? .red : .green)
                    Spacer()
                    Badges(item: item, member: member)
                }
                .padding(6)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.callout.weight(.medium)).lineLimit(1)
                Text(details).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                if member.suggestion != .keep {
                    Text(member.reason).font(.caption).lineLimit(3).padding(.top, 2)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(marked ? Color.red : Color.green, lineWidth: 3))
        .contentShape(Rectangle())
        .help(marked ? "Click to keep" : "Click to mark for deleting")
    }

    private var details: String {
        var parts: [String] = []
        if let date = item.date { parts.append(date.formatted(date: .abbreviated, time: .shortened)) }
        parts.append("\(item.width)×\(item.height)")
        if item.size > 0 { parts.append(Format.size(item.size)) }
        return parts.joined(separator: " · ")
    }
}

struct Tag: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(color))
            .foregroundStyle(.white)
    }
}

struct Badges: View {
    let item: PhotoItem
    let member: SetMember

    var body: some View {
        HStack(spacing: 4) {
            if member.suggestion == .keep { badge("★ Best", .yellow, .black) }
            if member.suggestion == .review { badge("Review", .orange, .black) }
            if item.favorite { badge("♥", .black.opacity(0.6), .white) }
            if item.live { badge("Live", .black.opacity(0.6), .white) }
            if item.burst { badge("Burst", .black.opacity(0.6), .white) }
            if item.raw { badge("RAW", .black.opacity(0.6), .white) }
            if item.edited { badge("Edited", .black.opacity(0.6), .white) }
        }
    }

    private func badge(_ text: String, _ background: Color, _ foreground: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(background))
            .foregroundStyle(foreground)
    }
}

/// A photo's thumbnail from Photos, loaded when it scrolls into view.
struct Thumbnail: View {
    @EnvironmentObject var model: AppModel
    let id: String
    let side: CGFloat
    var fit = false
    @State private var image: NSImage?
    @State private var request: PHImageRequestID?

    var body: some View {
        ZStack {
            Color.black.opacity(0.85)
            if let image {
                if fit {
                    Image(nsImage: image).resizable().scaledToFit()
                } else {
                    Image(nsImage: image).resizable().scaledToFill()
                }
            }
        }
        .onAppear {
            request = model.library.thumbnail(id, side: side * 2) { found in
                if let found { image = found }
            }
        }
        .onDisappear {
            if let request { model.library.cancel(request) }
        }
    }
}
