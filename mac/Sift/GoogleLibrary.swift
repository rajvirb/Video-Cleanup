import AppKit
import AuthenticationServices
import AVFoundation
import CryptoKit
import Security
import SiftCore

enum GoogleError: LocalizedError {
    case notConfigured, cancelled, timedOut, server(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: "Google sign-in hasn't been set up in this copy of Sift yet."
        case .cancelled: "Signing in was cancelled."
        case .timedOut: "Nothing was picked in time. Try again when you're ready."
        case .server(let message): message
        }
    }
}

/// A photo picked in Google Photos.
struct PickedItem: Sendable {
    let id: String
    let filename: String
    let created: Date?
    let width: Int
    let height: Int
    let isVideo: Bool
    let baseURL: String
}

/// Google Photos, through Google's Picker. Since March 2025 Google lets apps see only the
/// photos a person picks in Google's own window (not their whole library), and never lets
/// apps delete from Google Photos. So: sign in, pick, compare here, delete in Google Photos.
final class GoogleLibrary: NSObject, @unchecked Sendable, ASWebAuthenticationPresentationContextProviding {
    static let scopes = "openid email https://www.googleapis.com/auth/photospicker.mediaitems.readonly"
    private let clientID = Bundle.main.object(forInfoDictionaryKey: "GoogleClientID") as? String ?? ""
    private var tokens: Tokens?
    private var picked: [String: PickedItem] = [:]
    private var authSession: ASWebAuthenticationSession?

    override init() {
        super.init()
        tokens = Keychain.load()
    }

    /// Whether this copy of Sift has a Google client ID (see mac/README.md).
    var isConfigured: Bool { clientID.hasSuffix(".apps.googleusercontent.com") }
    var isSignedIn: Bool { tokens != nil }
    var email: String? { tokens?.email }

    private var redirectScheme: String {
        "com.googleusercontent.apps." + clientID.replacingOccurrences(of: ".apps.googleusercontent.com", with: "")
    }
    private var redirectURI: String { redirectScheme + ":/oauth2redirect" }

    // MARK: signing in

