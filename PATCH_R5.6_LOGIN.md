# Sửa lỗi đăng nhập trong MỘT lần cài (R5.6)

## Chuyện gì đang xảy ra

`Đã xảy ra lỗi tạm thời khi đăng nhập` là câu game in ra **sau khi máy chủ VNG trả
lời** bước “Đang kiểm tra danh tính”. Không phải crash, không phải menu làm hỏng
UI — menu vẽ đủ, guard đọc được `ptg.vng` + `2.32.0 (227628)`.

Nhưng có một khác biệt thật, và chỉ một: cách bản R5.3–R5.5 tiêm dylib **sửa
header của executable chính**. Mọi lớp kiểm tra toàn vẹn đọc hash/header của
binary chính — kiểu VNG hay dùng ở bước kiểm tra danh tính — đều thấy file khác
bản gốc. Đó là lý do menu vẫn chạy mà đăng nhập bị chặn.

R5.6 sửa đúng chỗ đó và in luôn lý do từ server nếu vẫn còn lỗi.

## Cách sửa — lần cài duy nhất

Build `VTMenu.dylib` như thường (GitHub Actions hoặc Mac), rồi đóng gói bằng
đường **không sửa launcher**:

```powershell
py -3 tao_ipa_menu.py `
    --ipa PLAYTOGETHER-2.32.0.ipa `
    --dylib VTMenu.dylib `
    --manifest menu-build.json `
    --inject unityframework `
    --output PLAYTOGETHER-VTMenu-UNSIGNED.ipa
```

Kết quả:

| | `--inject executable` (cũ) | `--inject unityframework` (mới) |
|---|---|---|
| Executable chính | bị thêm `LC_LOAD_DYLIB` | **nguyên từng byte** |
| Lệnh nạp dylib | trong launcher | trong `UnityFramework` |
| Vị trí dylib | `Frameworks/VTMenu.dylib` | `Frameworks/UnityFramework.framework/VTMenu.dylib` |
| Đường dẫn nạp | `@executable_path/...` | `@loader_path/VTMenu.dylib` |
| Guard trong game | không đổi | không đổi |

Guard vẫn kiểm tra đúng 7 chữ ký hàm, UUID `1c1d8aea…`, metadata
`ddefd97a…`, hai bundle id — nên bản tiêm kiểu mới vẫn qua cửa như cũ.

Sau đó **ký lại toàn bộ app** bằng ESign như bình thường: cả `UnityFramework` và
`VTMenu.dylib` đều nằm trong bundle nên được ký cùng.

## Nếu vẫn lỗi — log trả lời ngay trong lần cài đó

R5.6 cài một `NSURLProtocol` ghi mọi request/response HTTP(S) vào
`Library/Application Support/VTMenu/login.log`:

```
12.480 probe installed
31.902 -> POST https://id.vng.vn/api/login
32.140 <- 403 /api/login {"errorCode":"SIGNATURE_INVALID","message":"..."}
```

- Method + URL đầy đủ
- HTTP status + 320 byte đầu của body
- Request/response **không bị sửa** — chỉ copy ra log rồi chuyển tiếp nguyên bản

Tắt probe mà không cần cài lại: tạo file `VTMenu/noprobe`.
Tắt cả menu: tạo file `VTMenu/safe`.

## Đọc log ngay trên máy — không cần PC

Trong menu có nút **`Log`** ở hàng dưới:

1. Mở menu → bấm **`Log`**.
2. Chọn tab **`login.log`** (hoặc `menu.log`).
3. Bấm **`Tải lại`** sau khi bấm đăng nhập.
4. Bấm **`Sao chép log`** → dán thẳng vào chat.

Menu hiện 16 KB cuối của file — đủ cho toàn bộ request đăng nhập. Nút `Sao chép
log` copy đúng phần đang hiện, nên chỉ cần dán là xong.

Nếu máy có Filza (jailbreak), đường dẫn đầy đủ:

```
/var/mobile/Containers/Data/Application/<UUID>/Library/Application Support/VTMenu/
    login.log
    menu.log
    config.json
```

Có PC thì lấy bằng `pymobiledevice3`:

```powershell
py -3 -m pymobiledevice3 apps afc ptg.vng pull "Library/Application Support/VTMenu/login.log" .\login.log
py -3 -m pymobiledevice3 apps afc ptg.vng pull "Library/Application Support/VTMenu/menu.log" .\menu.log
```

### Log nằm ở đâu trong máy

`Library/Application Support/VTMenu/` — thư mục dữ liệu của app, không phải
Documents. Vì vậy nó **không hiện trong app Tệp**. Ba đường đọc: nút `Log` trong
menu, Filza, hoặc `pymobiledevice3` ở trên.

## Bảng đọc kết quả

| Log thấy gì | Nghĩa | Sửa |
|---|---|---|
| `403` + `sign`/`signature`/`integrity`/`hash` | server kiểm tra toàn vẹn binary | đang ở `--inject unityframework` → thử IPA App Store `com.vng.playtogether` cùng build; nếu vẫn vậy thì server so cả cây bundle, chỉ còn đường dùng bản không tiêm để đăng nhập |
| `401` + `token`/`session`/`expired` | token cũ trong keychain | xoá app, cài lại, đăng nhập bằng acc khác hoặc Facebook/Apple |
| `4xx` + `account`/`banned`/`region`/`country` | tài khoản hoặc vùng | acc khác, mạng khác |
| `5xx` hoặc `ERR ... timeout` | server/mạng | thử lại sau, không phải menu |
| `200` + `errorCode` | VNG trả mã lỗi nghiệp vụ | gửi nguyên dòng `<- 200` |
| không có dòng `->` nào | app không đi qua `NSURLSession` (WKWebView) | xem syslog bên dưới |

Nếu login đi bằng web view (Facebook/Google), `NSURLProtocol` không thấy; lấy
log hệ thống:

```powershell
py -3 -m pymobiledevice3 syslog live --process PLAYTOGETHERVNG |
  Select-String -Pattern "login|auth|token|http|error|VNG"
```

## Cấu hình

`Library/Application Support/VTMenu/config.json`:

```json
{
  "schema": 3,
  "scale": 1.0,
  "opacity": 0.96,
  "jump_interval_ms": 20,
  "attach_delay_s": 8,
  "attach_mode": "subview"
}
```

| Khoá | Giá trị | Ý nghĩa |
|---|---|---|
| `attach_delay_s` | 0–120 | giây chờ trước khi gắn menu; `0` = gắn ngay |
| `attach_mode` | `subview` (mặc định) / `window` | menu trong window game, hay window riêng ở `UIWindowLevelAlert+100` |

## Chưa xác nhận

`apple_sdk_build`, `github_actions_build`, `ios_runtime_gameplay` vẫn `not_run`.
Phần sửa đăng nhập dựa trên cơ chế đã đọc được trong code và trên phản hồi thật
mà probe sẽ ghi; không có thiết bị thật trong phiên này.
