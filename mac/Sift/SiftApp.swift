import SwiftUI

@main
struct SiftApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 780, minHeight: 560)
        }
        .defaultSize(width: 1120, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {}        // one window is all Sift needs
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        switch model.stage {
        case .welcome:
            VStack(spacing: 14) {
                ProgressView()
                Text("Opening your Photos library…").foregroundStyle(.secondary)
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
}

struct NoAccessView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Sift needs access to your photos").font(.title2.bold())
            Text("To find duplicates and similar shots, Sift needs to see your Photos library. "
                 + "Nothing leaves your Mac, and nothing is deleted unless you choose to.\n\n"
                 + "In System Settings, choose Privacy & Security › Photos, and set Sift to Full Access.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 460)
            HStack {
                Button("Open System Settings") { model.openPrivacySettings() }
                    .buttonStyle(.borderedProminent)
                Button("Try Again") { Task { await model.begin() } }
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
