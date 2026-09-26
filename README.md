# Waydroid Remote: Màn hình Cảm ứng Từ xa Siêu Độ Trễ Thấp cho iPhone (Arch Linux + Hyprland)

Dự án biến chiếc **iPhone / iPad** thành màn hình cảm ứng phụ và bảng điều khiển từ xa độ trễ cực thấp cho **Waydroid** (Android) đang chạy trên **Arch Linux** (tối ưu hóa cho Hyprland / Wayland).

```
+--------------------------------------------------------------------------------+
|                             ARCH LINUX SERVER DAEMON                           |
|                                                                                |
|  +--------------------+                                                        |
|  | Waydroid / Android |                                                        |
|  | (SurfaceControl)   |                                                        |
|  +---------+----------+                                                        |
|            | OMX H.264                                                         |
|            v                                                                   |
|  +---------+----------+      TCP 8001 (Video)      +------------------------+  |
|  | scrcpy-server.jar  | =========================> | VideoToolbox / Metal   |  |
|  | (InputManager IPC) |                            | (Hardware Decode 0-lag)|  |
|  +---------^----------+                            +-----------+------------+  |
|            |                                                   |               |
|            | 32-byte binary packet                             |               |
|            | (Action, PointerID, X, Y, Pressure)               |               |
|            +---------------------------------------+           |               |
|                                                    |           | Render View   |
|                                TCP 8000 (Control)  |           v               |
|                                <================== +------------------------+  |
|                                                    | iPhone Native Client   |  |
|                                                    | (Multi-touch + SwiftUI)|  |
+----------------------------------------------------+------------------------+--+
```

---

## 🌟 Điểm nổi bật & Tính năng chính

* ⚡ **Độ trễ siêu thấp (Ultra-Low Latency)**:
  - **Touch Latency < 1ms**: Gói tin nhị phân 32-byte truyền qua kết nối TCP riêng biệt với `TCP_NODELAY`, tiêm thẳng vào `InputManager` của Android (không dùng `adb shell input tap/swipe` gây trễ).
  - **Visual Latency < 30ms**: Mã hóa trực tiếp từ `SurfaceControl` của Waydroid sang H.264, giải mã phần cứng trên iOS bằng Apple **VideoToolbox** (`kVTDecompressionPropertyKey_RealTime`, `maxFrameDelay = 0`), hiển thị 0-copy qua GPU Metal (`AVSampleBufferDisplayLayer`).
  - **Zero Frame Backlog**: Hàng đợi socket video tự động drop frame cũ nếu mạng LAN nghẽn, đảm bảo màn hình luôn hiển thị frame mới nhất mà không bao giờ bị tích tụ độ trễ.
* 👆 **Cảm ứng đa điểm thật (Native Multi-Touch & Gestures)**:
  - Hỗ trợ vuốt, chạm, giữ, cuộn 2 ngón và **pinch-to-zoom** (thu phóng 2 ngón) đa điểm mượt mà như dùng tablet Android thật.
  - Hỗ trợ lực nhấn cảm ứng (Pressure sensitivity).
* 📐 **Tự động map tọa độ & Xoay màn hình (Auto Letterbox Mapping)**:
  - Tự động căn chỉnh tỷ lệ khung hình (Letterbox / Pillarbox) vừa khít với màn hình iPhone.
  - Hỗ trợ xoay ngang (Landscape) và xoay dọc (Portrait) tức thì; tọa độ chạm tự động co giãn chính xác pixel theo màn hình Android.
* 🔍 **Tự động tìm kiếm qua Bonjour / mDNS**:
  - Server tự động phát thông báo dịch vụ `_waydroid-remote._tcp` trên LAN.
  - iPhone tự động phát hiện máy Linux ngay khi mở app; 1-chạm kết nối mà không cần nhập IP thủ công (vẫn có ô nhập IP dự phòng).
* ⌨️ **Bàn phím ảo & Phím điều hướng Android**:
  - Gõ văn bản tiếng Việt Telex/VNI, Emoji từ bàn phím iPhone truyền trực tiếp vào Android qua `INJECT_TEXT`.
  - Thanh phím tắt nổi: Quay lại (Back), Về trang chính (Home), Đa nhiệm (Recent Apps), Mở thanh thông báo (Notification Panel).
