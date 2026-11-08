#if os(macOS)
import AppKit
#else
import UIKit
import AVFoundation
#endif
import Observation
import UniformTypeIdentifiers
@preconcurrency import UserNotifications
import os

private let notifierLog = Logger(subsystem: "app.olaz", category: "notifications")

// MARK: - Pure logic (unit tested in NotificationTests.swift)

/// What the official renderer hands to `$znoti.createNotification(title, options)` — Electron's
/// `Notification` constructor arguments (`HostScripts/notification-adapter.js` forwards the web
/// `Notification(title, {body, icon, tag, silent})` of the official OOAN notifier unchanged).
struct NativeNotificationRequest: Equatable {
    enum Icon: Equatable {
        /// `https://…` avatar (1-1 contact).
        case remote(URL)
        /// `data:image/png;base64,…` (group mosaics are rendered to a canvas by the official code).
        case inline(Data)
        /// Relative asset of the client bundle, e.g. `assets/avatar_stranger_notif.<hash>.png`.
        case bundled(String)
    }

    var title: String
    var body: String
    /// Conversation id (`fromUid` for 1-1, `g…` for groups): the official click handler opens it.
    var tag: String
    var silent: Bool
    var icon: Icon?

    static func parse(_ args: [Any]) -> NativeNotificationRequest? {
        let title = args.string(0) ?? ""
        let options = args.dict(1) ?? [:]
        let body = options["body"] as? String ?? ""
        guard !title.isEmpty || !body.isEmpty else { return nil }
        let tag: String
        switch options["tag"] {
        case let text as String: tag = text
        case let number as NSNumber: tag = number.stringValue
        default: tag = ""
        }
        return NativeNotificationRequest(
            title: title, body: body, tag: tag,
            silent: (options["silent"] as? NSNumber)?.boolValue ?? false,
            icon: (options["icon"] as? String).flatMap(parseIcon)
        )
    }

    static func parseIcon(_ raw: String) -> Icon? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return nil }
        if text.hasPrefix("data:") {
            guard let comma = text.firstIndex(of: ","), text[..<comma].contains(";base64"),
                  let data = Data(base64Encoded: String(text[text.index(after: comma)...])), !data.isEmpty else { return nil }
            return .inline(data)
        }
        if let url = URL(string: text), url.scheme == "https" || url.scheme == "http", url.host() != nil {
            return .remote(url)
        }
        if text.contains("://") { return nil }
        // Relative asset path (strip cache-busting query).
        let path = text.split(separator: "?", maxSplits: 1).first.map(String.init) ?? text
        return path.isEmpty ? nil : .bundled(path)
    }
}

enum NotificationPolicy {
    /// The official client also hides banners while the app is focused (FocusDetector). That detector
    /// is fed from the native window (`NativeNotifier.startFocusBridge`); this is the native backstop for
    /// the one case that must never notify: the user is looking at the very conversation the message is in.
    static func shouldSuppress(appIsActive: Bool, mainWindowVisible: Bool, openConversation: String?,
                               tag: String, userIdleSeconds: TimeInterval, idleThreshold: TimeInterval = 180) -> Bool {
        guard appIsActive, mainWindowVisible, !tag.isEmpty, openConversation == tag else { return false }
        return userIdleSeconds < idleThreshold
    }

    /// The banner's inline "Trả lời" must not send into a hidden chat that is locked, nor while the hidden state is still unknown.
    static func refusesReply(hiddenStateKnown: Bool, conversationLocked: Bool) -> Bool { !hiddenStateKnown || conversationLocked }

    /// Conversations that became hidden between two snapshots (their delivered banners are removed).
    static func newlyHidden(old: Set<String>, new: Set<String>) -> Set<String> { new.subtracting(old) }

    /// Official text for a message whose content must stay hidden (app lock: `STR_PASS_CODE_NOTIFY_MESSAGE`).
    static let hiddenPreviewBody = "Bạn có tin nhắn mới"

