import SwiftUI
import UIKit

struct MobileSettingsView: View {
    @Environment(AccountsManager.self) private var accounts
    @Environment(MobileSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var pendingRemoval: AccountsManager.Account?

    var body: some View {
        @Bindable var settings = settings
        @Bindable var accounts = accounts
        NavigationStack {
            Form {
                Section("Tài khoản") {
                    ForEach(accounts.accounts) { account in
                        HStack(spacing: 12) {
                            AccountAvatar(name: account.label, url: account.avatar, size: 32)
                            VStack(alignment: .leading) {
                                Text(account.label)
                                Text(accounts.isLive(account.id) ? "Đang kết nối" : "Đang ngủ")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("Thông báo", isOn: Binding(get: { account.notificationsEnabled },
                                                               set: { accounts.setNotifications(account.id, enabled: $0) }))
                                .labelsHidden()
                        }
                        .swipeActions {
                            Button("Xoá", role: .destructive) { pendingRemoval = account }
                        }
                    }
                    .onMove { accounts.move(from: $0, to: $1) }
                    Button {
                        accounts.addAccount()
                        dismiss()
                    } label: { Label("Thêm tài khoản", systemImage: "plus") }
                }

                Section {
                    Toggle("Giữ kết nối khi chạy nền", isOn: $settings.keepAliveInBackground)
                    Picker("Số tài khoản chạy cùng lúc", selection: $accounts.maxLiveAccounts) {
                        Text("Tất cả").tag(0)
                        ForEach(1..<6) { Text("\($0)").tag($0) }
                    }
                    Button("Mở cài đặt thông báo của iOS") {
                        if let url = URL(string: UIApplication.openNotificationSettingsURLString) { UIApplication.shared.open(url) }
                    }
                } header: {
                    Text("Realtime & thông báo")
                } footer: {
                    Text("Mọi tài khoản luôn kết nối và nhận tin ngay. iOS tạm dừng ứng dụng khi bạn rời đi, nên \"Giữ kết nối khi chạy nền\" giữ ứng dụng chạy để tiếp tục nhận thông báo (tốn pin hơn). Nếu bạn vuốt tắt ứng dụng, thông báo sẽ dừng. Khi iPhone thiếu bộ nhớ, các tài khoản không hiển thị tạm ngủ rồi tự kết nối lại.")
                }

                Section("Giới thiệu") {
                    Text("Olaz cho iPhone, dựa trên Olaz của Quan Nguyen (github.com/qnguyen3/zalo-swift-re), phần mềm tự do theo giấy phép GPL-3.0.")
                        .font(.footnote)
                    Text("Ứng dụng không chính thức, không liên kết hay được VNG chứng nhận. \"Zalo\" là nhãn hiệu của VNG. Dùng ứng dụng không chính thức có thể trái điều khoản của Zalo; tự chịu rủi ro.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Cài đặt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { EditButton() }
                ToolbarItem(placement: .confirmationAction) { Button("Xong") { dismiss() } }
            }
            .confirmationDialog("Đăng xuất và xoá dữ liệu?",
                                isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
                                titleVisibility: .visible, presenting: pendingRemoval) { account in
                Button("Xoá \(account.label)", role: .destructive) {
                    Task { await accounts.remove(account.id) }
                }
            }
        }
    }
}
