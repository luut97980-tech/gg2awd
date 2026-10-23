# VTMenu iOS — bản sửa R5.4

## Phạm vi

Không thêm chức năng. Chỉ ba sửa lỗi và một sửa CI. `menu_revision` vẫn là **5**,
framework UUID, `global-metadata.dat` hash, bảy chữ ký hàm và hai bundle id được
chấp nhận đều giữ nguyên. `tao_ipa_menu.py` không cần sửa.

## 1. Bật công tắc làm mất cổng chờ cảnh

**Triệu chứng.** Xoay máy hoặc quay lại từ nền, rồi chạm bật ESP/Spam ngay →
thỉnh thoảng văng ở màn hình đăng nhập, giống hệt lỗi R5.1.

**Nguyên nhân.** `GameBackend::suspend()` đặt `settleUntil = now + 0.75`, nhưng
`GameBackend::toggle()` gán `state->settleUntil = 0` ở cuối hàm. Cú chạm xóa luôn
cổng vừa đặt, nên khung hình kế tiếp đọc actor/camera/transform của scene đang dựng.

**Sửa.** Bỏ hẳn dòng gán đó. Cổng chờ thuộc về vòng đời scene, không thuộc về
trạng thái công tắc.

## 2. ESP mất cả khung hình khi phòng quá 128 người

**Triệu chứng.** Vào phòng đông, ESP tắt ngóm dù công tắc vẫn bật; chẩn đoán ghi
`ESP: ESP actor count exceeds 128`.

**Nguyên nhân.** Ngưỡng 128 vừa là trần vẽ vừa là điều kiện ném ngoại lệ; ném ở
`espTick` kéo theo `needsSettle`, xóa sạch khung.

**Sửa.** Tách hai ngưỡng:

| Ngưỡng | Giá trị | Ý nghĩa |
|---|---|---|
| `kEspDrawLimit` | 128 | số khung tối đa vẽ mỗi khung hình |
| `kActorArrayLimit` | 4096 | trần từ chối `Count` hỏng |

Mảng vẫn được cấp phát đúng bằng `Count` thật nên `CopyTo` không lệch kích thước;
vòng lặp chỉ chạy `min(Count, 128)`.

## 3. Tài liệu lệch code

`VALIDATION.json` và mục R5.2 của README vẫn mô tả menu là child view controller
trong root view của window. Code R5.3 đã chuyển sang `VTPassthroughWindow` riêng.
Mục R5.4 của README và `orientation_implementation` trong `VALIDATION.json` đã
được viết lại theo đúng `src/Plugin.mm`.

## 4. CI: Node 20 hết hỗ trợ

GitHub Actions cảnh báo `actions/checkout@v4` và `actions/upload-artifact@v4`
đang bị ép chạy trên Node 24. Đã đổi:

- `actions/checkout@v4` → `@v5`
- `actions/upload-artifact@v4` → `@v5`
- thêm bước **Verify artifact**: kiểm `dist/VTMenu.dylib`,
  `dist/menu-build.json`, `menu_revision==5`, `features==['esp','spam_jump']`,
  và `LC_BUILD_VERSION` của dylib.
- in `python3 --version` cùng phiên bản SDK.

Tên artifact giữ nguyên **VTMenu-iOS-ESP-Spam-R5** để không phải sửa ba tài liệu
đang tham chiếu nó.

## Build lại

1. Đẩy repo lên GitHub, gồm `.github/workflows`.
2. Actions → **Build iOS ESP Spam Menu** → Run workflow.
3. Tải artifact, giải nén, chạy `py tao_ipa_menu.py` (hoặc `python3`).
4. Ký bằng ESign/AltStore với profile hợp lệ, giữ bundle gốc.

## Kiểm tra sau khi cài

1. Mở game, chưa bật gì, đăng nhập → vào được, không văng.
2. Menu hiện `PTG | R5.4`, trạng thái “Đã kết nối”.
3. Xoay máy rồi bật ESP ngay trong 0,75 s → không văng, ESP hiện sau khi cảnh ổn định.
4. Vào phòng >128 người → ESP vẫn vẽ, không tự tắt.
5. Nếu sai metadata, gửi nguyên nội dung **Sao chép chẩn đoán**.

## Chưa xác nhận

`apple_sdk_build`, `github_actions_build`, `ios_runtime_gameplay`,
`signing_esign` đều `not_run`. 14 test Python đã chạy lại và đạt; 3 test C++
portable chưa biên dịch lại trong phiên này (máy không có compiler).
