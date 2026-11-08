import SiftCore
import SwiftUI

/// One set at a time, big and side by side, in full quality. All the photos zoom
/// together and follow the pointer, so you can compare the same detail in each.
struct CompareView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var zoom: CGFloat = 1
    @State private var anchor = UnitPoint.center
    @FocusState private var focused: Bool

    var body: some View {
        if let k = model.comparing, k < model.sets.count {
            let set = model.sets[k]
            let markedHere = set.members.map { model.items[$0.index].id }.filter { model.marked.contains($0) }
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Text("Set \(k + 1) of \(model.sets.count) · \(Format.plural(set.members.count, "photo"))").bold()
                    Text("← → switch set · 1–9 keep or delete · Z zoom")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Picker("Zoom", selection: $zoom) {
                        Text("Fit").tag(CGFloat(1))
                        Text("2×").tag(CGFloat(2))
                        Text("4×").tag(CGFloat(4))
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 150)
                    Button("Keep All") { model.keepAll(set) }
                    Button("Previous", systemImage: "chevron.left") { model.comparing = k - 1 }
                        .keyboardShortcut(.leftArrow, modifiers: [])
                        .disabled(k == 0)
                    Button("Next", systemImage: "chevron.right") { model.comparing = k + 1 }
                        .keyboardShortcut(.rightArrow, modifiers: [])
                        .disabled(k >= model.sets.count - 1)
                    Button(role: .destructive) {
                        model.requestDelete(Set(markedHere))
                    } label: {
                        Text(markedHere.isEmpty ? "Delete" : "Delete \(markedHere.count)")
                    }
                    .disabled(markedHere.isEmpty || model.deleting)
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                .padding(12)
                Divider()
                panels(set)
            }
            .frame(minWidth: 900, idealWidth: 1300, minHeight: 620, idealHeight: 860)
            .focusable()
            .focused($focused)
            .onAppear { focused = true }
            // the summary before deleting opens from here while the compare view is showing
            .sheet(item: Binding(get: { model.pendingDelete }, set: { model.pendingDelete = $0 })) { pending in
                DeleteSummaryView(pending: pending).environmentObject(model)
            }
            .onChange(of: k) { zoom = 1 }
            .onKeyPress(characters: .decimalDigits) { press in
                guard let n = Int(press.characters), n >= 1, n <= set.members.count else { return .ignored }
                model.toggle(model.items[set.members[n - 1].index].id)
                return .handled
            }
            .onKeyPress("z") {
                zoom = zoom == 1 ? 2 : zoom == 2 ? 4 : 1
                return .handled
            }
        } else {
            Text("That set has been dealt with.")
                .padding(40)
                .onAppear { dismiss() }
        }
    }

    private func panels(_ set: DuplicateSet) -> some View {
        GeometryReader { geo in
            let n = set.members.count
            let cols = n <= 3 ? n : (n == 4 ? (geo.size.width > 1400 ? 4 : 2) : (geo.size.width > 1400 ? 4 : 3))
            let rows = Int(ceil(Double(n) / Double(cols)))
            let height = max(320, (geo.size.height - 12 * Double(rows + 1)) / Double(rows))
            let maxPixels = set.members.map { model.items[$0.index].pixels }.max() ?? 0
            let maxSize = set.members.map { model.items[$0.index].size }.max() ?? 0
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: cols), spacing: 12) {
                    ForEach(Array(set.members.enumerated()), id: \.element.index) { i, member in
                        let item = model.items[member.index]
                        ComparePanel(item: item, member: member, number: i + 1, marked: model.marked.contains(item.id),
                                     bestPixels: item.pixels == maxPixels && n > 1, bestSize: item.size == maxSize && item.size > 0,
                                     zoom: zoom, anchor: $anchor,
                                     toggleZoom: { zoom = zoom == 1 ? 2 : 1 },
                                     keepOnly: { model.keepOnly(member.index, in: set) })
                            .frame(height: height)
                    }
                }
                .padding(12)
            }
        }
    }
}

struct ComparePanel: View {
    @EnvironmentObject var model: AppModel
    let item: PhotoItem
    let member: SetMember
    let number: Int
    let marked: Bool
    let bestPixels: Bool
    let bestSize: Bool
    let zoom: CGFloat
    @Binding var anchor: UnitPoint
    let toggleZoom: () -> Void
    let keepOnly: () -> Void

    @State private var full: NSImage?
    @State private var isFullQuality = true
    @State private var loading = true
    @State private var downloaded = 0.0

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                ZStack {
                    Color.black
                    Group {
                        if let full {
                            Image(nsImage: full).resizable().scaledToFit()
                        } else {
                            Thumbnail(id: item.id, side: 400, fit: true)
                        }
                    }
                    .scaleEffect(zoom, anchor: anchor)
                    .animation(.easeOut(duration: 0.12), value: zoom)
                }
                .clipped()
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    if case .active(let point) = phase, geo.size.width > 0, geo.size.height > 0 {
                        anchor = UnitPoint(x: point.x / geo.size.width, y: point.y / geo.size.height)
                    }
                }
                .onTapGesture(perform: toggleZoom)
                .overlay(alignment: .topLeading) {
                    HStack(alignment: .top) {
                        Tag(text: marked ? "DELETE" : "KEEP", color: marked ? .red : .green)
                        Spacer()
                        Badges(item: item, member: member)
                    }
                    .padding(8)
                }
                .overlay(alignment: .bottomLeading) {
                    Text("\(number)")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(.black.opacity(0.6)))
                        .foregroundStyle(.white)
                        .padding(8)
                }
                .overlay(alignment: .bottomTrailing) { status.padding(8) }
            }
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(item.name).fontWeight(.semibold).lineLimit(1)
                        if member.suggestion == .keep { Text("★ Best copy").foregroundStyle(.green).fontWeight(.semibold) }
                    }
                    HStack(spacing: 8) {
                        if let date = item.date { Text(date.formatted(date: .abbreviated, time: .shortened)) }
                        Text("\(item.width)×\(item.height)").fontWeight(bestPixels ? .semibold : .regular)
                        if item.size > 0 { Text(Format.size(item.size)).fontWeight(bestSize ? .semibold : .regular) }
                    }
                    .foregroundStyle(.secondary)
                    if member.suggestion != .keep { Text(member.reason).lineLimit(2) }
                }
                .font(.callout)
                Spacer()
                Button(marked ? "Keep" : "Delete") { model.toggle(item.id) }
                Button("Keep Only This", action: keepOnly)
            }
            .padding(10)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(marked ? Color.red : Color.green, lineWidth: 3))
        .task(id: item.id) {
            loading = true
            full = nil
            let (image, ok) = await model.library.fullImage(item.id) { downloaded = $0 }
            full = image
            isFullQuality = ok
            loading = false
        }
    }

    @ViewBuilder private var status: some View {
        if loading {
            Label(downloaded > 0 ? "Downloading from iCloud… \(Int(downloaded * 100))%" : "Loading full quality…",
                  systemImage: "icloud.and.arrow.down")
                .modifier(Pill(color: .black.opacity(0.7)))
        } else if !isFullQuality {
            Label("Preview only: the full-quality version couldn't be loaded", systemImage: "exclamationmark.triangle")
                .modifier(Pill(color: .orange.opacity(0.9)))
        }
    }
}

struct Pill: ViewModifier {
    let color: Color

    func body(content: Content) -> some View {
        content
            .font(.caption)
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background(Capsule().fill(color))
            .foregroundStyle(.white)
    }
}