* 🎛️ **Bộ Preset linh hoạt**:
  - `720p`: Siêu nhẹ, độ trễ thấp nhất cho mạng Wi-Fi yếu (60 FPS, 4 Mbps).
  - `1080p`: Chuẩn sắc nét, cân bằng hoàn hảo (60 FPS, 8 Mbps).
  - `Native / 90fps / 120fps`: Tận dụng màn hình ProMotion 120Hz của iPhone Pro.
* 🛡️ **Tự động xử lý trạng thái Waydroid**:
  - Tự động unfreeze container Waydroid khi khởi động server, ngăn chặn hiện tượng đóng băng khi cửa sổ Wayland ẩn.

---

## 🚀 Hướng dẫn cài đặt & Khởi chạy

### Bước 1: Thiết lập tự động trên Arch Linux (1 lệnh duy nhất)

Mở terminal trong thư mục project và chạy:

```bash
./scripts/setup_server.sh
```

Script sẽ tự động:
1. Cài đặt các gói phụ thuộc: `android-tools`, `scrcpy`, `protobuf`, `python-zeroconf`, `avahi`.
2. Kiểm tra và khởi động Waydroid session.
3. Tự động cấp quyền ADB key vào container Waydroid (không bị lỗi `unauthorized`).
4. Triển khai `scrcpy-server.jar` vào container.
5. Chạy tự kiểm (self-test) kiểm tra luồng video và tiêm phím.

### Bước 2: Chạy Server trên Arch Linux

Chạy trực tiếp từ terminal:

```bash
./scripts/run_server.sh
```

Hoặc tùy chỉnh preset và port:

```bash
./scripts/run_server.sh 1080p 8000 8001
# Các preset có sẵn: 720p, 1080p, native, native-90fps, native-120fps
```

#### (Tùy chọn) Chạy ngầm dạng Systemd Service:

```bash
mkdir -p ~/.config/systemd/user
cp server/waydroid-remote.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now waydroid-remote.service
```

---

## 📱 Cài đặt & Chạy ứng dụng trên iPhone

### Cách 1: Tải IPA từ GitHub Actions (Khuyến nghị, không cần Mac)

1. Repo đã tích hợp sẵn GitHub Actions workflow tại `.github/workflows/build-ipa.yml`.
2. Mỗi khi push code lên GitHub hoặc bấm **Run workflow** trong tab Actions, GitHub sẽ tự động build file `WaydroidRemote-unsigned.ipa`.
3. Tải file IPA về iPhone và cài đặt trực tiếp bằng một trong các công cụ:
   - **TrollStore** (nếu máy có TrollStore - cài vĩnh viễn, không cần sign).
   - **SideStore** / **AltStore** (cài qua máy tính hoặc trực tiếp trên Wi-Fi).
   - **Scarlet** / **Sideloadly**.

### Cách 2: Tự build bằng Xcode trên macOS

Nếu bạn có máy Mac có Xcode:

```bash
# Build unsigned IPA:
./scripts/build_ipa.sh

# Hoặc build và ký bằng Developer Certificate của bạn:
export EXPORT_OPTIONS_PLIST="$PWD/ExportOptions.plist"
./scripts/build_ipa.sh
```

---

## 🎮 Cách sử dụng trên iPhone

1. Đảm bảo iPhone và máy tính Arch Linux kết nối **cùng một mạng Wi-Fi (hoặc USB LAN)**.
2. Mở ứng dụng **Waydroid Remote** trên iPhone.
3. Ứng dụng sẽ hiển thị máy tính trong danh sách **"Tự động tìm kiếm trên LAN"**. Bấm **"Kết nối"**.
4. Màn hình Waydroid sẽ lập tức hiển thị toàn màn hình:
   - **Chạm 1 ngón**: Nhấp/chọn.
   - **Vuốt 1 ngón**: Cuộn trang/kéo thả.
   - **Nhúm 2 ngón (Pinch)**: Phóng to / thu nhỏ bản đồ, ảnh, web.
   - **Vuốt 2 ngón**: Cuộn mượt.
   - **Góc trên**: HUD hiển thị độ trễ RTT (ms), FPS, bitrate và menu đổi preset.
   - **Thanh dưới**: Các nút Back, Home, Đa nhiệm và Bàn phím ảo để gõ văn bản tiếng Việt.

---

## ⚡ Mẹo tối ưu hóa độ trễ tối đa (Hyprland + Wi-Fi)

1. **Sử dụng băng tần Wi-Fi 5GHz hoặc 6GHz**:
   - Tránh Wi-Fi 2.4GHz vì dễ bị nhiễu sóng Bluetooth, làm tăng jitter ping từ 2ms lên 20ms.
