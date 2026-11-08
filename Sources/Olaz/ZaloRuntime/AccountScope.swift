import Foundation
import WebKit
import os

private let scopeLog = Logger(subsystem: "app.olaz", category: "account-scope")

/// Everything one signed-in Zalo account owns on this device, so several accounts can run side by side without
/// seeing each other's session:
///
/// | Olaz single-account | per account                                                   |
/// |---------------------|---------------------------------------------------------------|
/// | `HTTPCookieStorage.shared` | `cookies`: a private jar persisted to `<root>/cookies.plist` |
/// | `WKWebsiteDataStore.default()` | `WKWebsiteDataStore(forIdentifier: id)` (IndexedDB, localStorage) |
/// | `Olaz/ZaloData`     | `Olaz/Accounts/<id>/ZaloData` (electron-store files, downloads) |
/// | Keychain `zprotocol.<x>` | `acct.<id>.zprotocol.<x>`                                   |
/// | UserDefaults `olaz.imei` | `olaz.imei.<id>`                                            |
///
/// `legacy` keeps the original single-account layout, so an existing macOS install stays signed in.
@MainActor
final class AccountScope {
    /// nil for the legacy (single, pre-multi-account) scope.
    let id: UUID?
    let root: URL
    let userData: URL
    let cookies: HTTPCookieStorage
    private let cookieFile: URL?
    private var saveTask: Task<Void, Never>?
    private var cookieObserver: NSObjectProtocol?

    static let legacy = AccountScope(userData: ZaloPlatform.defaultUserData)

    /// Single-account layout at `userData` with the shared cookie jar (the legacy scope; tests use their own folder).
    init(userData: URL) {
        id = nil
        self.userData = userData
        root = userData.deletingLastPathComponent()
        cookies = .shared
        cookieFile = nil
    }

    init(id: UUID) {
        self.id = id
        root = Self.accountsRoot.appendingPathComponent(id.uuidString, isDirectory: true)
        userData = root.appendingPathComponent("ZaloData", isDirectory: true)
        try? FileManager.default.createDirectory(at: userData, withIntermediateDirectories: true)
        // An ephemeral configuration hands out its own in-memory cookie storage, separate from `.shared`.
        cookies = URLSessionConfiguration.ephemeral.httpCookieStorage ?? HTTPCookieStorage()
        cookies.cookieAcceptPolicy = .always
        cookieFile = root.appendingPathComponent("cookies.plist")
        loadCookies()
        cookieObserver = NotificationCenter.default.addObserver(
            forName: .NSHTTPCookieManagerCookiesChanged, object: cookies, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleCookieSave() }
        }
    }

    static var accountsRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Olaz/Accounts", isDirectory: true)
    }

    var isLegacy: Bool { id == nil }

    /// WebKit storage of this account's pages (main window and hidden shared-worker window share it).
    func makeDataStore() -> WKWebsiteDataStore {
        if let id { return WKWebsiteDataStore(forIdentifier: id) }
        return .default()
    }

    var keychainPrefix: String { id.map { "acct.\($0.uuidString.lowercased())." } ?? "" }
    var imeiDefaultsKey: String { id.map { "olaz.imei.\($0.uuidString.lowercased())" } ?? "olaz.imei" }

    // MARK: Cookies

    /// Session cookies (no expiry) are kept too: the official client sets some of them and expects them after a relaunch,
    /// exactly as Electron's persistent partition does.
    func saveCookiesNow() {
        guard let cookieFile else { return }
        saveTask?.cancel()
        saveTask = nil
        let all = (cookies.cookies ?? []).compactMap { cookie -> [String: Any]? in
            guard let properties = cookie.properties else { return nil }
            return Dictionary(uniqueKeysWithValues: properties.map { ($0.key.rawValue, $0.value) })
        }
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: all, format: .binary, options: 0)
            #if os(iOS)
            try data.write(to: cookieFile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try data.write(to: cookieFile, options: .atomic)
            #endif
        } catch {
            scopeLog.error("cookie save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func scheduleCookieSave() {
        guard cookieFile != nil, saveTask == nil else { return }
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.saveTask = nil
            self?.saveCookiesNow()
        }
    }

    private func loadCookies() {
        guard let cookieFile, let data = try? Data(contentsOf: cookieFile),
              let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Any]] else { return }
        let now = Date()
        for raw in list {
            let properties = Dictionary(uniqueKeysWithValues: raw.map { (HTTPCookiePropertyKey($0.key), $0.value) })
            guard let cookie = HTTPCookie(properties: properties) else { continue }
            if let expires = cookie.expiresDate, expires < now { continue }
            cookies.setCookie(cookie)
        }
    }

    /// Deletes everything this account stored on the device. The scope must not be used afterwards.
    func destroy() async {
        guard let id else { return }
        if let cookieObserver { NotificationCenter.default.removeObserver(cookieObserver) }
        saveTask?.cancel()
        for cookie in cookies.cookies ?? [] { cookies.deleteCookie(cookie) }
        UserDefaults.standard.removeObject(forKey: imeiDefaultsKey)
        Keychain.deleteAll(prefix: keychainPrefix)
        try? FileManager.default.removeItem(at: root)
        // WebKit refuses to remove a store that a web view still uses; the engine is torn down first, retry briefly.
        for attempt in 0..<5 {
            do {
                try await WKWebsiteDataStore.remove(forIdentifier: id)
                return
            } catch {
                scopeLog.notice("data store busy (attempt \(attempt)): \(error.localizedDescription, privacy: .public)")
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }
}
