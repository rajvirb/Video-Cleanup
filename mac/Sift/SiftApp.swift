import SwiftUI

@main
struct SiftApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var support = SupportModel()

    init() {
        Theme.registerFonts()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .environmentObject(support)
                .task { await support.load() }
                .frame(minWidth: 980, minHeight: 580)
                .background(Theme.bg)
                .tint(Theme.accent)
        }
        .defaultSize(width: 1160, height: 800)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(replacing: .newItem) {}        // one window is all Sift needs
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 280)
        } detail: {
            detail
                .foregroundStyle(Theme.ink)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.bg)
        }
        .sheet(item: $model.saving) { request in
            SaveSheet(request: request).environmentObject(model)
        }
    }

    @ViewBuilder private var detail: some View {
        if model.sidebar == .support {
            SupportView()
        } else {
            switch model.stage {
            case .welcome:
                VStack(spacing: 14) {
                    ProgressView()
                    Text("Opening your Photos library…").foregroundStyle(Theme.muted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .task { await model.begin() }
            case .noAccess:
                NoAccessView()
            case .start:
                if model.source == .photos && !model.photosAccess { NoAccessView() } else { StartView() }
            case .scanning:
                ScanningView()
            case .results:
                ResultsView()
                    .sheet(item: Binding(get: { model.comparing == nil ? model.pendingDelete : nil },
                                         set: { model.pendingDelete = $0 })) { pending in
                        DeleteSummaryView(pending: pending).environmentObject(model)
                    }
            case .videos:
                VideosView()
            case .compressing:
                CompressingView()
            case .compressed:
                CompressedView()
                    .sheet(item: $model.pendingDelete) { pending in
                        DeleteSummaryView(pending: pending).environmentObject(model)
                    }
            }
        }
    }
}

/// The sources down the left (Apple Photos, folders on this Mac, Google Photos), each with
/// the tools that work on it, and Support at the bottom.
struct SidebarView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        List(selection: Binding(get: { model.sidebar }, set: { model.select($0) })) {
            Section("Apple Photos") { tools(.photos) }
            Section("Folders on this Mac") { tools(.folders) }
            Section {
                row(.tool(.google, .photos), "Duplicate Photos", "square.on.square")
            } header: {
                HStack {
                    Text("Google Photos")
                    Spacer()
                    if model.googleSignedIn { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success) }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            List(selection: Binding(get: { model.sidebar }, set: { model.select($0) })) {
                Label("Support Sift", systemImage: "heart").tag(Optional(AppModel.SidebarItem.support))
            }
            .listStyle(.sidebar)
            .frame(height: 44)
            .scrollDisabled(true)
        }
        .disabled(model.stage == .scanning || model.stage == .compressing)
    }

    @ViewBuilder private func tools(_ source: AppModel.Source) -> some View {
        row(.tool(source, .photos), "Duplicate Photos", "square.on.square")
        row(.tool(source, .videoDuplicates), "Duplicate Videos", "film.stack")
        row(.tool(source, .videoCompression), "Make Videos Smaller", "arrow.down.right.and.arrow.up.left")
    }

    private func row(_ item: AppModel.SidebarItem, _ title: String, _ symbol: String) -> some View {
        Label(title, systemImage: symbol).tag(Optional(item))
    }
}

struct NoAccessView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Eyebrow(text: "Photos access")
            Text("Sift needs access to your photos").font(Theme.display(30))
            Text("To find duplicates and similar shots, Sift needs to see your Photos library. "
                 + "Nothing leaves your Mac, and nothing is deleted unless you choose to.")
                .foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Text("In System Settings, choose Privacy & Security › Photos, and set Sift to Full Access.")
                .foregroundStyle(Theme.muted)
            HStack(spacing: 10) {
                Button("Open System Settings") { model.openPrivacySettings() }
                    .buttonStyle(.primary)
                Button("Try Again") { Task { await model.begin() } }
                    .buttonStyle(.secondary)
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: 520, alignment: .leading)
        .card(padding: 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