2. **Cấu hình Window Rules cho Waydroid trên Hyprland (`hyprland.conf`)**:
   Để Waydroid render mượt mà ở tần số quét cao mà không bị compositor giới hạn FPS:
   ```ini
   # Thêm vào ~/.config/hypr/hyprland.conf
   windowrulev2 = noblur, class:^(Waydroid)$
   windowrulev2 = immediate, class:^(Waydroid)$
   ```
3. **Kết nối qua cáp USB (Độ trễ thấp tuyệt đối < 5ms)**:
   Nếu dùng dây cáp Lightning / Type-C kết nối iPhone với máy tính:
   ```bash
   # Sử dụng iproxy chuyển hướng port qua cáp USB:
   iproxy 8000:8000 8001:8001 &
   ```
   Sau đó trên iPhone nhập `127.0.0.1` ở ô IP thủ công. Độ trễ lúc này tương đương cáp màn hình trực tiếp!

---

## 📂 Cấu trúc Thư mục Dự án

```
.
├── server/
│   ├── protocol.py                 # Định nghĩa các gói tin nhị phân chuẩn scrcpy (Touch 32-byte, Keycode, Video)
│   ├── scrcpy_core.py              # Bộ điều phối scrcpy-server, streaming H.264 và tiêm sự kiện trực tiếp
│   ├── discovery.py                # Bonjour/mDNS service publisher tự động broadcast trên LAN
│   ├── waydroid_touch_server.py    # Server daemon chính (TCP 8000 Control, TCP 8001 Video, REST API)
│   └── waydroid-remote.service     # Systemd service unit cho Linux
├── ios/
│   └── WaydroidRemote/
│       ├── ScrcpyProtocol.swift    # Bộ đóng gói nhị phân cho iOS (32-byte touch, keys, ping)
│       ├── CoordinateMapper.swift  # Tự động tính aspect-fit letterbox và chuyển đổi tọa độ chạm
│       ├── H264Decoder.swift       # Giải mã phần cứng H.264 siêu độ trễ thấp bằng VideoToolbox
│       ├── SampleBufferVideoView.swift # View hiển thị video 0-copy qua AVSampleBufferDisplayLayer
│       ├── TouchTrackerView.swift  # Lớp bắt chạm đa điểm multi-touch, pinch và gestures trên iOS
│       ├── NetworkClient.swift     # Quản lý kết nối kép TCP_NODELAY và tự động kết nối lại
│       ├── ServerDiscovery.swift   # Tìm kiếm Bonjour mDNS bằng NWBrowser
│       ├── HUDOverlayView.swift    # HUD hiển thị realtime latency, fps, bitrate và đổi preset nóng
│       ├── VirtualKeyboardBar.swift# Bàn phím ảo tiếng Việt & phím điều hướng Android
│       ├── RemoteTouchView.swift   # Giao diện màn hình cảm ứng toàn màn hình
│       ├── ContentView.swift       # Giao diện chính kết nối
│       ├── Info.plist              # Khai báo quyền Bonjour & Local Network
│       └── WaydroidRemote.xcodeproj# Dự án Xcode hoàn chỉnh
├── scripts/
│   ├── setup_server.sh             # Script tự động cài đặt và kiểm tra toàn bộ môi trường Arch Linux
│   ├── run_server.sh               # Script 1-click khởi chạy server daemon
│   └── build_ipa.sh                # Script build IPA tự động cho macOS
└── .github/workflows/
    └── build-ipa.yml               # GitHub Actions CI build IPA tự động
```

---

## 🛠️ Xử lý Sự cố Thường gặp (Troubleshooting)

* **Lỗi `unauthorized` khi kết nối ADB**:
  - Chạy `./scripts/setup_server.sh`. Script sẽ tự động nạp `~/.android/adbkey.pub` vào container.
* **Waydroid bị đóng băng (Container: FROZEN)**:
  - Chạy lệnh: `waydroid prop set persist.waydroid.suspend false` và `sudo waydroid container unfreeze`.
* **iPhone không tự tìm thấy server**:
  - Đảm bảo iPhone và máy tính cùng subnet Wi-Fi (ví dụ cùng dải `192.168.1.x`).
  - Bạn có thể nhập trực tiếp IP LAN của máy Linux (xem trên terminal khi server chạy) vào ô kết nối thủ công.
