import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// One conversation: messages from the official client (newest at the bottom), older pages on scroll, a composer.
struct ChatScreen: View {
    let engine: ZaloEngine
    let conversationId: String
    @State private var draft = ""
    @State private var sending = false
    @State private var requestedOlderAt: String?
    @State private var replyTo: ChatMessage?
    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var uploading = false
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
        .photosPicker(isPresented: $showPhotos, selection: $photoItems, maxSelectionCount: 20, matching: .any(of: [.images, .videos]))
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            photoItems = []
            Task { await sendPhotos(items) }
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { Task { await sendFiles(urls) } }
        }
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
                        MobileMessageRow(message: message, engine: engine,
                                         onReply: { replyTo = $0; composerFocused = true },
                                         onReact: { emoji, msg in engine.react(emoji, to: msg.id, in: conversationId) })
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
        VStack(spacing: 0) {
            if let replyTo {
                HStack(spacing: 8) {
                    Rectangle().fill(Color.accentColor).frame(width: 3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Trả lời \(replyTo.isMine ? "chính mình" : replyTo.senderName)")
                            .font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor)
                        Text(MobileMessageRow.preview(of: replyTo)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button { self.replyTo = nil } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .accessibilityLabel("Huỷ trả lời")
                }
                .frame(height: 36)
                .padding(.horizontal, 12)
                .padding(.top, 6)
            }
            if uploading {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Đang gửi tệp…").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.top, 6)
            }
            inputRow
        }
        .background(.bar)
    }

    private var inputRow: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Menu {
                Button { showPhotos = true } label: { Label("Ảnh hoặc video", systemImage: "photo.on.rectangle") }
                Button { showFiles = true } label: { Label("Tệp", systemImage: "doc") }
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 26))
                    .frame(width: 36, height: 36)
            }
            .disabled(uploading)
            .accessibilityLabel("Đính kèm")
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
        let quoted = replyTo
        replyTo = nil
        Task {
            let ok = await engine.sendText(text, to: conversationId, quoting: quoted?.id)
            if !ok { draft = text; replyTo = quoted }
            sending = false
        }
    }

    // MARK: Attachments

    /// Copies the picked photos / videos into a temporary folder (the page reads them from there) and sends them
    /// through the official photo path.
    private func sendPhotos(_ items: [PhotosPickerItem]) async {
        uploading = true
        defer { uploading = false }
        var urls: [URL] = []
        for item in items {
            if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }),
               let movie = try? await item.loadTransferable(type: PickedMovie.self) {
                urls.append(movie.url)
            } else if let data = try? await item.loadTransferable(type: Data.self) {
                let type = item.supportedContentTypes.first
                // HEIC and other camera formats go out as JPEG, which every Zalo client can show; GIF stays animated.
                if type?.conforms(to: .gif) != true, let image = UIImage(data: data), let jpeg = image.jpegData(compressionQuality: 0.9) {
                    if let url = Outbox.write(jpeg, name: "IMG_\(urls.count + 1).jpg") { urls.append(url) }
                } else if let url = Outbox.write(data, name: "IMG_\(urls.count + 1).\(type?.preferredFilenameExtension ?? "jpg")") {
                    urls.append(url)
                }
            }
        }
        guard !urls.isEmpty else {
            CardActionCenter.shared.show("Không đọc được ảnh đã chọn.", in: conversationId)
            return
        }
        report(await engine.sendMedia(urls, to: conversationId))
    }

    private func sendFiles(_ picked: [URL]) async {
        uploading = true
        defer { uploading = false }
        let urls = picked.compactMap { Outbox.copy($0) }
        guard !urls.isEmpty else {
            CardActionCenter.shared.show("Không đọc được tệp đã chọn.", in: conversationId)
            return
        }
        report(await engine.sendFiles(urls, to: conversationId))
    }

    private func report(_ outcome: ComposerOutcome) {
        switch outcome {
        case .failed(let text), .pending(let text): CardActionCenter.shared.show(text, in: conversationId)
        case .done, .cancelled: break
        }
    }
}

