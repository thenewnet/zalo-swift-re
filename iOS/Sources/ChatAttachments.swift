import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

/// Temporary copies of what the user picks to send. The official page reads them through its file input, so they
/// must be plain files the app owns; the folder is in the app's temporary directory, which iOS cleans up.
@MainActor
enum Outbox {
    static let folder: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Outbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// A fresh sub-folder per pick, so two files with the same name never collide.
    private static func batchFolder() -> URL {
        let url = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func write(_ data: Data, name: String) -> URL? {
        let url = batchFolder().appendingPathComponent(name)
        do { try data.write(to: url); return url } catch { return nil }
    }

    /// Copies a file chosen in Files (security-scoped) into the outbox.
    static func copy(_ source: URL) -> URL? {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let target = batchFolder().appendingPathComponent(source.lastPathComponent)
        do { try FileManager.default.copyItem(at: source, to: target); return target } catch { return nil }
    }
}

/// A video from the photo library, received as a file (not loaded into memory).
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("Outbox", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let target = folder.appendingPathComponent(received.file.lastPathComponent)
            try FileManager.default.copyItem(at: received.file, to: target)
            return PickedMovie(url: target)
        }
    }
}

extension ChatMessage.ContactCard: Identifiable {
    var id: String { uid.isEmpty ? name : uid }
}

/// A shared contact card: profile, message, add friend, call.
struct ContactCardSheet: View {
    let card: ChatMessage.ContactCard
    let engine: ZaloEngine
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var profile: ContactProfile?
    @State private var loading = true
    @State private var requestSent = false

    private var name: String { profile?.name.isEmpty == false ? profile!.name : card.name }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                AccountAvatar(name: name, url: profile?.avatar ?? card.avatar, size: 96)
                    .padding(.top, 24)
                Text(name.isEmpty ? "Danh thiếp" : name).font(.title2.bold())
                if let zaloName = profile?.zaloName, !zaloName.isEmpty, zaloName != name {
                    Text(zaloName).foregroundStyle(.secondary)
                }
                if let bio = profile?.bio, !bio.isEmpty {
                    Text(bio).font(.callout).multilineTextAlignment(.center).padding(.horizontal)
                }
                if loading { ProgressView() }
                VStack(spacing: 10) {
                    if !card.uid.isEmpty, profile?.isSelf != true {
                        Button {
                            engine.openContactConversation(card.uid)
                            dismiss()
                        } label: {
                            Label("Nhắn tin", systemImage: "bubble.left.fill").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        if let profile, !profile.isFriend, !profile.isOfficialAccount, !card.isOfficialAccount {
                            Button {
                                let me = engine.profile?.displayName ?? ""
                                engine.sendFriendRequest(to: card.uid, message: me.isEmpty ? "Xin chào" : "Xin chào, mình là \(me)")
                                requestSent = true
                            } label: {
                                Label(requestSent ? "Đã gửi lời mời kết bạn" : "Kết bạn",
                                      systemImage: requestSent ? "checkmark" : "person.badge.plus")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .disabled(requestSent)
                        }
                    }
                    if !card.phone.isEmpty, let tel = URL(string: "tel:" + card.phone.filter { $0.isNumber || $0 == "+" }) {
                        Button { openURL(tel) } label: {
                            Label("Gọi \(card.phone)", systemImage: "phone.fill").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        Button { PlatformServices.copy(card.phone) } label: {
                            Label("Sao chép số điện thoại", systemImage: "doc.on.doc").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .controlSize(.large)
                .padding(.horizontal, 24)
                Spacer()
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Đóng") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
        .task {
            guard !card.uid.isEmpty else { loading = false; return }
            profile = await engine.contactProfile(card.uid)
            loading = false
        }
    }
}
