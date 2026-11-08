import AppKit
import StoreKit
import SwiftUI

/// The "Support Sift" page. The App Store version offers tips through Apple's in-app
/// purchase (as Apple requires outside the US); other versions open a donation link.
/// The link and wording come from support/sift.json in the GitHub repository, so they can
/// be changed without an app update; the last copy is kept for when the Mac is offline.
@MainActor
final class SupportModel: ObservableObject {
    static let configURL = URL(string: "https://raw.githubusercontent.com/rajvirb/Video-Cleanup/main/support/sift.json")!
    static let tipIDs = ["com.rajvirb.siftapp.tip.small", "com.rajvirb.siftapp.tip.medium", "com.rajvirb.siftapp.tip.large"]
    private static let cacheKey = "supportConfig"

    @Published var title = "Support Sift"
    @Published var message = "Sift is free, and made by one person. If it's saved you time or space, you can help keep it going."
    @Published var buttonTitle = "Donate"
    @Published var link: URL?
    @Published var tips: [Product] = []
    @Published var thanks: String?
    @Published var buying = false

    /// The App Store version only ever shows Apple's in-app tips. Builds from Xcode show
    /// them too, so they can be tried with the StoreKit test file (mac/Sift.storekit).
    var showsTipJar: Bool {
        #if APP_STORE || DEBUG
        true
        #else
        false
        #endif
    }

    var showsLink: Bool {
        #if APP_STORE
        false
        #else
        link != nil
        #endif
    }

    struct Config: Codable {
        struct Donate: Codable { var title: String?; var message: String?; var button: String?; var url: String? }
        var donate: Donate?
    }

    func load() async {
        if let data = UserDefaults.standard.data(forKey: Self.cacheKey) { apply(data) }
        var request = URLRequest(url: Self.configURL)
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let (data, response) = try? await URLSession.shared.data(for: request),
           (response as? HTTPURLResponse)?.statusCode == 200, apply(data) {
            UserDefaults.standard.set(data, forKey: Self.cacheKey)
        }
        if showsTipJar, let products = try? await Product.products(for: Self.tipIDs) {
            tips = products.sorted { $0.price < $1.price }
        }
    }

    @discardableResult
    private func apply(_ data: Data) -> Bool {
        guard let config = try? JSONDecoder().decode(Config.self, from: data), let donate = config.donate else { return false }
        if let value = donate.title, !value.isEmpty { title = value }
        if let value = donate.message, !value.isEmpty { message = value }
        if let value = donate.button, !value.isEmpty { buttonTitle = value }
        link = donate.url.flatMap { $0.isEmpty ? nil : URL(string: $0) }
        return true
    }

    func tip(_ product: Product) async {
        buying = true
        defer { buying = false }
        guard let result = try? await product.purchase() else { return }
        if case .success(let verification) = result, case .verified(let transaction) = verification {
            await transaction.finish()
            thanks = "Thank you! That really helps."
        }
    }

    func openLink() {
        if let link { NSWorkspace.shared.open(link) }
    }
}

struct SupportView: View {
    @EnvironmentObject var support: SupportModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Eyebrow(text: "Support")
            Text(support.title).font(Theme.display(32))
            Text(support.message)
                .foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
            if support.showsTipJar {
                if support.tips.isEmpty {
                    Text("Tips aren't available right now.").foregroundStyle(Theme.muted)
                } else {
                    HStack(spacing: 12) {
                        ForEach(support.tips, id: \.id) { product in
                            Button {
                                Task { await support.tip(product) }
                            } label: {
                                VStack(spacing: 4) {
                                    Text(product.displayName).font(Theme.display(15, bold: false))
                                    Text(product.displayPrice).foregroundStyle(Theme.accentText)
                                }
                                .frame(width: 130, height: 64)
                            }
                            .buttonStyle(.secondary)
                            .disabled(support.buying)
                        }
                    }
                }
            }
            if support.showsLink {
                Button(support.buttonTitle, systemImage: "heart.fill") { support.openLink() }
                    .buttonStyle(.primary)
            }
            if let thanks = support.thanks {
                Label(thanks, systemImage: "heart.fill").foregroundStyle(Theme.success)
            }
        }
        .frame(maxWidth: 560, alignment: .leading)
        .card(padding: 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await support.load() }
    }
}
