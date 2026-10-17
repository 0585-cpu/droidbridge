#!/usr/bin/env bash
# Pinned, dynamically linked LGPL dependency. Never package Homebrew's OS-specific binary.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
version=1.0.30
sha=fea36f34f9156400209595e300840767ab1a385ede1dc7ee893015aea9c6dbaf
work="$root/build/libusb"
archive="$work/libusb-$version.tar.bz2"
source_dir="$work/libusb-$version"
architectures="${DROIDBRIDGE_LIBUSB_ARCHS:-$(uname -m)}"
mkdir -p "$work"
if [ ! -f "$archive" ]; then
  curl --fail --location --retry 2 "https://github.com/libusb/libusb/releases/download/v$version/libusb-$version.tar.bz2" -o "$archive.part"
  mv "$archive.part" "$archive"
fi
echo "$sha  $archive" | shasum -a 256 -c -
if [ ! -d "$source_dir" ]; then tar -xjf "$archive" -C "$work"; fi
products=()
for architecture in $architectures; do
  case "$architecture" in arm64|x86_64) ;; *) echo "Unsupported architecture: $architecture" >&2; exit 2 ;; esac
  prefix="$work/install-$architecture-macos14"
  if [ ! -f "$prefix/lib/libusb-1.0.0.dylib" ]; then
    mkdir -p "$work/objects-$architecture"
    (
      cd "$work/objects-$architecture"
      MACOSX_DEPLOYMENT_TARGET=14.0 CFLAGS="-O2 -arch $architecture -mmacosx-version-min=14.0" \
        LDFLAGS="-arch $architecture -mmacosx-version-min=14.0" \
        "$source_dir/configure" --host="$architecture-apple-darwin" --prefix="$prefix" --disable-static --enable-shared
      make -j "$(sysctl -n hw.ncpu)"
      make install
    )
  fi
  products+=("$prefix/lib/libusb-1.0.0.dylib")
done
mkdir -p "$work/package"
lipo -create "${products[@]}" -output "$work/package/libusb-1.0.0.dylib"
install_name_tool -id '@rpath/libusb-1.0.0.dylib' "$work/package/libusb-1.0.0.dylib"
cp "$source_dir/COPYING" "$work/package/libusb-COPYING.txt"
# Distribute the exact corresponding source alongside the library (LGPL 2.1 section 6).
cp "$archive" "$work/package/libusb-source.tar.bz2"
echo "libusb $version ready: $work/package"
