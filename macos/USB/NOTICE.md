# libusb

`Sources/CAoaUSB/vendor/libusb.h` is the unmodified header from libusb 1.0.30,
licensed under LGPL 2.1 or later. See `LIBUSB-COPYING` and the copyright notices
in the header. DroidBridge's wrapper and Swift code remain under the project license.

Source: https://github.com/libusb/libusb/releases/tag/v1.0.30

`scripts/build-libusb.sh` verifies the release archive SHA-256 and builds an
unmodified dynamic library for macOS 14. The app distributes the license and
exact source archive under `Contents/Resources/ThirdParty`. The library is at
`Contents/Frameworks/libusb-1.0.0.dylib` and is loaded dynamically. To test a
modified compatible library, rebuild with the script or replace that dylib and
re-sign your local app. Modification and reverse engineering for debugging those
library modifications are permitted under the LGPL.
