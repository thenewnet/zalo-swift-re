# Olaz cho iPhone — build trên máy Mac

Ứng dụng chạy nhiều tài khoản Zalo cùng lúc trên iPhone. Mỗi tài khoản có phiên, cookie, dữ liệu và Keychain riêng, và đều nhận tin nhắn, thông báo realtime trong lúc app còn chạy.

## Cần có

- Máy Mac có Xcode 26 trở lên (đã kiểm tra với Xcode 26.6 trên CI).
- iPhone chạy iOS 18.4 trở lên, cắm cáp hoặc ghép qua Wi‑Fi với Xcode, và bật Developer Mode (Cài đặt › Quyền riêng tư & Bảo mật › Chế độ nhà phát triển).
- Một Apple ID đăng nhập trong Xcode (Settings › Accounts). Apple ID miễn phí vẫn được, nhưng app chỉ chạy 7 ngày rồi phải build lại. Tài khoản Apple Developer trả phí thì app chạy 1 năm.
- Homebrew.

## Các bước

```bash
git clone https://github.com/thenewnet/zalo-swift-re.git
cd zalo-swift-re

brew install xcodegen

# 1. Lấy bộ chạy Zalo PC (app.asar) từ bản cài chính thức của VNG.
#    Script tải đúng phiên bản đã ghim, kiểm tra SHA-256 và chữ ký của VNG, rồi chép vào iOS/ZaloRuntime.
#    Nếu đã có file .dmg: ZALO_DMG=/đường/dẫn/ZaloSetup.dmg scripts/fetch-zalo-runtime.sh
scripts/fetch-zalo-runtime.sh

# 2. Tạo project Xcode. Team ID xem ở Xcode › Settings › Accounts (hoặc developer.apple.com › Membership).
#    Bundle ID phải là duy nhất, ví dụ thêm tên của anh vào.
OLAZ_TEAM_ID=ABCDE12345 OLAZ_BUNDLE_ID=vn.trung.olaz xcodegen generate

# 3. Mở project
open OlazMobile.xcodeproj
```

Trong Xcode, chọn scheme **OlazMobile**, chọn iPhone của anh ở thanh trên cùng, rồi bấm Run (⌘R). Lần đầu, trên iPhone vào Cài đặt › Cài đặt chung › Quản lý VPN & thiết bị và tin cậy chứng chỉ nhà phát triển.

Nếu đổi `project.yml` hoặc thêm file, chạy lại bước 2.

## Dùng app

- Thanh trên cùng có một avatar cho mỗi tài khoản, kèm số tin chưa đọc. Chạm để chuyển, nhấn giữ để tắt thông báo hoặc đăng xuất và xoá. Nút **+** để thêm tài khoản.
- Đăng nhập bằng mã QR: quét bằng app Zalo trên một máy khác, hoặc bấm "Lưu mã QR vào Ảnh" rồi trong app Zalo chọn Quét mã › biểu tượng ảnh.
- Zalo chỉ cho một phiên máy tính mỗi tài khoản: đăng nhập ở đây sẽ đăng xuất Zalo PC ở máy khác của tài khoản đó.
- Cài đặt (bánh răng): bật/tắt thông báo từng tài khoản, "Giữ kết nối khi chạy nền" (mặc định bật), giới hạn số tài khoản chạy cùng lúc.

## Giới hạn

- Realtime cho mọi tài khoản chỉ khi app còn chạy (mở hoặc chạy nền nhờ chế độ giữ kết nối). Vuốt tắt hẳn app trong trình chuyển app thì sẽ không nhận được gì nữa cho tới khi mở lại.
- Mỗi tài khoản chạy một bộ Zalo PC riêng, tốn khoảng 150–250 MB RAM. iPhone thường chạy tốt 2–3 tài khoản cùng lúc. Khi iOS báo thiếu bộ nhớ, các tài khoản không hiển thị sẽ tạm ngủ rồi tự thức lại.
- Chưa hỗ trợ gọi thoại/video và chụp màn hình.
- Tài khoản nhiều dữ liệu: danh sách hội thoại được gửi theo từng đợt và chỉ gửi phần thay đổi, tin nhắn chỉ giữ cho vài hội thoại mở gần nhất, các tài khoản đang ẩn được cập nhật thưa hơn, nên giao diện không bị treo.

## Pháp lý

Olaz là phần mềm GPL‑3.0 (xem LICENSE), bản iOS này cũng theo GPL‑3.0. Mã Zalo PC (app.asar) là của VNG, không nằm trong repo, và chỉ được tải về máy của anh bằng script ở bước 1. Đây không phải sản phẩm chính thức của VNG.