    static func body(_ body: String, showsPreview: Bool) -> String { showsPreview ? body : hiddenPreviewBody }

    /// Image type UNNotificationAttachment accepts, sniffed from the bytes (the CDN URLs have no extension).
    static func attachmentType(for data: Data) -> (type: UTType, ext: String)? {
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return (.png, "png") }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return (.jpeg, "jpg") }
        if bytes.starts(with: [0x47, 0x49, 0x46, 0x38]) { return (.gif, "gif") }
        return nil
    }

    /// Only Zalo CDN hosts over https may be fetched for the notification sound.
    static func isSoundURLAllowed(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host() else { return false }
        return MediaLoader.isZaloCDN(host) && url.path().hasSuffix("/sound/noti.mp3")
    }
}

// MARK: - UNUserNotificationCenter bridge

/// Renders the official client's notifications as native banners, for **every** signed-in account.
///
/// The official renderer decides when to notify (settings, mutes, app focus…) and calls
/// `$znoti.createNotification` / `closeNotification` (channels `_noti_*`, installed on each bridge by
/// `ZaloMainProcess`). This class answers them with `UNUserNotificationCenter` and pushes `_noti_on-show`
/// / `_noti_on-click` / `_noti_on-close` back so the official callbacks run (open conversation, timers).
///
/// Multi-account: each engine registers itself (`attach`), keyed by its `AccountScope`. Banners carry the account
/// (`userInfo["account"]`, thread `"<account>|<conversation>"`, subtitle = account name), so taps and inline replies
/// go to the right account. Only the account on screen (`foregroundEngine`) is told "focus"; the others get "blur",
/// so the official FocusDetector treats them as background windows and notifies for them, exactly like a second
/// Zalo PC window that is not in front.
@MainActor
final class NativeNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NativeNotifier()

    static let messageCategory = "app.olaz.message"
    static let replyAction = "app.olaz.message.reply"
    /// Title of the development renderer window — never the user-facing window.
    private static let debugWindowTitle = "Zalo renderer (debug)"

    private final class WeakEngine { weak var engine: ZaloEngine?; init(_ engine: ZaloEngine) { self.engine = engine } }
    /// Engines by `ObjectIdentifier(engine.scope)`.
    private var engines: [ObjectIdentifier: WeakEngine] = [:]
    /// The account whose UI is on screen. nil with a single account means "that one".
    weak var foregroundEngine: ZaloEngine? {
        didSet { if oldValue !== foregroundEngine { sendFocusToAll() } }
    }
    /// Asks the app to switch to an account (banner tapped for an account that is not on screen).
    var onOpenAccount: ((ZaloEngine) -> Void)?

    /// Single-account callers (and fallbacks): the engine on screen, else any attached one.
    var engine: ZaloEngine? { foregroundEngine ?? liveEngines.first }
    private var liveEngines: [ZaloEngine] {
        engines = engines.filter { $0.value.engine != nil }
        return engines.values.compactMap(\.engine)
    }

    private struct Live {
        weak var bridge: ZaloBridge?
        weak var engine: ZaloEngine?
        var tag: String
    }
    private var live: [String: Live] = [:]
    private var focusObservers: [NSObjectProtocol] = []
    private var activityMonitor: Any?
    private var lastActivityPush = Date.distantPast
    #if os(macOS)
    private var sounds: [NSSound] = []
    #else
    private var sounds: [AVAudioPlayer] = []
    #endif
    private var attached = false
    private var orphanDrafts = FailedDraftStore()
    private var knownHidden: [ObjectIdentifier: Set<String>] = [:]
    private var observed: Set<ObjectIdentifier> = []

    /// `UNUserNotificationCenter.current()` traps outside an app bundle (tests, `swift run`, probe).
    var isAvailable: Bool { Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil }
    private var center: UNUserNotificationCenter? { isAvailable ? UNUserNotificationCenter.current() : nil }

    // MARK: Platform

    private var appIsActive: Bool {
        #if os(macOS)
        NSApp.isActive
        #else
        UIApplication.shared.applicationState == .active
        #endif
    }

    private var mainWindowVisible: Bool {
        #if os(macOS)
        mainWindow()?.isVisible == true && mainWindow()?.isMiniaturized == false
        #else
        true
        #endif
    }

    private func engine(for scope: AccountScope) -> ZaloEngine? { engines[ObjectIdentifier(scope)]?.engine }

    private func engine(account: String?) -> ZaloEngine? {
        guard let account, let id = UUID(uuidString: account) else { return nil }
        return liveEngines.first { $0.accountID == id }
    }

    private func isOnScreen(_ engine: ZaloEngine?) -> Bool {
        guard let engine else { return false }
        if let foregroundEngine { return foregroundEngine === engine }
        return liveEngines.count <= 1
    }

    /// Notification thread of a conversation: per account when several run, so banners never mix.
    private func thread(_ tag: String, engine: ZaloEngine?) -> String {
        let conv = tag.isEmpty ? "zalo" : tag
        guard let id = engine?.accountID else { return conv }
        return id.uuidString + "|" + conv
    }

    // MARK: IPC (Electron `Notification` → `_noti_*`)

    static func installIPC(on bridge: ZaloBridge, scope: AccountScope = .legacy) {
        bridge.handle("_noti_is-supported") { _ in NativeNotifier.shared.isAvailable }
        bridge.handle("_noti_create") { [weak bridge] args in NativeNotifier.shared.create(args, bridge: bridge, scope: scope) }
        bridge.handle("_noti_close") { args in
            NativeNotifier.shared.close(id: args.string(0))
            return nil
        }
    }

    private func create(_ args: [Any], bridge: ZaloBridge?, scope: AccountScope) -> String? {
        guard isAvailable, let request = NativeNotificationRequest.parse(args) else { return nil }
        let owner = engine(for: scope)
        if let owner, !owner.notificationsEnabledForAccount { return nil }
        let id = UUID().uuidString
        live[id] = Live(bridge: bridge, engine: owner, tag: request.tag)
        Task { await deliver(request, id: id, engine: owner) }
        return id
    }

    /// The official code closes its notification after ~10 s, when a newer one for the same conversation replaces it,
    /// and on click. A banner leaves the screen by itself and its history belongs in Notification Center, so this only
    /// acknowledges the close to the renderer; delivered notifications are removed when the conversation is opened.
    private func close(id: String?) {
        guard let id, let entry = live[id] else { return }
        push("_noti_on-close", id: id, entry: entry)
        live[id] = nil
    }

    /// Drops the banners of a conversation the user has now opened (in that account).
    func clearDelivered(conversation id: String, engine: ZaloEngine? = nil) {
        guard isAvailable, !id.isEmpty else { return }
        let threadID = thread(id, engine: engine ?? self.engine)
        UNUserNotificationCenter.current().getDeliveredNotifications { delivered in
            let ids = delivered.filter { $0.request.content.threadIdentifier == threadID }.map(\.request.identifier)
            if !ids.isEmpty { UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids) }
        }
    }

    private func push(_ channel: String, id: String, entry: Live?) {
        let bridge = entry?.bridge ?? entry?.engine?.host?.bridge ?? engine?.host?.bridge
        bridge?.send(channel, [["id": id, "tag": entry?.tag ?? ""]])
    }

    // MARK: Delivery

    private func deliver(_ request: NativeNotificationRequest, id: String, engine owner: ZaloEngine?) async {
        guard let center else { return }
        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional else {
            notifierLog.info("notification dropped: authorization \(status.rawValue)")
            live[id] = nil
            return
        }
        if NotificationPolicy.shouldSuppress(
            appIsActive: appIsActive && isOnScreen(owner), mainWindowVisible: mainWindowVisible,
            openConversation: owner?.openConversationId, tag: request.tag, userIdleSeconds: Self.userIdleSeconds()) {
            notifierLog.info("notification suppressed: conversation is open and the app is in use")
            return
        }

        let showsPreview = UserDefaults.standard.object(forKey: NotificationSettingsState.previewDefaultsKey) as? Bool ?? true
        let content = UNMutableNotificationContent()
        content.title = request.title
        if liveEngines.count > 1, let name = owner?.profile?.displayName, !name.isEmpty { content.subtitle = name }
        content.body = NotificationPolicy.body(request.body, showsPreview: showsPreview)
        content.threadIdentifier = thread(request.tag, engine: owner)
        content.categoryIdentifier = Self.messageCategory
        var info: [String: Any] = ["convId": request.tag, "id": id]
        if let account = owner?.accountID { info["account"] = account.uuidString }
        content.userInfo = info
        if !request.silent { content.sound = .default }
        if let attachment = await avatarAttachment(for: request.icon, engine: owner) { content.attachments = [attachment] }

        do {
            try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        } catch {
            notifierLog.error("add notification failed: \(error.localizedDescription, privacy: .public)")
            live[id] = nil
            return
        }
        if let entry = live[id] {
            // The renderer registers the id when `createNotification` resolves; let that happen first.
            try? await Task.sleep(for: .milliseconds(60))
            push("_noti_on-show", id: id, entry: entry)
        }
    }

    private func avatarAttachment(for icon: NativeNotificationRequest.Icon?, engine owner: ZaloEngine?) async -> UNNotificationAttachment? {
        guard let icon else { return nil }
        let data: Data?
        switch icon {
        case .inline(let bytes): data = bytes
        case .bundled(let path): data = (owner ?? engine)?.host?.install.asar.read("pc-dist/" + path)
        case .remote(let url):
            data = await Self.withTimeout(seconds: 3) {
                guard let file = try? await MediaLoader.shared.localFile(for: url) else { return nil }
                return try? Data(contentsOf: file)
            } ?? nil
        }
        guard let data, let kind = NotificationPolicy.attachmentType(for: data) else { return nil }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OlazNotifications", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(UUID().uuidString + "." + kind.ext)
        do {
            try data.write(to: file)
            return try UNNotificationAttachment(identifier: "avatar", url: file,
                                                options: [UNNotificationAttachmentOptionsTypeHintKey: kind.type.identifier])
        } catch {
            try? FileManager.default.removeItem(at: file)
            return nil
        }
    }

    private static func withTimeout<T: Sendable>(seconds: Double, _ work: @escaping @Sendable () async -> T) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await work() }
            group.addTask { try? await Task.sleep(for: .seconds(seconds)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    // MARK: Badge

    /// App icon badge = unread over every account (iOS; macOS keeps the official `badge` path).
    func setBadge(_ count: Int) {
        guard let center else { return }
        Task { try? await center.setBadgeCount(count) }
    }

    // MARK: Authorization

    enum Authorization { case unavailable, notDetermined, denied, authorized }

    func authorizationStatus() async -> Authorization {
        guard let center else { return .unavailable }
        switch await center.notificationSettings().authorizationStatus {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        default: return .authorized
        }
    }

    @discardableResult
    func requestAuthorization() async -> Authorization {
        guard let center else { return .unavailable }
        do {
            _ = try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            notifierLog.error("requestAuthorization failed: \(error.localizedDescription, privacy: .public)")
        }
        return await authorizationStatus()
    }

    private func postSendFailure(convId: String, engine owner: ZaloEngine?) async {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = "Chưa gửi được tin nhắn trả lời"
        content.body = "Nội dung được giữ lại trong ô soạn thảo của hội thoại. Mở để gửi lại."
        content.threadIdentifier = thread(convId, engine: owner)
        var info: [String: Any] = ["convId": convId]
        if let account = owner?.accountID { info["account"] = account.uuidString }
        content.userInfo = info
        do { try await center.add(UNNotificationRequest(identifier: "sendfail-" + UUID().uuidString, content: content, trigger: nil)) }
        catch { notifierLog.error("send-failure notification failed: \(error.localizedDescription, privacy: .public)") }
    }

    // MARK: Lifecycle

    /// Called when an engine's main renderer reports `ready` (first and every later page load).
    func attach(engine: ZaloEngine) {
        let key = ObjectIdentifier(engine.scope)
        engines[key] = WeakEngine(engine)
        for (id, draft) in orphanDrafts.drain() { engine.failedDrafts.stash(draft, for: id) }
        if !observed.contains(key) {
            observed.insert(key)
            observeOpenConversation(engine)
            observeHiddenConversations(engine)
        }
        sendFocus(to: engine)
        guard isAvailable, !attached else { return }
        attached = true
        let reply = UNTextInputNotificationAction(
            identifier: Self.replyAction, title: "Trả lời", options: [],
            textInputButtonTitle: "Gửi", textInputPlaceholder: "Nhập tin nhắn…")
        let category = UNNotificationCategory(identifier: Self.messageCategory, actions: [reply], intentIdentifiers: [],
                                              options: [.hiddenPreviewsShowTitle])
        center?.setNotificationCategories([category])
        center?.delegate = self
        startFocusBridge()
    }

    /// An engine that went to sleep or was removed.
    func detach(engine: ZaloEngine) {
        let key = ObjectIdentifier(engine.scope)
        engines[key] = nil
        observed.remove(key)
        knownHidden[key] = nil
        if foregroundEngine === engine { foregroundEngine = nil }
    }

    /// A chat that becomes hidden (here or on another device) takes its banners out of Notification Center.
    private func observeHiddenConversations(_ engine: ZaloEngine) {
        let key = ObjectIdentifier(engine.scope)
        withObservationTracking {
            _ = engine.conversationActions.hiddenIds
        } onChange: { [weak self, weak engine] in
            Task { @MainActor in
                guard let self, let engine, self.observed.contains(key) else { return }
                let hidden = engine.conversationActions.hiddenIds
                for id in NotificationPolicy.newlyHidden(old: self.knownHidden[key] ?? [], new: hidden) {
                    self.clearDelivered(conversation: id, engine: engine)
                }
                self.knownHidden[key] = hidden
                self.observeHiddenConversations(engine)
            }
        }
    }

    private func observeOpenConversation(_ engine: ZaloEngine) {
        let key = ObjectIdentifier(engine.scope)
        withObservationTracking {
            _ = engine.openConversationId
        } onChange: { [weak self, weak engine] in
            Task { @MainActor in
                guard let self, let engine, self.observed.contains(key) else { return }
                if let id = engine.openConversationId { self.clearDelivered(conversation: id, engine: engine) }
                self.observeOpenConversation(engine)
            }
        }
    }

    /// Re-sends the current focus state (the page-load handler in `ZaloMainProcess` announces "focus" unconditionally).
    func syncFocusState() { sendFocusToAll() }

    // MARK: Focus bridge — the official FocusDetector decides "app is in use" from these events

    private func startFocusBridge() {
        #if os(macOS)
        let names: [Notification.Name] = [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification]
        #else
        let names: [Notification.Name] = [UIApplication.didBecomeActiveNotification, UIApplication.willResignActiveNotification,
                                          UIApplication.didEnterBackgroundNotification]
        #endif
        focusObservers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.sendFocusToAll() }
            }
        }
        #if os(macOS)
        activityMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown, .scrollWheel]) { [weak self] event in
            MainActor.assumeIsolated { self?.noteUserActivity() }
            return event
        }
        #endif
        sendFocusToAll()
    }

    private func sendFocusToAll() {
        for engine in liveEngines { sendFocus(to: engine) }
    }

    /// `webContents.send('visibility-change', 'focus'|'blur', windowId)` as Electron's main does for the main window.
    /// Only the account on screen, in an active app, is "focused".
    private func sendFocus(to engine: ZaloEngine) {
        let active = appIsActive && isOnScreen(engine)
        engine.host?.bridge.send("visibility-change", active ? ["focus", "1"] : ["blur", "1"])
        if active { Task { await engine.refreshNotificationAuthorization() } }
    }

    /// Touches on iOS / clicks on macOS count as activity for the account on screen.
    func noteUserActivity() {
        let now = Date()
        guard now.timeIntervalSince(lastActivityPush) >= 2 else { return }
        lastActivityPush = now
        engine?.callChat("activity", object: "__zaloNotification")
    }

    // MARK: Sound (official `noti.mp3`, requested by the renderer's own sound rules)

    func playNotificationSound(_ raw: String) {
        guard let url = URL(string: raw), NotificationPolicy.isSoundURLAllowed(url) else { return }
        Task {
            guard let file = try? await MediaLoader.shared.localFile(for: url) else { return }
            #if os(macOS)
            guard let sound = NSSound(contentsOf: file, byReference: true) else { return }
            sounds.removeAll { !$0.isPlaying }
            sounds.append(sound)
            sound.play()
            #else
            // In the background the banner's own sound plays; the in-app sound only when the app is in use.
            guard appIsActive, let player = try? AVAudioPlayer(contentsOf: file) else { return }
            sounds.removeAll { !$0.isPlaying }
            sounds.append(player)
            player.play()
            #endif
        }
    }

    // MARK: Helpers

    #if os(macOS)
    /// The app's chat window: not the debug renderer, a panel, or the media viewer.
    private func mainWindow() -> NSWindow? {
        NSApp.windows.first { $0.canBecomeMain && !($0 is NSPanel) && !($0 is MediaViewerWindow) && $0.title != Self.debugWindowTitle }
    }
    #endif

    func bringAppToFront() {
        #if os(macOS)
        NSApp.activate()
        if let window = mainWindow() {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        }
        #endif
    }

    nonisolated static func userIdleSeconds() -> TimeInterval {
        #if os(macOS)
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        #else
        0
        #endif
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let identifier = response.notification.request.identifier
        let info = response.notification.request.content.userInfo
        let convId = info["convId"] as? String ?? ""
        let account = info["account"] as? String
        let action = response.actionIdentifier
        let text = (response as? UNTextInputNotificationResponse)?.userText
        await MainActor.run {
            NativeNotifier.shared.handleResponse(id: identifier, convId: convId, account: account, action: action, text: text)
        }
    }

    private func handleResponse(id: String, convId: String, account: String?, action: String, text: String?) {
        let entry = live[id]
        let owner = entry?.engine ?? engine(account: account) ?? (account == nil ? engine : nil)
        switch action {
        case Self.replyAction:
            // Inline reply goes through the official send path of that account; the app stays in the background.
            if let text, !convId.isEmpty {
                Task {
                    let refused = owner.map { NotificationPolicy.refusesReply(hiddenStateKnown: $0.conversationActions.hiddenKnown,
                                                                              conversationLocked: $0.isConversationLocked(convId)) } ?? true
                    if !refused, let owner, await owner.sendText(text, to: convId) { return }
                    let draft = ComposerDraft(text: text)
                    if let owner { owner.failedDrafts.stash(draft, for: convId) } else { orphanDrafts.stash(draft, for: convId) }
                    if !(appIsActive && isOnScreen(owner) && owner?.openConversationId == convId) {
                        await postSendFailure(convId: convId, engine: owner)
                    }
                }
            }
        case UNNotificationDefaultActionIdentifier:
            bringAppToFront()
            if let owner, !isOnScreen(owner) { onOpenAccount?(owner) }
            if !convId.isEmpty { owner?.navigationRequest = convId }
            if entry != nil || !id.hasPrefix("sendfail-") { push("_noti_on-click", id: id, entry: entry) }
        default:
            break
        }
        if entry != nil { push("_noti_on-close", id: id, entry: entry) }
        if action == UNNotificationDefaultActionIdentifier { clearDelivered(conversation: convId, engine: owner) }
        live[id] = nil
    }
}
