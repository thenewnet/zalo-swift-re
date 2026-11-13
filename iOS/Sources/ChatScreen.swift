import SwiftUI
import UIKit

/// One conversation: messages from the official client (newest at the bottom), older pages on scroll, a composer.
struct ChatScreen: View {
    let engine: ZaloEngine
    let conversationId: String
    @State private var draft = ""
    @State private var sending = false
    @State private var requestedOlderAt: String?
    @FocusState private var composerFocused: Bool

    private var messages: [ChatMessage] { engine.messages[conversationId] ?? [] }
    private var title: String {
        engine.conversations.first { $0.id == conversationId }?.displayName ?? "Hội thoại"
    }

    var body: some View {
        VStack(spacing: 0) {
            messageList
            Divider()
            composer
        }
        .modifier(CardNoticeToast(conversationId: conversationId))
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { engine.openConversation(conversationId) }
        .onDisappear { if engine.openConversationId == conversationId { engine.closeConversation() } }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 6) {
                    if engine.hasMoreHistory[conversationId] == true {
                        ProgressView()
                            .padding(8)
                            .onAppear { loadOlder() }
                    }
                    ForEach(messages) { message in
                        MobileMessageRow(message: message, engine: engine)
                            .id(message.id)
                    }
                    if let typing = engine.typing[conversationId] {
                        Text("\(typing) đang soạn tin…")
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal)
                            .id("typing")
                    }
                }
                .padding(.vertical, 8)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: messages.last?.id) { _, last in
                guard let last else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last, anchor: .bottom) }
            }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Nhập tin nhắn", text: $draft, axis: .vertical)
                .lineLimit(1...6)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
                .focused($composerFocused)
            Button {
                send()
            } label: {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 18))
                    .frame(width: 36, height: 36)
            }
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func loadOlder() {
        // One request per oldest message: the list shows the spinner again after the page arrives if more remain.
        let oldest = messages.first?.id ?? "-"
        guard requestedOlderAt != oldest else { return }
        requestedOlderAt = oldest
        engine.loadOlderMessages(conversationId)
    }

    private func send() {
        let text = draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        sending = true
        draft = ""
        Task {
            let ok = await engine.sendText(text, to: conversationId)
            if !ok { draft = text }
            sending = false
        }
    }
}

/// A compact iOS bubble for every message kind the engine knows. Photos open full screen, links open in Safari,
/// videos and voice messages play, files and locations open in the system apps; long-press offers copy.
struct MobileMessageRow: View {
    let message: ChatMessage
    let engine: ZaloEngine
    @Environment(\.openURL) private var openURL
    @State private var viewer: MediaViewerItem?

