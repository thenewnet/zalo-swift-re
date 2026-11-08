import Foundation
import Observation

/// Several Zalo accounts signed in at once, each a full `ZaloEngine` on its own `AccountScope`.
///
/// Realtime for every account: by default **all** accounts stay connected at the same time (their own WebSocket,
/// their own notifications), whether on screen or not. Engines that are not on screen are told so (`setBackground`):
/// the official client then treats them like a background window, notifies for them, and the list adapter refreshes
/// less often. Every engine is a full copy of the official renderer, so on memory pressure the accounts that are not on
/// screen are put to sleep (`ZaloEngine.shutdown`, sign-in kept) and woken again shortly after. `maxLiveAccounts`
/// (0 = no limit) lets the user cap how many run at once on a small device.
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
    /// Accounts whose engine may run at the same time (the active one included); 0 = all of them (realtime for all).
    var maxLiveAccounts: Int = 0 {
        didSet { UserDefaults.standard.set(maxLiveAccounts, forKey: Keys.maxLive); enforceLiveLimit() }
    }

    /// Accounts put to sleep by a memory warning, woken again after `wakeDelay`.
    @ObservationIgnored private var sleptForMemory: Set<UUID> = []
    @ObservationIgnored private var wakeTask: Task<Void, Never>?
    @ObservationIgnored private var memoryWarnings: [Date] = []
    private static let wakeDelay: Duration = .seconds(90)

    private var liveLimit: Int { maxLiveAccounts > 0 ? maxLiveAccounts : Int.max }

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
        NativeNotifier.shared.onOpenAccount = { [weak self] engine in
            guard let self, let id = engine.accountID else { return }
            self.activate(id)
        }
        let order = accounts.sorted { $0.lastUsed > $1.lastUsed }.map(\.id)
        for id in order.prefix(liveLimit) { ensureEngine(id).start() }
        observeUnread()
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
        NativeNotifier.shared.foregroundEngine = engine
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
        engines[id]?.notificationsEnabledForAccount = enabled
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
        // Accounts that went to sleep (memory) or whose connection iOS dropped come back now.
        for account in accounts.sorted(by: { $0.lastUsed > $1.lastUsed }).prefix(liveLimit) {
            let engine = ensureEngine(account.id)
            if !engine.isRunning { engine.start() }
        }
        sleptForMemory.removeAll()
    }

    /// The system is short on memory: put the accounts that are not on screen to sleep, and wake them again a little
    /// later so they stay realtime. Three warnings within ten minutes keep them asleep until the app comes back.
    func handleMemoryWarning() {
        let now = Date()
        memoryWarnings = memoryWarnings.filter { now.timeIntervalSince($0) < 600 } + [now]
        for (id, engine) in engines where id != activeID && engine.isRunning {
            engine.shutdown()
            sleptForMemory.insert(id)
        }
        wakeTask?.cancel()
        guard memoryWarnings.count < 3 else { return }
        wakeTask = Task { [weak self] in
            try? await Task.sleep(for: Self.wakeDelay)
            guard !Task.isCancelled, let self else { return }
            // One at a time, so waking does not itself cause the next warning.
            for id in self.sleptForMemory {
                guard !Task.isCancelled else { return }
                self.engines[id]?.start()
                self.engines[id]?.setBackground(true)
                self.sleptForMemory.remove(id)
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    /// Unread over all accounts on the app icon.
    private func observeUnread() {
        withObservationTracking {
            _ = totalUnread
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                NativeNotifier.shared.setBadge(self.totalUnread)
                self.observeUnread()
            }
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
        engine.notificationsEnabledForAccount = account(for: id)?.notificationsEnabled ?? true
        engine.setBackground(id != activeID)
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
        guard live.count > liveLimit else { return }
        for account in live.dropFirst(liveLimit) where account.id != activeID {
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
