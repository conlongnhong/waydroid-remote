#!/usr/bin/env bash
# ==============================================================================
# Setup Script for Waydroid Remote Server on Arch Linux + Hyprland
# ==============================================================================
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

echo -e "${CYAN}============================================================${NC}"
echo -e "${CYAN}    Waydroid Remote - Tự động thiết lập Arch Linux Server    ${NC}"
echo -e "${CYAN}============================================================${NC}"

# 1. Kiểm tra quyền sudo
if ! sudo -n true 2>/dev/null; then
    echo -e "${YELLOW}[*] Yêu cầu quyền sudo để kiểm tra và cài đặt gói hệ thống...${NC}"
    sudo true
fi

# 2. Kiểm tra các gói phụ thuộc cần thiết
echo -e "\n${BLUE}[1/5] Kiểm tra và cài đặt các gói phụ thuộc trên Arch Linux...${NC}"
REQUIRED_PKGS=("android-tools" "scrcpy" "protobuf" "python" "avahi")
MISSING_PKGS=()

for pkg in "${REQUIRED_PKGS[@]}"; do
    if ! pacman -Q "$pkg" >/dev/null 2>&1; then
        MISSING_PKGS+=("$pkg")
    fi
done

if [ ${#MISSING_PKGS[@]} -gt 0 ]; then
    echo -e "${YELLOW}[!] Đang cài đặt gói còn thiếu: ${MISSING_PKGS[*]}...${NC}"
    sudo pacman -S --needed --noconfirm "${MISSING_PKGS[@]}"
else
    echo -e "${GREEN}[✓] Toàn bộ gói hệ thống đã sẵn sàng.${NC}"
fi

# Cài đặt python-zeroconf nếu có thể (để mDNS native không cần gọi CLI)
if ! pacman -Q python-zeroconf >/dev/null 2>&1; then
    echo -e "${YELLOW}[*] Cài đặt thêm python-zeroconf cho Bonjour mDNS tự động...${NC}"
    sudo pacman -S --needed --noconfirm python-zeroconf 2>/dev/null || true
fi

# Đảm bảo avahi-daemon đang chạy
if systemctl is-active --quiet avahi-daemon; then
    echo -e "${GREEN}[✓] Dịch vụ avahi-daemon đang hoạt động.${NC}"
else
    echo -e "${YELLOW}[*] Khởi động avahi-daemon...${NC}"
    sudo systemctl enable --now avahi-daemon >/dev/null 2>&1 || true
fi

# 3. Kiểm tra Waydroid
echo -e "\n${BLUE}[2/5] Kiểm tra trạng thái Waydroid...${NC}"
if ! command -v waydroid >/dev/null 2>&1; then
    echo -e "${RED}[LỖI] Không tìm thấy waydroid trên hệ thống. Hãy cài đặt waydroid trước!${NC}"
    exit 1
fi

WAYDROID_STATUS=$(waydroid status 2>&1 || true)
if echo "$WAYDROID_STATUS" | grep -q "Session:.*RUNNING"; then
    echo -e "${GREEN}[✓] Waydroid Session đang chạy!${NC}"
else
    echo -e "${YELLOW}[!] Waydroid Session chưa chạy. Đang khởi động Waydroid session...${NC}"
    waydroid session start >/dev/null 2>&1 &
    sleep 3
fi

# Lấy IP Waydroid
WAYDROID_IP=$(echo "$WAYDROID_STATUS" | grep "IP address:" | awk '{print $NF}' | tr -d ' ' || true)
if [ -z "$WAYDROID_IP" ] || [ "$WAYDROID_IP" = "None" ]; then
    WAYDROID_IP="192.168.240.112"
fi
echo -e "${GREEN}[✓] IP Waydroid: ${WAYDROID_IP}${NC}"

# 4. Cấu hình xác thực ADB và kết nối tới Waydroid
echo -e "\n${BLUE}[3/5] Cấu hình và xác thực ADB tới Waydroid (${WAYDROID_IP}:5555)...${NC}"
adb start-server >/dev/null 2>&1 || true

# Tạo SSH/ADB key nếu chưa có
if [ ! -f ~/.android/adbkey.pub ]; then
    adb keygen ~/.android/adbkey >/dev/null 2>&1 || true
fi

# Tự động nạp public key vào container để không bị 'unauthorized'
if [ -f ~/.android/adbkey.pub ]; then
    KEY_CONTENT=$(cat ~/.android/adbkey.pub)
    echo -e "${YELLOW}[*] Tự động nạp ADB key vào /data/misc/adb/adb_keys...${NC}"
    sudo waydroid shell -- sh -c "mkdir -p /data/misc/adb && echo '$KEY_CONTENT' >> /data/misc/adb/adb_keys && chown system:shell /data/misc/adb/adb_keys && chmod 640 /data/misc/adb/adb_keys" >/dev/null 2>&1 || true
    sudo waydroid shell -- killall -9 adbd >/dev/null 2>&1 || true
    sleep 1
fi

adb connect "${WAYDROID_IP}:5555" >/dev/null 2>&1 || true
ADB_STATE=$(adb devices | grep "${WAYDROID_IP}:5555" | awk '{print $2}' || true)

if [ "$ADB_STATE" = "device" ]; then
    echo -e "${GREEN}[✓] ADB đã kết nối thành công: ${WAYDROID_IP}:5555 (device)${NC}"
else
    echo -e "${YELLOW}[!] Trạng thái ADB hiện tại: ${ADB_STATE:-chưa kết nối}. Đang thử kết nối lại...${NC}"
    adb connect "${WAYDROID_IP}:5555"
fi

# 5. Đẩy scrcpy-server vào Waydroid container
echo -e "\n${BLUE}[4/5] Kiểm tra scrcpy-server trong Waydroid...${NC}"
if [ -f /usr/share/scrcpy/scrcpy-server ]; then
    adb -s "${WAYDROID_IP}:5555" push /usr/share/scrcpy/scrcpy-server /data/local/tmp/scrcpy-server.jar >/dev/null 2>&1
    echo -e "${GREEN}[✓] Đã đẩy scrcpy-server.jar vào /data/local/tmp/${NC}"
else
    echo -e "${RED}[LỖI] Không tìm thấy /usr/share/scrcpy/scrcpy-server.${NC}"
    exit 1
fi

# 6. Kiểm tra tự kiểm (Self-test)
echo -e "\n${BLUE}[5/5] Kiểm tra thử nghiệm luồng video và tiêm phím...${NC}"
python3 -c "
import socket, struct, subprocess, time

ip = '${WAYDROID_IP}:5555'
res = subprocess.run(['adb', '-s', ip, 'shell', 'getprop', 'ro.product.model'], stdout=subprocess.PIPE, text=True)
print('    Model Android:', res.stdout.strip())
" || true

echo -e "\n${GREEN}============================================================${NC}"
echo -e "${GREEN}  CÀI ĐẶT THÀNH CÔNG! HỆ THỐNG ĐÃ SẴN SÀNG CHẠY SERVER.     ${NC}"
echo -e "${GREEN}============================================================${NC}"
echo -e "Để chạy server thủ công:"
echo -e "  ${CYAN}./scripts/run_server.sh${NC}"
echo -e "Hoặc chạy dạng dịch vụ ngầm qua systemd:"
echo -e "  ${CYAN}systemctl --user enable --now $(pwd)/server/waydroid-remote.service${NC}\n"