/// A compact iOS bubble for every message kind the engine knows. Photos open full screen, links open in Safari,
/// videos and voice messages play, files and locations open in the system apps; long-press offers copy.
struct MobileMessageRow: View {
    let message: ChatMessage
    let engine: ZaloEngine
    var onReply: (ChatMessage) -> Void = { _ in }
    var onReact: (String, ChatMessage) -> Void = { _, _ in }
    @Environment(\.openURL) private var openURL
    @State private var viewer: MediaViewerItem?
    @State private var contact: ChatMessage.ContactCard?

    static let reactionEmojis = ["❤️", "👍", "😆", "😮", "😢", "😡"]

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
                    if let quote = message.quote {
                        quoteView(quote)
                    }
                    bubble
                        .contextMenu { menu }
                    if !message.reactions.isEmpty {
                        reactionChips
                    }
                }
                if !message.isMine { Spacer(minLength: 48) }
            }
            .padding(.horizontal, 10)
            .fullScreenCover(item: $viewer) { item in MediaViewer(item: item) }
            .sheet(item: $contact) { card in ContactCardSheet(card: card, engine: engine) }

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
        case .contactCard(let card):
            Button { contact = card } label: {
                HStack(spacing: 10) {
                    AccountAvatar(name: card.name, url: card.avatar, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(card.name.isEmpty ? "Danh thiếp" : card.name).foregroundStyle(.primary).lineLimit(1)
                        Text(card.isOfficialAccount ? "Tài khoản OA" : (card.phone.isEmpty ? "Danh thiếp Zalo" : card.phone))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
                .padding(10)
                .frame(width: 240, alignment: .leading)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
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
        if canInteract {
            ControlGroup {
                ForEach(Self.reactionEmojis, id: \.self) { emoji in
                    Button { onReact(emoji, message) } label: {
                        Text(myReactions.contains(emoji) ? "\(emoji)✓" : emoji)
                    }
                }
            }
            .controlGroupStyle(.compactMenu)
            Button { onReply(message) } label: { Label("Trả lời", systemImage: "arrowshape.turn.up.left") }
        }
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

    private var canInteract: Bool {
        switch message.kind {
        case .recalled, .system, .notice, .placeholder: false
        default: !message.id.isEmpty
        }
    }

    private var myReactions: Set<String> { Set(message.reactions.filter(\.includesMe).map(\.emoji)) }

    /// Reaction chips under the bubble; tapping one adds or removes my reaction of that kind.
    private var reactionChips: some View {
        HStack(spacing: 4) {
            ForEach(message.reactions) { reaction in
                Button { onReact(reaction.emoji, message) } label: {
                    HStack(spacing: 2) {
                        Text(reaction.emoji)
                        if reaction.count > 1 { Text("\(reaction.count)").font(.caption2.monospacedDigit()) }
                    }
                    .font(.caption)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(reaction.includesMe ? Color.accentColor.opacity(0.2) : Color(.tertiarySystemFill), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(reaction.tooltip ?? reaction.emoji)
            }
        }
    }

    private func quoteView(_ quote: ChatMessage.Quote) -> some View {
        HStack(spacing: 6) {
            Rectangle().fill(Color.accentColor).frame(width: 2)
            VStack(alignment: .leading, spacing: 1) {
                Text(quote.senderName).font(.caption2.weight(.semibold))
                Text(quote.text).font(.caption2).lineLimit(2)
            }
            .foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
        .frame(maxWidth: 240, alignment: .leading)
    }

    /// One line describing a message (reply banner).
    static func preview(of message: ChatMessage) -> String {
        if !message.text.isEmpty { return message.text }
        return summary(message.kind)
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

    private var summary: String { Self.summary(message.kind) }

    static func summary(_ kind: ChatMessage.Kind) -> String {
        switch kind {
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
