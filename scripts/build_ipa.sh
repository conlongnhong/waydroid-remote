#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT_DIR/ios/WaydroidRemote/WaydroidRemote.xcodeproj"
SCHEME="WaydroidRemote"
BUILD_DIR="$ROOT_DIR/build"
ARCHIVE_PATH="$BUILD_DIR/$SCHEME.xcarchive"
IPA_PATH="$BUILD_DIR/$SCHEME.ipa"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Lỗi: build IPA cần macOS + Xcode. Máy hiện tại không phải macOS." >&2
  exit 2
fi

command -v xcodebuild >/dev/null || {
  echo "Lỗi: chưa có xcodebuild. Hãy cài Xcode rồi chạy lại." >&2
  exit 2
}

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

if [[ -n "${EXPORT_OPTIONS_PLIST:-}" ]]; then
  [[ -f "$EXPORT_OPTIONS_PLIST" ]] || {
    echo "Lỗi: EXPORT_OPTIONS_PLIST không tồn tại: $EXPORT_OPTIONS_PLIST" >&2
    exit 2
  }

  xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -sdk iphoneos \
    -archivePath "$ARCHIVE_PATH" \
    archive \
    -allowProvisioningUpdates

  EXPORT_DIR="$BUILD_DIR/export"
  xcodebuild \
    -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportOptionsPlist "$EXPORT_OPTIONS_PLIST" \
    -exportPath "$EXPORT_DIR"

  EXPORTED_IPA="$(find "$EXPORT_DIR" -maxdepth 1 -type f -name '*.ipa' -print -quit)"
  [[ -n "$EXPORTED_IPA" ]] || { echo "Xcode không tạo IPA sau khi export." >&2; exit 1; }
  cp "$EXPORTED_IPA" "$IPA_PATH"
  echo "Đã tạo IPA đã ký: $IPA_PATH"
  exit 0
fi

# Unsigned fallback, useful for validating the project on any Mac with Xcode.
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -sdk iphoneos \
  -archivePath "$ARCHIVE_PATH" \
  archive \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO

APP_PATH="$ARCHIVE_PATH/Products/Applications/$SCHEME.app"
[[ -d "$APP_PATH" ]] || { echo "Không tìm thấy app sau khi archive." >&2; exit 1; }

PAYLOAD_DIR="$BUILD_DIR/Payload"
mkdir -p "$PAYLOAD_DIR"
cp -R "$APP_PATH" "$PAYLOAD_DIR/"
(cd "$BUILD_DIR" && zip -qry "$(basename "$IPA_PATH")" Payload)
rm -rf "$PAYLOAD_DIR"

echo "Đã tạo IPA unsigned: $IPA_PATH"
echo "IPA này cần ký bằng Apple Developer certificate trước khi cài lên iPhone."