    @MainActor
    func signIn() async throws {
        guard isConfigured else { throw GoogleError.notConfigured }
        let verifier = Self.randomString(64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        var auth = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        auth.queryItems = [
            .init(name: "client_id", value: clientID), .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"), .init(name: "scope", value: Self.scopes),
            .init(name: "code_challenge", value: challenge), .init(name: "code_challenge_method", value: "S256"),
        ]
        let callback: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: auth.url!, callbackURLScheme: redirectScheme) { url, error in
                if let url { continuation.resume(returning: url) } else {
                    continuation.resume(throwing: (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin
                                        ? GoogleError.cancelled : (error ?? GoogleError.cancelled))
                }
            }
            session.presentationContextProvider = self
            authSession = session
            session.start()
        }
        guard let code = URLComponents(url: callback, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "code" })?.value else { throw GoogleError.cancelled }
        let reply = try await tokenRequest(["code": code, "client_id": clientID, "code_verifier": verifier,
                                            "grant_type": "authorization_code", "redirect_uri": redirectURI])
        tokens = Tokens(reply, keepingRefresh: nil)
        Keychain.save(tokens!)
    }

    func signOut() {
        if let token = tokens?.refresh ?? tokens?.access {
            var revoke = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke?token=\(token)")!)
            revoke.httpMethod = "POST"
            URLSession.shared.dataTask(with: revoke).resume()
        }
        tokens = nil
        picked = [:]
        Keychain.delete()
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.windows.first ?? NSWindow()
    }

    private func accessToken() async throws -> String {
        guard let current = tokens else { throw GoogleError.server("Please sign in to Google again.") }
        if current.expires > Date().addingTimeInterval(60) { return current.access }
        guard let refresh = current.refresh else { throw GoogleError.server("Please sign in to Google again.") }
        let reply = try await tokenRequest(["refresh_token": refresh, "client_id": clientID, "grant_type": "refresh_token"])
        tokens = Tokens(reply, keepingRefresh: current)
        Keychain.save(tokens!)
        return tokens!.access
    }

    private func tokenRequest(_ form: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")" }
            .joined(separator: "&").data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (response as? HTTPURLResponse)?.statusCode == 200, json["access_token"] != nil else {
            throw GoogleError.server(json["error_description"] as? String ?? "Google didn't sign you in.")
        }
        return json
    }

    // MARK: picking

    /// Opens Google Photos' Picker in the browser, waits until photos have been picked, and
    /// returns them. `status` says what's happening.
    func pick(status: @escaping @Sendable (String) -> Void) async throws -> [PickedItem] {
        let session = try await api("POST", "sessions", body: Data("{}".utf8))
        guard let id = session["id"] as? String, let picker = session["pickerUri"] as? String,
              let pickerURL = URL(string: picker + "/autoclose") else { throw GoogleError.server("Google Photos didn't open the picker.") }
        let polling = session["pollingConfig"] as? [String: Any]
        let interval = Self.seconds(polling?["pollInterval"] as? String) ?? 5
        let deadline = Date().addingTimeInterval(Self.seconds(polling?["timeoutIn"] as? String) ?? 1800)
        await MainActor.run { _ = NSWorkspace.shared.open(pickerURL) }
        status("Pick photos in the Google Photos window that opened, then click Done.")

        defer { Task { _ = try? await self.api("DELETE", "sessions/\(id)") } }
        while true {
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            if Date() > deadline { throw GoogleError.timedOut }
            if try await api("GET", "sessions/\(id)")["mediaItemsSet"] as? Bool == true { break }
        }

        status("Reading what you picked…")
        var items: [PickedItem] = []
        var pageToken: String?
        repeat {
            var path = "mediaItems?sessionId=\(id)&pageSize=100"
            if let pageToken { path += "&pageToken=\(pageToken)" }
            let page = try await api("GET", path)
            for entry in page["mediaItems"] as? [[String: Any]] ?? [] {
                guard let itemID = entry["id"] as? String, let file = entry["mediaFile"] as? [String: Any],
                      let base = file["baseUrl"] as? String else { continue }
                let meta = file["mediaFileMetadata"] as? [String: Any]
                items.append(PickedItem(
                    id: itemID, filename: file["filename"] as? String ?? "Photo",
                    created: Self.date(entry["createTime"] as? String),
                    width: Int(meta?["width"] as? Int ?? 0), height: Int(meta?["height"] as? Int ?? 0),
                    isVideo: (entry["type"] as? String) == "VIDEO", baseURL: base))
            }
            pageToken = page["nextPageToken"] as? String
        } while pageToken != nil
        for item in items { picked[item.id] = item }
        return items
    }

    private func api(_ method: String, _ path: String, body: Data? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://photospicker.googleapis.com/v1/\(path)")!)
        request.httpMethod = method
        request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
        if let body { request.httpBody = body; request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard let code = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(code) else {
            let message = (json["error"] as? [String: Any])?["message"] as? String
            throw GoogleError.server(message ?? "Google Photos didn't answer as expected.")
        }
        return json
    }

    // MARK: photos

    /// The picked photos as Sift's items, with fingerprints made from small previews.
    func items(for picks: [PickedItem], progress: @escaping @Sendable (Int, Int) -> Void) async -> [PhotoItem] {
        let photos = picks.filter { !$0.isVideo }
        var hashes: [String: [UInt64]] = [:]
        var done = 0
        await withTaskGroup(of: (String, [UInt64]?).self) { group in
            var next = 0
            func start() {
                guard next < photos.count else { return }
                let item = photos[next]
                next += 1
                group.addTask {
                    guard let image = await self.image(item.baseURL + "=w256-h256"),
                          let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                          let gray = PhotoLibrary.gray(cg, maxSide: 160) else { return (item.id, nil) }
                    return (item.id, Fingerprint.hash(gray: gray.pixels, width: gray.width, height: gray.height))
                }
            }
            for _ in 0..<6 { start() }
            for await (id, hash) in group {
                if let hash { hashes[id] = hash }
                done += 1
                progress(done, photos.count)
                start()
            }
        }
        return photos.map {
            PhotoItem(id: $0.id, name: $0.filename, date: $0.created, width: $0.width, height: $0.height, size: 0, hash: hashes[$0.id])
        }
    }

    /// Downloads the originals of picked items into a folder, returning the files made.
    func download(_ ids: [String], to folder: URL) async throws -> [URL] {
        let token = try await accessToken()
        var files: [URL] = []
        for id in ids {
            guard let item = picked[id], let url = URL(string: item.baseURL + (item.isVideo ? "=dv" : "=d")) else { continue }
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (temp, response) = try await URLSession.shared.download(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw GoogleError.server("Google Photos didn't send “\(item.filename)”.")
            }
            let target = PhotoLibrary.unused(folder.appendingPathComponent(item.filename))
            try FileManager.default.moveItem(at: temp, to: target)
            files.append(target)
        }
        return files
    }

    private func image(_ url: String) async -> NSImage? {
        guard let target = URL(string: url), let token = try? await accessToken() else { return nil }
        var request = URLRequest(url: target)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        return NSImage(data: data)
    }

    // MARK: small helpers

    private static func randomString(_ length: Int) -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return String((0..<length).map { _ in chars.randomElement()! })
    }

    /// "5s" or "1800s", as Google writes durations.
    private static func seconds(_ text: String?) -> Double? {
        text.flatMap { Double($0.replacingOccurrences(of: "s", with: "")) }
    }

    private static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}

