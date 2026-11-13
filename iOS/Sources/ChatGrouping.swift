import SwiftUI

/// A row of the chat list: one message, or consecutive photos from one sender shown as a grid (like the Zalo app).
enum ChatItem: Identifiable {
    case single(ChatMessage)
    case album([ChatMessage])

    var id: String {
        switch self {
        case .single(let message): message.id
        case .album(let photos): "album|" + (photos.first?.id ?? "")
        }
    }

    /// Photos without a caption or quote, from the same sender, each within two minutes of the previous one.
    static func group(_ messages: [ChatMessage]) -> [ChatItem] {
        var items: [ChatItem] = []
        var run: [ChatMessage] = []
        func flush() {
            if run.count >= 2 { items.append(.album(run)) } else { items.append(contentsOf: run.map(ChatItem.single)) }
            run = []
        }
        for message in messages {
            guard message.isAlbumPhoto else { flush(); items.append(.single(message)); continue }
            if let last = run.last, last.senderId != message.senderId || last.isMine != message.isMine
                || message.date.timeIntervalSince(last.date) > 120 {
                flush()
            }
            run.append(message)
        }
        flush()
        return items
    }
}

extension ChatMessage {
    var isAlbumPhoto: Bool {
        guard case .photo = kind, quote == nil else { return false }
        return text.isEmpty || text == "[Hình ảnh]"
    }

    var photoURL: URL? {
        if case .photo(let url, _, _) = kind { return url }
        return nil
    }
}

/// Consecutive photos as a compact grid: 2 per row for 2 or 4 photos, 3 per row otherwise.
struct AlbumRow: View {
    let photos: [ChatMessage]
    let engine: ZaloEngine
    let onOpen: (Int) -> Void
    let onReply: (ChatMessage) -> Void
    let onReact: (String, ChatMessage) -> Void

    private var first: ChatMessage { photos[0] }
    private var columns: Int { photos.count == 2 || photos.count == 4 ? 2 : 3 }
    private let width: CGFloat = 240
    private let spacing: CGFloat = 3

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            if first.isMine { Spacer(minLength: 48) }
            if !first.isMine {
                AccountAvatar(name: first.senderName, url: first.senderAvatar, size: 28)
            }
            VStack(alignment: first.isMine ? .trailing : .leading, spacing: 2) {
                if !first.isMine, !first.senderName.isEmpty {
                    Text(first.senderName).font(.caption2).foregroundStyle(.secondary)
                }
                grid
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                let reactions = photos.flatMap(\.reactions)
                if !reactions.isEmpty {
                    Text(Array(Set(reactions.map(\.emoji))).sorted().joined()).font(.caption)
                }
            }
            if !first.isMine { Spacer(minLength: 48) }
        }
        .padding(.horizontal, 10)
    }

    private var grid: some View {
        let side = (width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        let rows = stride(from: 0, to: photos.count, by: columns).map { Array(photos.indices[$0..<min($0 + columns, photos.count)]) }
        return VStack(spacing: spacing) {
            ForEach(rows, id: \.first) { row in
                HStack(spacing: spacing) {
                    ForEach(row, id: \.self) { index in
                        // The last row stretches its photos so the grid stays a rectangle.
                        let cell = row.count < columns ? (width - spacing * CGFloat(row.count - 1)) / CGFloat(row.count) : side
                        thumbnail(index, width: cell, height: side)
                    }
                }
            }
        }
        .frame(width: width)
    }

    private func thumbnail(_ index: Int, width: CGFloat, height: CGFloat) -> some View {
        let message = photos[index]
        return Button { onOpen(index) } label: {
            AsyncImage(url: message.photoURL) { $0.resizable().scaledToFill() } placeholder: {
                Rectangle().fill(Color(.tertiarySystemFill))
            }
            .frame(width: width, height: height)
            .clipped()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            ControlGroup {
                ForEach(MobileMessageRow.reactionEmojis, id: \.self) { emoji in
                    Button { onReact(emoji, message) } label: { Text(emoji) }
                }
            }
            .controlGroupStyle(.compactMenu)
            Button { onReply(message) } label: { Label("Trả lời", systemImage: "arrowshape.turn.up.left") }
            Button { onOpen(index) } label: { Label("Xem ảnh", systemImage: "photo") }
            if let list = engine.pins[message.conversationId], list.canPin {
                if list.items.contains(where: { $0.message(in: [message]) != nil }) {
                    Button { engine.requestUnpin(message) } label: { Label("Bỏ ghim tin nhắn", systemImage: "pin.slash") }
                } else {
                    Button { engine.pin(message) } label: { Label("Ghim tin nhắn", systemImage: "pin") }
                }
            }
        }
    }
}

/// Every pin of the conversation, with "Bỏ ghim".
struct PinnedListSheet: View {
    let engine: ZaloEngine
    let conversationId: String
    @Environment(\.dismiss) private var dismiss

    private var list: PinnedList? { engine.pins[conversationId] }

    var body: some View {
        NavigationStack {
            List {
                ForEach(list?.items ?? []) { item in
                    HStack(spacing: 12) {
                        if let thumbnail = item.thumbnail {
                            AsyncImage(url: thumbnail) { $0.resizable().scaledToFill() } placeholder: { Color(.tertiarySystemFill) }
                                .frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 8))
                        } else {
                            Image(systemName: "pin.fill").foregroundStyle(Color.accentColor).frame(width: 44, height: 44)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title.isEmpty ? item.label : item.title).lineLimit(2)
                            Text(item.sender.isEmpty ? item.label : "\(item.label) · \(item.sender)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions {
                        if list?.canPin == true {
                            Button("Bỏ ghim", role: .destructive) {
                                dismiss()
                                // The confirm is shown by the chat screen once this sheet is gone.
                                Task {
                                    try? await Task.sleep(for: .milliseconds(450))
                                    engine.requestUnpin(item, in: conversationId)
                                }
                            }
                        }
                    }
                }
            }
            .overlay {
                if list?.items.isEmpty ?? true {
                    ContentUnavailableView("Chưa có tin ghim", systemImage: "pin")
                }
            }
            .navigationTitle("Tin đã ghim")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Xong") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}
