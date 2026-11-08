import SwiftUI
import UIKit

/// One account: setup / QR login / conversations, depending on its engine's phase.
struct AccountScreen: View {
    let engine: ZaloEngine

    var body: some View {
        switch engine.phase {
        case .starting, .signingIn:
            VStack(spacing: 12) {
                ProgressView()
                Text(engine.phase == .signingIn ? "Đang đồng bộ…" : "Đang khởi động Zalo…")
                    .foregroundStyle(.secondary)
            }
        case .preparing(let setup):
            VStack(spacing: 12) {
                if let failure = setup.failure {
                    Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.orange)
                    Text(failure).multilineTextAlignment(.center).padding(.horizontal)
                    Button("Thử lại") { engine.retryRuntimeSetup() }.buttonStyle(.borderedProminent)
                } else {
                    ProgressView()
                    Text("Đang chuẩn bị bộ chạy Zalo…").foregroundStyle(.secondary)
                }
            }
        case .login(let login):
            LoginScreen(engine: engine, login: login)
        case .ready:
            ConversationsScreen(engine: engine)
        }
    }
}

// MARK: - Login

struct LoginScreen: View {
    let engine: ZaloEngine
    let login: ZaloEngine.LoginState
    @State private var saved = false

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Text("Đăng nhập Zalo").font(.title2.bold()).padding(.top, 24)
                if let notice = engine.signOutNotice {
                    Text(notice).font(.footnote).foregroundStyle(.orange).multilineTextAlignment(.center).padding(.horizontal)
                }
                qr
                status
                VStack(alignment: .leading, spacing: 8) {
                    Text("Cách quét mã:").font(.subheadline.bold())
                    Text("• Mở app Zalo của tài khoản này trên một điện thoại hoặc máy tính bảng khác, chọn biểu tượng quét mã QR và quét mã trên màn hình.")
                    Text("• Hoặc bấm \"Lưu mã QR vào Ảnh\", rồi trong app Zalo chọn Quét mã QR → biểu tượng ảnh và chọn ảnh vừa lưu.")
                    Text("Zalo chỉ cho phép một phiên máy tính cho mỗi tài khoản: nếu tài khoản đang đăng nhập Zalo PC ở máy khác, phiên đó sẽ bị đăng xuất.")
                        .foregroundStyle(.secondary)
                }
                .font(.footnote)
                .padding(.horizontal, 24)
            }
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var qr: some View {
        if let png = login.qrPNG, let image = UIImage(data: png) {
            VStack(spacing: 12) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 240, height: 240)
                    .padding(12)
                    .background(.white, in: RoundedRectangle(cornerRadius: 16))
                    .opacity(login.step == .expired ? 0.3 : 1)
                HStack {
                    Button {
                        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
                        saved = true
                    } label: {
                        Label(saved ? "Đã lưu vào Ảnh" : "Lưu mã QR vào Ảnh", systemImage: saved ? "checkmark" : "square.and.arrow.down")
                    }
                    .buttonStyle(.bordered)
                    Button { saved = false; engine.refreshQR() } label: { Label("Mã mới", systemImage: "arrow.clockwise") }
                        .buttonStyle(.bordered)
                }
            }
        } else {
            ProgressView().frame(width: 240, height: 240)
        }
    }

    @ViewBuilder
    private var status: some View {
        switch login.step {
        case .generating: Text("Đang tạo mã QR…").foregroundStyle(.secondary)
        case .waitingScan:
            Text(login.isSecondQR ? "Quét mã thứ hai để xác nhận thiết bị" : "Quét mã bằng app Zalo").foregroundStyle(.secondary)
        case .waitingConfirm(let name, _):
            Text("\(name): bấm \"Đăng nhập\" trên điện thoại để xác nhận").multilineTextAlignment(.center)
        case .expired:
            Button("Mã đã hết hạn. Tạo mã mới") { engine.refreshQR() }.buttonStyle(.borderedProminent)
        case .failed(let message):
            Text(message).foregroundStyle(.red).multilineTextAlignment(.center)
        }
    }
}

// MARK: - Conversations

struct ConversationsScreen: View {
    let engine: ZaloEngine
    @State private var path: [String] = []
    @State private var query = ""

    /// Filtering a large list on every keystroke is cheap enough; the list itself is lazy (`List`).
    private var rows: [ZaloEngine.ConversationSummary] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return engine.conversations }
        return engine.conversations.filter { $0.displayName.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        NavigationStack(path: $path) {
            List(rows) { conversation in
                NavigationLink(value: conversation.id) {
                    ConversationRow(conversation: conversation)
                }
            }
            .listStyle(.plain)
            .searchable(text: $query, prompt: "Tìm kiếm")
            .navigationTitle(engine.profile?.displayName ?? "Tin nhắn")
            .navigationBarTitleDisplayMode(.inline)
            .overlay {
                if engine.conversations.isEmpty {
                    ContentUnavailableView("Chưa có hội thoại", systemImage: "bubble.left.and.bubble.right",
                                           description: Text("Tin nhắn cũ nằm trên điện thoại. Hội thoại mới sẽ hiện ở đây."))
                }
            }
            .navigationDestination(for: String.self) { id in
                ChatScreen(engine: engine, conversationId: id)
            }
        }
        .onChange(of: engine.navigationRequest) { _, request in
            guard let request else { return }
            engine.navigationRequest = nil
            path = [request]
        }
        .onAppear {
            if let request = engine.navigationRequest {
                engine.navigationRequest = nil
                path = [request]
            }
        }
    }
}

struct ConversationRow: View {
    let conversation: ZaloEngine.ConversationSummary

    var body: some View {
        HStack(spacing: 12) {
            AccountAvatar(name: conversation.displayName, url: conversation.avatar, size: 48)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    if conversation.pinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary) }
                    Text(conversation.displayName).font(.body.weight(conversation.unread > 0 ? .semibold : .regular)).lineLimit(1)
                    Spacer()
                    if let date = conversation.preview?.date {
                        Text(date, format: Self.dateStyle(date)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Text(previewText).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    if conversation.unread > 0 {
                        Text(conversation.unread > 99 ? "99+" : "\(conversation.unread)")
                            .font(.caption2.bold()).foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(.red))
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var previewText: String {
        guard let preview = conversation.preview else { return "" }
        return (preview.fromMe ? "Bạn: " : "") + preview.text
    }

    private static func dateStyle(_ date: Date) -> Date.FormatStyle {
        Calendar.current.isDateInToday(date) ? .dateTime.hour().minute() : .dateTime.day().month()
    }
}
