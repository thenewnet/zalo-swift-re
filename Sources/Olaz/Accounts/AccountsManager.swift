import Foundation
import Observation

/// Several Zalo accounts signed in at once, each a full `ZaloEngine` on its own `AccountScope`.
///
/// Every engine runs a complete copy of the official renderer (main window + hidden shared-worker window), so memory
/// is the limit, not the protocol. At most `maxLiveAccounts` engines run; the least recently used one beyond that is
/// put to sleep (`ZaloEngine.shutdown`, sign-in kept) and wakes when the user switches back to it. Engines that are
/// not on screen are told so (`setBackground`) and refresh their lists less often.
@MainActor
@Observable
final class AccountsManager {
    struct Account: Identifiable, Codable, Equatable {
        let id: UUID
        /// Last known profile, shown while the engine sleeps.
        var displayName: String
        var avatar: URL?
        var notificationsEnabled = true
        var lastUsed: Date
    }

    private(set) var accounts: [Account] = []
    private(set) var engines: [UUID: ZaloEngine] = [:]
    private(set) var activeID: UUID?
    /// Accounts whose engine may run at the same time (the active one included).
    var maxLiveAccounts: Int = AccountsManager.defaultMaxLive {
        didSet { UserDefaults.standard.set(maxLiveAccounts, forKey: Keys.maxLive); enforceLiveLimit() }
    }

    static var defaultMaxLive: Int {
        // ~1 GB of RAM per live renderer pair is a safe budget; never fewer than 2.
        let gb = Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)
        return max(2, min(5, gb / 2))
    }

    private enum Keys {
        static let accounts = "olaz.accounts.v1"
        static let active = "olaz.accounts.active"
        static let maxLive = "olaz.accounts.maxLive"
    }

    init() {
        if let stored = UserDefaults.standard.object(forKey: Keys.maxLive) as? Int { maxLiveAccounts = stored }
        if let data = UserDefaults.standard.data(forKey: Keys.accounts),
           let decoded = try? JSONDecoder().decode([Account].self, from: data) {
            accounts = decoded
        }
        let saved = UserDefaults.standard.string(forKey: Keys.active).flatMap(UUID.init(uuidString:))
        activeID = accounts.first { $0.id == saved }?.id ?? accounts.first?.id
    }

    // MARK: Queries

    var activeEngine: ZaloEngine? { activeID.flatMap { engines[$0] } }
    func engine(for id: UUID) -> ZaloEngine? { engines[id] }
    func account(for id: UUID) -> Account? { accounts.first { $0.id == id } }
    func isLive(_ id: UUID) -> Bool { engines[id]?.isRunning == true }

    func unread(for id: UUID) -> Int {
        engines[id]?.conversations.reduce(0) { $0 + $1.unread } ?? 0
    }

    var totalUnread: Int { accounts.reduce(0) { $0 + unread(for: $1.id) } }

    // MARK: Lifecycle

    /// Starts the active account (and the other recently used ones, up to the live limit).
    func start() {
        if accounts.isEmpty { addAccount() ; return }
        let order = accounts.sorted { $0.lastUsed > $1.lastUsed }.map(\.id)
        for id in order.prefix(maxLiveAccounts) { ensureEngine(id).start() }
        if let activeID { activate(activeID) }
    }

    @discardableResult
    func addAccount() -> UUID {
        let account = Account(id: UUID(), displayName: "", avatar: nil, lastUsed: Date())
        accounts.append(account)
        save()
        activate(account.id)
        return account.id
    }

    func activate(_ id: UUID) {
        guard accounts.contains(where: { $0.id == id }) else { return }
        activeID = id
        UserDefaults.standard.set(id.uuidString, forKey: Keys.active)
        touch(id)
        let engine = ensureEngine(id)
        if !engine.isRunning { engine.start() }
        for (other, e) in engines { e.setBackground(other != id) }
        enforceLiveLimit()
    }

    /// Signs the account out of this device and deletes its data (cookies, WebKit storage, files, Keychain items).
    func remove(_ id: UUID) async {
        if let engine = engines.removeValue(forKey: id) {
            engine.logOutQuietly()
            engine.shutdown()
            await engine.scope.destroy()
        } else {
            await AccountScope(id: id).destroy()
        }
        accounts.removeAll { $0.id == id }
        save()
        if activeID == id {
            activeID = nil
            if let next = accounts.sorted(by: { $0.lastUsed > $1.lastUsed }).first { activate(next.id) }
        }
    }

    func setNotifications(_ id: UUID, enabled: Bool) {
        guard let i = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[i].notificationsEnabled = enabled
        save()
    }

    func move(from source: IndexSet, to destination: Int) {
        accounts.move(fromOffsets: source, toOffset: destination)
        save()
    }

    /// App went to the background: every engine counts as off screen; cookies are flushed.
    func appDidEnterBackground() {
        for engine in engines.values {
            engine.setBackground(true)
            engine.scope.saveCookiesNow()
        }
    }

    func appWillEnterForeground() {
        if let activeID { engines[activeID]?.setBackground(false) }
    }

    /// The system is short on memory: put every account but the active one to sleep.
    func handleMemoryWarning() {
        for (id, engine) in engines where id != activeID && engine.isRunning {
            engine.shutdown()
        }
    }

    /// Profile of a running engine changed: remember it for the switcher while that engine sleeps.
    func noteProfile(of id: UUID) {
        guard let profile = engines[id]?.profile, let i = accounts.firstIndex(where: { $0.id == id }) else { return }
        guard accounts[i].displayName != profile.displayName || accounts[i].avatar != profile.avatar else { return }
        accounts[i].displayName = profile.displayName
        accounts[i].avatar = profile.avatar
        save()
    }

    // MARK: Private

    private func ensureEngine(_ id: UUID) -> ZaloEngine {
        if let engine = engines[id] { return engine }
        let engine = ZaloEngine(scope: AccountScope(id: id))
        engine.accountID = id
        engines[id] = engine
        observeProfile(id)
        return engine
    }

    private func observeProfile(_ id: UUID) {
        withObservationTracking {
            _ = engines[id]?.profile
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.engines[id] != nil else { return }
                self.noteProfile(of: id)
                self.observeProfile(id)
            }
        }
    }

    private func enforceLiveLimit() {
        let live = accounts.filter { isLive($0.id) }.sorted { $0.lastUsed > $1.lastUsed }
        guard live.count > maxLiveAccounts else { return }
        for account in live.dropFirst(maxLiveAccounts) where account.id != activeID {
            engines[account.id]?.shutdown()
        }
    }

    private func touch(_ id: UUID) {
        guard let i = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[i].lastUsed = Date()
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(accounts) { UserDefaults.standard.set(data, forKey: Keys.accounts) }
    }
}
