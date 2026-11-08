import SwiftUI

/// iOS counterpart of the macOS `CardActionCenter` (Views/CardActions.swift): the engine reports short notices
/// ("Đã sao chép", failures) here; the chat screen shows them as a toast.
@MainActor @Observable
final class CardActionCenter {
    static let shared = CardActionCenter()

    struct Notice: Identifiable, Equatable {
        let id = UUID()
        let text: String
        /// Shown only while this conversation is open (nil = anywhere).
        var conversation: String?
    }

    private(set) var notice: Notice?

    func reset() { notice = nil }

    func show(_ text: String, in conversation: String? = nil) {
        let next = Notice(text: text, conversation: conversation)
        notice = next
        Task {
            try? await Task.sleep(for: .seconds(4))
            if notice == next { notice = nil }
        }
    }
}

/// Shows the current notice of `CardActionCenter` at the bottom of a conversation.
struct CardNoticeToast: ViewModifier {
    let conversationId: String
    @State private var center = CardActionCenter.shared

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let notice = center.notice, notice.conversation == nil || notice.conversation == conversationId {
                Text(notice.text)
                    .font(.footnote)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 70)
                    .transition(.opacity)
                    .id(notice.id)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: center.notice)
    }
}
