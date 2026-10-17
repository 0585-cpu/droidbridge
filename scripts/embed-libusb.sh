#!/usr/bin/env bash
set -euo pipefail
root="${SRCROOT:?Xcode SRCROOT is required}"
DROIDBRIDGE_LIBUSB_ARCHS="${ARCHS:?Xcode ARCHS is required}" "$root/scripts/build-libusb.sh"
frameworks="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}"
licenses="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/ThirdParty"
mkdir -p "$frameworks" "$licenses"
cp "$root/build/libusb/package/libusb-1.0.0.dylib" "$frameworks/"
cp "$root/build/libusb/package/libusb-COPYING.txt" "$licenses/"
cp "$root/build/libusb/package/libusb-source.tar.bz2" "$licenses/"
if [ "${CODE_SIGNING_ALLOWED:-NO}" = YES ]; then
  codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" --timestamp=none "$frameworks/libusb-1.0.0.dylib"
fi