extension GoogleLibrary: MediaProvider {
    func thumbnail(_ id: String, side: CGFloat, done: @escaping (NSImage?) -> Void) -> (() -> Void)? {
        guard let item = picked[id] else { done(nil); return nil }
        let size = Int(side * 2)
        let task = Task {
            let image = await image(item.baseURL + "=w\(size)-h\(size)")
            await MainActor.run { done(image) }
        }
        return { task.cancel() }
    }

    func fullImage(_ id: String, progress: @escaping (Double) -> Void) async -> (NSImage?, Bool) {
        guard let item = picked[id] else { return (nil, false) }
        let image = await image(item.baseURL + "=w4096-h4096")
        return (image, image != nil)
    }

    func playerItem(_ id: String) async -> AVPlayerItem? { nil }
    func delete(_ ids: [String]) async -> Bool { false }
    var canDelete: Bool { false }
    var deleteNote: String { "" }
}

/// Google's sign-in tokens, kept in the Keychain.
struct Tokens: Codable {
    var access: String
    var refresh: String?
    var expires: Date
    var email: String?

    init(_ reply: [String: Any], keepingRefresh old: Tokens?) {
        access = reply["access_token"] as? String ?? ""
        refresh = reply["refresh_token"] as? String ?? old?.refresh
        expires = Date().addingTimeInterval(reply["expires_in"] as? Double ?? 3600)
        email = Self.email(fromIDToken: reply["id_token"] as? String) ?? old?.email
    }

    /// The email address inside Google's ID token (the middle part of a JSON Web Token).
    private static func email(fromIDToken token: String?) -> String? {
        guard let part = token?.split(separator: ".").dropFirst().first else { return nil }
        var base64 = part.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["email"] as? String
    }
}

enum Keychain {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "Sift Google Photos",
        kSecAttrAccount as String: "tokens",
    ]

    static func save(_ tokens: Tokens) {
        guard let data = try? JSONEncoder().encode(tokens) else { return }
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = data
        SecItemAdd(item as CFDictionary, nil)
    }

    static func load() -> Tokens? {
        var search = query
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(search as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(Tokens.self, from: data)
    }

    static func delete() {
        SecItemDelete(query as CFDictionary)
    }
}

private extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
