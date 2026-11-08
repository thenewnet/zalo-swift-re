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

/// A compact iOS bubble for every message kind the engine knows (media shown inline, the rest summarised).
struct MobileMessageRow: View {
    let message: ChatMessage
    let engine: ZaloEngine

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
                    if !message.reactions.isEmpty {
                        Text(message.reactions.map(\.icon.emoji).joined())
                            .font(.caption)
                    }
                }
                if !message.isMine { Spacer(minLength: 48) }
            }
            .padding(.horizontal, 10)
        }
    }

    @ViewBuilder
    private var bubble: some View {
        switch message.kind {
        case .photo(let url, let width, let height):
            media(url, aspect: width > 0 && height > 0 ? CGFloat(width) / CGFloat(height) : 1)
        case .sticker(let url), .gif(let url):
            AsyncImage(url: url) { $0.resizable().scaledToFit() } placeholder: { Color.clear }
                .frame(width: 120, height: 120)
        case .recalled:
            textBubble("Tin nhắn đã được thu hồi", italic: true)
        default:
            textBubble(message.text.isEmpty ? summary : message.text, italic: message.text.isEmpty)
        }
    }

    private func media(_ url: URL?, aspect: CGFloat) -> some View {
        AsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: {
            Rectangle().fill(Color(.tertiarySystemFill))
        }
        .frame(width: 220, height: min(320, 220 / max(aspect, 0.3)))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func textBubble(_ text: String, italic: Bool = false) -> some View {
        Text(text)
            .italic(italic)
            .textSelection(.enabled)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .foregroundStyle(message.isMine ? .white : .primary)
            .background(message.isMine ? Color.accentColor : Color(.secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 18))
    }

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
