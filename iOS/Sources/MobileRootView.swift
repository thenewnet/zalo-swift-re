import SwiftUI
import UIKit
import WebKit

/// Account bar on top, the active account below. Every account's renderer stays in the window (invisible) so all of
/// them keep running.
struct MobileRootView: View {
    @Environment(AccountsManager.self) private var accounts
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            AccountBar(showSettings: $showSettings)
            ZStack {
                if let id = accounts.activeID, let engine = accounts.engine(for: id) {
                    AccountScreen(engine: engine)
                        .id(id)
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(alignment: .topLeading) {
            RendererKeeper(views: accounts.accounts.flatMap { accounts.engine(for: $0.id)?.rendererViews ?? [] })
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .sheet(isPresented: $showSettings) { MobileSettingsView() }
        .onAppear {
            PlatformServices.revealHandler = { url in FilePresenter.present(url) }
            NativeNotifier.shared.noteUserActivity()
        }
    }
}

/// Holds the renderers' web views in the window hierarchy, fully transparent and behind everything.
struct RendererKeeper: UIViewRepresentable {
    let views: [WKWebView]

    func makeUIView(context: Context) -> UIView {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        container.clipsToBounds = true
        container.isUserInteractionEnabled = false
        container.alpha = 0.01
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        for sub in container.subviews where !views.contains(where: { $0 === sub }) { sub.removeFromSuperview() }
        for view in views where view.superview !== container {
            view.frame = CGRect(x: 0, y: 0, width: 1100, height: 720)
            view.isUserInteractionEnabled = false
            container.addSubview(view)
        }
    }
}

/// Top strip: one avatar per account with its unread count; tap to switch, long-press for actions.
struct AccountBar: View {
    @Environment(AccountsManager.self) private var accounts
    @Binding var showSettings: Bool
    @State private var removing: AccountsManager.Account?

    var body: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(accounts.accounts) { account in
                        chip(account)
                    }
                    Button {
                        accounts.addAccount()
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 36, height: 36)
                            .background(Circle().strokeBorder(.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [3])))
                    }
                    .accessibilityLabel("Thêm tài khoản")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            Button { showSettings = true } label: {
                Image(systemName: "gearshape").font(.system(size: 18)).frame(width: 40, height: 40)
            }
            .padding(.trailing, 6)
        }
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .confirmationDialog("Đăng xuất và xoá dữ liệu?",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible, presenting: removing) { account in
            Button("Xoá \(account.label)", role: .destructive) {
                Task { await accounts.remove(account.id) }
            }
        } message: { _ in
            Text("Phiên Zalo của tài khoản này trên iPhone sẽ bị xoá (cookie, dữ liệu, tệp). Tin nhắn trên tài khoản không bị ảnh hưởng.")
        }
    }

    private func chip(_ account: AccountsManager.Account) -> some View {
        let active = account.id == accounts.activeID
        let unread = accounts.unread(for: account.id)
        let engine = accounts.engine(for: account.id)
        return Button {
            accounts.activate(account.id)
        } label: {
            AccountAvatar(name: account.label, url: engine?.profile?.avatar ?? account.avatar, size: 36)
                .overlay(Circle().strokeBorder(active ? Color.accentColor : .clear, lineWidth: 2.5).padding(-4))
                .overlay(alignment: .topTrailing) {
                    if unread > 0 {
                        Text(unread > 99 ? "99+" : "\(unread)")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .frame(minWidth: 17, minHeight: 17)
                            .background(Capsule().fill(.red))
                            .offset(x: 7, y: -6)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if let engine, case .login = engine.phase {
                        Circle().fill(.orange).frame(width: 10, height: 10)
                            .overlay(Circle().stroke(.background, lineWidth: 2)).offset(x: 3, y: 3)
                    } else if !accounts.isLive(account.id) {
                        Circle().fill(.gray).frame(width: 10, height: 10)
                            .overlay(Circle().stroke(.background, lineWidth: 2)).offset(x: 3, y: 3)
                    }
                }
                .opacity(active ? 1 : 0.8)
                .padding(4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(account.label)
        .contextMenu {
            Text(account.label)
            Button {
                accounts.setNotifications(account.id, enabled: !account.notificationsEnabled)
            } label: {
                Label(account.notificationsEnabled ? "Tắt thông báo" : "Bật thông báo",
                      systemImage: account.notificationsEnabled ? "bell.slash" : "bell")
            }
            Divider()
            Button(role: .destructive) { removing = account } label: {
                Label("Đăng xuất và xoá", systemImage: "trash")
            }
        }
    }
}

extension AccountsManager.Account {
    var label: String { displayName.isEmpty ? "Tài khoản mới" : displayName }
}

struct AccountAvatar: View {
    let name: String
    let url: URL?
    var size: CGFloat = 36

    private var initials: String {
        let letters = name.split(separator: " ").suffix(2).compactMap(\.first)
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }

    var body: some View {
        ZStack {
            Circle().fill(Color.accentColor.gradient)
            Text(initials)
                .font(.system(size: size * 0.38, weight: .semibold))
                .foregroundStyle(.white)
            if let url {
                AsyncImage(url: url) { phase in
                    if let image = phase.image { image.resizable().scaledToFill() }
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

/// Presents a local file (downloads, "open file") with the share sheet.
@MainActor
enum FilePresenter {
    static func present(_ url: URL) {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var top = scene?.windows.first { $0.isKeyWindow }?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        guard let top else { return }
        let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = top.view
        top.present(sheet, animated: true)
    }
}
