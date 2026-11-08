import Photos
import SiftCore
import SwiftUI

/// What the scan found: a summary, then each set of photos that look alike, to mark
/// KEEP or DELETE.
struct ResultsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.border).frame(height: 1)
            if model.sets.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(Theme.success)
                    Text(model.items.isEmpty ? "No photos to check" : "Nothing left to review").font(Theme.display(24))
                    Text("Sift didn't find any more duplicates or similar shots.").foregroundStyle(Theme.muted)
                    Button("Scan Again") { model.stage = .start }
                        .buttonStyle(.secondary)
                        .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 16) {
                        ForEach(Array(model.sets.enumerated()), id: \.element.id) { k, set in
                            SetRow(number: k + 1, set: set) { model.comparing = k }
                        }
                    }
                    .padding(24)
                }
            }
        }
        .sheet(isPresented: Binding(get: { model.comparing != nil }, set: { if !$0 { model.comparing = nil } })) {
            CompareView()
                .environmentObject(model)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Eyebrow(text: "Duplicate photos")
                    Text(model.deleteSuggested > 0 ? "\(Format.size(model.savingSuggested)) could be freed"
                         : "\(Format.plural(model.sets.count, "set")) to look at")
                        .font(Theme.display(30))
                    HStack(spacing: 8) {
                        Pill(text: Format.plural(model.sets.count, "set"), color: Theme.ink2, background: Theme.surface3)
                        if model.deleteSuggested > 0 {
                            Pill(text: "\(Format.plural(model.deleteSuggested, "copy", "copies")) to delete",
                                 color: Theme.danger, background: Theme.dangerSoft)
                        }
                        if model.reviewSuggested > 0 {
                            Pill(text: "\(model.reviewSuggested.formatted()) to review", color: Theme.warning, background: Theme.warningSoft)
                        }
                    }
                }
                Spacer()
                Button("Scan Again") { model.stage = .start }.buttonStyle(.secondary)
            }
            if let message = model.message {
                Label(message, systemImage: "checkmark.circle")
                    .font(.callout)
                    .foregroundStyle(Theme.success)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: Theme.radius).fill(Theme.successSoft))
            }
            HStack(spacing: 10) {
                Picker("Sort", selection: $model.sortOrder) {
                    ForEach(AppModel.SortOrder.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .frame(width: 210)
                Button("Select Suggested") { model.selectSuggested() }
                    .buttonStyle(.secondary)
                    .help("Mark the copies Sift is sure about. Ones marked Review are left for you to decide.")
                Button("Clear") { model.marked.removeAll() }
                    .buttonStyle(.secondary)
                    .disabled(model.marked.isEmpty)
                Spacer()
                if !model.marked.isEmpty {
                    Text("\(model.marked.count.formatted()) marked · \(Format.size(model.markedSize))")
                        .foregroundStyle(Theme.muted)
                        .monospacedDigit()
                }
                Button(model.marked.isEmpty ? "Delete" : "Delete \(model.marked.count.formatted())…") {
                    model.requestDelete(model.marked)
                }
                .buttonStyle(.danger)
                .disabled(model.marked.isEmpty || model.deleting)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .padding(.bottom, 16)
        .background(Theme.bg)
    }
}

struct SetRow: View {
    @EnvironmentObject var model: AppModel
    let number: Int
    let set: DuplicateSet
    let compare: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("Set \(number)").font(Theme.display(15, bold: false))
                Text(Format.plural(set.members.count, "photo")).foregroundStyle(Theme.muted)
                let saving = set.saving(model.items)
                if saving > 0 { Pill(text: "Frees \(Format.size(saving))", color: Theme.accentText, background: Theme.accentSoft) }
                Spacer()
                Button("Compare", systemImage: "arrow.up.left.and.arrow.down.right", action: compare)
                    .buttonStyle(SecondaryButtonStyle(tint: Theme.accentText))
                Button("Keep All") { model.keepAll(set) }.buttonStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 240), spacing: 12)], alignment: .leading, spacing: 12) {
                ForEach(set.members, id: \.index) { member in
                    let item = model.items[member.index]
                    ItemTile(item: item, member: member, marked: model.marked.contains(item.id))
                        .onTapGesture { model.toggle(item.id) }
                }
            }
        }
        .card(padding: 16)
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
                    .frame(height: 148)
                    .clipped()
                    .saturation(marked ? 0.2 : 1)
                    .opacity(marked ? 0.55 : 1)
                HStack(alignment: .top) {
                    KeepDeleteTag(marked: marked)
                    Spacer()
                    Badges(item: item, member: member)
                }
                .padding(7)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).font(.callout.weight(.medium)).lineLimit(1)
                Text(details).font(.caption).foregroundStyle(Theme.muted).lineLimit(2)
                if member.suggestion != .keep {
                    Text(member.reason).font(.caption).foregroundStyle(Theme.ink2).lineLimit(3).padding(.top, 2)
                }
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.surface2)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius)
            .strokeBorder(marked ? Theme.danger : Theme.border, lineWidth: marked ? 2 : 1))
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

struct KeepDeleteTag: View {
    let marked: Bool

    var body: some View {
        Text(marked ? "DELETE" : "KEEP")
            .font(.system(size: 10, weight: .bold))
            .tracking(0.8)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(marked ? Theme.danger : Color.black.opacity(0.55)))
            .foregroundStyle(.white)
    }
}

struct Badges: View {
    let item: PhotoItem
    let member: SetMember

    var body: some View {
        HStack(spacing: 4) {
            if member.suggestion == .keep { onPhoto("★ Best", Theme.accent) }
            if member.suggestion == .review { onPhoto("Review", Color(red: 0.72, green: 0.47, blue: 0.12)) }
            if item.favorite { onPhoto("♥", .black.opacity(0.55)) }
            if item.live { onPhoto("Live", .black.opacity(0.55)) }
            if item.burst { onPhoto("Burst", .black.opacity(0.55)) }
            if item.raw { onPhoto("RAW", .black.opacity(0.55)) }
            if item.edited { onPhoto("Edited", .black.opacity(0.55)) }
        }
    }

    /// Badges sit on the photo, so they're solid enough to read on any picture.
    private func onPhoto(_ text: String, _ background: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6).padding(.vertical, 2.5)
            .background(Capsule().fill(background))
            .foregroundStyle(.white)
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
            Theme.surface3
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