    var body: some View {
        if message.kind.isStandalone || message.kind == .system {
            Text(message.text.isEmpty ? summary : message.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
        } else {
            HStack(alignment: .bottom, spacing: 6) {
                if message.isMine { Spacer(minLength: 48) }
                if !message.isMine {
                    AccountAvatar(name: message.senderName, url: message.senderAvatar, size: 28)
                }
                VStack(alignment: message.isMine ? .trailing : .leading, spacing: 2) {
                    if !message.isMine, !message.senderName.isEmpty {
                        Text(message.senderName).font(.caption2).foregroundStyle(.secondary)
                    }
                    bubble
                        .contextMenu { menu }
                    if !message.reactions.isEmpty {
                        Text(message.reactions.map(\.icon.emoji).joined())
                            .font(.caption)
                    }
                }
                if !message.isMine { Spacer(minLength: 48) }
            }
            .padding(.horizontal, 10)
            .fullScreenCover(item: $viewer) { item in MediaViewer(item: item) }
        }
    }

    // MARK: Bubbles

    @ViewBuilder
    private var bubble: some View {
        switch message.kind {
        case .photo(let url, let width, let height):
            Button { viewer = .image(url) } label: {
                media(url, aspect: width > 0 && height > 0 ? CGFloat(width) / CGFloat(height) : 1)
            }
            .buttonStyle(.plain)
        case .gif(let url):
            Button { viewer = .image(url) } label: {
                AsyncImage(url: url) { $0.resizable().scaledToFit() } placeholder: { Color.clear }
                    .frame(width: 160, height: 160)
            }
            .buttonStyle(.plain)
        case .sticker(let url):
            AsyncImage(url: url) { $0.resizable().scaledToFit() } placeholder: { Color.clear }
                .frame(width: 120, height: 120)
        case .video(let thumbnail, let duration, let url):
            Button { if let url { viewer = .video(url) } } label: {
                ZStack {
                    media(thumbnail, aspect: 16 / 9)
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.white, .black.opacity(0.35))
                    if duration > 0 {
                        Text(Self.clock(duration))
                            .font(.caption2.monospacedDigit()).foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.black.opacity(0.5), in: Capsule())
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                            .padding(8)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(url == nil)
        case .voice(let url, let duration):
            VoiceBubble(url: url, duration: duration, isMine: message.isMine)
        case .file(let name, let size, let url):
            Button { open(url) } label: {
                HStack(spacing: 10) {
                    Image(systemName: "doc.fill").font(.title2).foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name.isEmpty ? "Tệp" : name).lineLimit(2).foregroundStyle(.primary)
                        if size > 0 {
                            Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Image(systemName: "arrow.down.circle").foregroundStyle(.secondary)
                }
                .padding(10)
                .frame(maxWidth: 260, alignment: .leading)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
        case .link(let title, let url, let thumbnail, let description, let source):
            Button { open(url) } label: {
                VStack(alignment: .leading, spacing: 0) {
                    if !message.text.isEmpty, message.text != url?.absoluteString {
                        Text(linkified(message.text)).padding(10)
                    }
                    if let thumbnail {
                        AsyncImage(url: thumbnail) { $0.resizable().scaledToFill() } placeholder: {
                            Rectangle().fill(Color(.tertiarySystemFill))
                        }
                        .frame(width: 240, height: 126).clipped()
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title.isEmpty ? (url?.absoluteString ?? "") : title)
                            .font(.subheadline.weight(.semibold)).lineLimit(2).foregroundStyle(.primary)
                        if !description.isEmpty {
                            Text(description).font(.caption).lineLimit(2).foregroundStyle(.secondary)
                        }
                        Text(source.isEmpty ? (url?.host() ?? "") : source)
                            .font(.caption2).foregroundStyle(Color.accentColor)
                    }
                    .padding(10)
                }
                .frame(width: 240, alignment: .leading)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
        case .location(let info):
            Button { openMap(info) } label: {
                HStack(spacing: 10) {
                    Image(systemName: "mappin.circle.fill").font(.title).foregroundStyle(.red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(info.title.isEmpty ? "Vị trí" : info.title).foregroundStyle(.primary).lineLimit(2)
                        if !info.address.isEmpty {
                            Text(info.address).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: 260, alignment: .leading)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
        case .recalled:
            textBubble(AttributedString("Tin nhắn đã được thu hồi"), italic: true)
        default:
            if message.text.isEmpty {
                textBubble(AttributedString(summary), italic: true)
            } else {
                textBubble(linkified(message.text))
            }
        }
    }

    private func media(_ url: URL?, aspect: CGFloat) -> some View {
        AsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: {
            Rectangle().fill(Color(.tertiarySystemFill))
        }
        .frame(width: 220, height: min(320, 220 / max(aspect, 0.3)))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .contentShape(RoundedRectangle(cornerRadius: 14))
    }

    private func textBubble(_ text: AttributedString, italic: Bool = false) -> some View {
        Text(text)
            .italic(italic)
            .tint(message.isMine ? .white : .accentColor)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .foregroundStyle(message.isMine ? .white : .primary)
            .background(message.isMine ? Color.accentColor : Color(.secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 18))
            .environment(\.openURL, OpenURLAction { url in
                open(url)
                return .handled
            })
    }

    // MARK: Long-press menu

    @ViewBuilder
    private var menu: some View {
        if !message.text.isEmpty {
            Button { PlatformServices.copy(message.text) } label: { Label("Sao chép", systemImage: "doc.on.doc") }
        }
        if let link = primaryURL {
            Button { open(link) } label: { Label("Mở liên kết", systemImage: "safari") }
            Button { PlatformServices.copy(link.absoluteString) } label: { Label("Sao chép liên kết", systemImage: "link") }
            ShareLink(item: link) { Label("Chia sẻ", systemImage: "square.and.arrow.up") }
        }
        if case .photo(let url, _, _) = message.kind, url != nil {
            Button { viewer = .image(url) } label: { Label("Xem ảnh", systemImage: "photo") }
        }
    }

    /// The link a long-press acts on: the card's URL, the media's, or the first link in the text.
    private var primaryURL: URL? {
        switch message.kind {
        case .link(_, let url, _, _, _): return url
        case .file(_, _, let url): return WebLink.sanitized(url)
        case .video(_, _, let url): return WebLink.sanitized(url)
        case .location(let info): return info.mapURL
        default: return Self.links(in: message.text).first
        }
    }

    // MARK: Actions

    private func open(_ url: URL?) {
        guard let url else { return }
        if let web = WebLink.sanitized(url) {
            openURL(web)          // Safari (or the app that owns the link)
        } else if let scheme = url.scheme?.lowercased(), ["tel", "mailto", "sms"].contains(scheme) {
            openURL(url)
        }
    }

    private func openMap(_ info: ChatMessage.LocationInfo) {
        if let c = info.coordinate {
            let name = (info.title.isEmpty ? "Vị trí" : info.title).addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            if let url = URL(string: "https://maps.apple.com/?ll=\(c.latitude),\(c.longitude)&q=\(name)") { openURL(url) }
        } else {
            open(info.mapURL)
        }
    }

    // MARK: Text

    /// Web links, phone numbers and e-mail addresses in a message become tappable.
    private func linkified(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        guard let detector = Self.detector else { return result }
        let ns = text as NSString
        for match in detector.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let range = Range(match.range, in: text),
                  let attributed = Range(range, in: result) else { continue }
            var url = match.url
            if match.resultType == .phoneNumber, let number = match.phoneNumber {
                url = URL(string: "tel:" + number.filter { $0.isNumber || $0 == "+" })
            }
            if let url, url.scheme == nil || ["http", "https", "tel", "mailto"].contains(url.scheme!.lowercased()) {
                result[attributed].link = url.scheme == nil ? URL(string: "https://" + url.absoluteString) : url
                result[attributed].underlineStyle = .single
            }
        }
        return result
    }

    @MainActor private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue
                                                       | NSTextCheckingResult.CheckingType.phoneNumber.rawValue)

    static func links(in text: String) -> [URL] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        return detector.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
            .compactMap { WebLink.sanitized($0.url) }
    }

    static func clock(_ seconds: Int) -> String { String(format: "%d:%02d", seconds / 60, seconds % 60) }

    private var summary: String {
        switch message.kind {
        case .text: ""
        case .photo: "[Hình ảnh]"
        case .sticker: "[Sticker]"
        case .gif: "[GIF]"
        case .video: "[Video]"
        case .voice(_, let duration): "[Tin nhắn thoại \(duration)s]"
        case .file(let name, _, _): "[Tệp] \(name)"
        case .link(let title, _, _, _, _): title
        case .contactCard(let card): "[Danh thiếp] \(card.name)"
        case .location: "[Vị trí]"
        case .call(let video, let missed, _, let title, _): title.isEmpty ? (missed ? "Cuộc gọi nhỡ" : (video ? "Cuộc gọi video" : "Cuộc gọi thoại")) : title
        case .ecard: "[Thiệp]"
        case .oaMessage: "[Tin nhắn]"
        case .poll: "[Bình chọn]"
        case .stickerSet(let title, _): title
        case .zinstant(let title, let text, _): title.isEmpty ? text : title
        case .notice(_, let text), .placeholder(_, let text): text
        case .system: ""
        case .recalled: "Tin nhắn đã được thu hồi"
        case .unsupported: "[Tin nhắn chưa hỗ trợ]"
        }
    }
}
