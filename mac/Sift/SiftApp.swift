import SwiftUI

@main
struct SiftApp: App {
    @StateObject private var model = AppModel()

    init() {
        Theme.registerFonts()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 820, minHeight: 580)
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
        Group {
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
                StartView()
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
        .foregroundStyle(Theme.ink)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
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
