# Connection UI refresh — 2026-09-28

The Android and macOS interfaces now follow the simple connection-first structure of Tetrd: a large status, one contextual primary action, and a separate settings page. The design uses Korean guidance, coral accents, larger spacing, and readable traffic units. No Tetrd source code or artwork is included.

## Android

- The Connection tab shows USB, Mac pairing, and cellular readiness with the action appropriate to the current state.
- The Settings tab holds Mac management, TTL/Hop Limit, DNS blocking, speed limits, and diagnostics. Unsaved profile edits survive tab navigation.
- Pairing opens a code-comparison dialog above either tab; dismissing the dialog rejects the request.
- A running Android relay is described as ready to share, because it cannot establish that the Mac has installed its routes.
- The theme follows system light/dark appearance. Debug-only synthetic screenshot fixtures do not open USB or start the relay.

## macOS

- A normal connection window replaces the dense menu-bar popover. The menu-bar menu opens that window, shows status, and offers disconnect/quit.
- The Connect action prepares the relay and starts the tunnel in sequence.
- Settings and detailed diagnostics are separate from the main connection controls.
- Only the helper's running tunnel state displays Connected. Retained fail-closed state and failed teardown retain a Disconnect action. Quit waits for successful teardown.
- The approval sheet explicitly explains that the two codes are compared rather than typed.

## Verification

- macOS shared checks: 249 passed, 0 failed.
- Signed macOS host/helper build and bundle validation passed.
- The signed app's connection window and settings page were opened and visually inspected on the Mac. The final coral primary button was also checked in the running app.
- Android: 130 JVM tests passed; lint reported 0 errors and 17 warnings; debug app and test APK builds passed.
- Three synthetic Android screens (USB setup, relay ready, settings) were rendered on the connected SM-F966N and visually inspected. These use fixture state, not a live tunnel.
- Final direct device run: 4 tests passed (screen capture, draft preservation/profile reload, TCP TTL, IPv6 UDP Hop Limit). The draft regression test waits for the rendered state and confirms both tab navigation and profile reload.
- Android 16 initially displayed a native 16 KB compatibility warning. The custom socket library's linker alignment was corrected; all packaged native libraries and APK ZIP alignment now pass the 16 KB checks. The warning no longer blocks the device activity, and both socket-policy loopback tests pass. This follows the [Android native-library alignment guidance](https://developer.android.com/guide/practices/page-sizes).
- Build and device evidence is recorded in `build/evidence/2026-09-28-ui/`; packaged hashes are in `build/artifacts/UI-REFRESH-SHA256SUMS.txt`.

The prior network acceptance results remain in `device-validation-2026-09-28.md`. This UI validation does not repeat the end-to-end cellular tunnel tests or start a new tunnel.

## Device test cleanup incident

The first Gradle `connectedDebugAndroidTest` run automatically uninstalled the target and test APKs during cleanup, clearing Android app data including the saved pairing. The UI APK was reinstalled. The Mac still has its previous pairing record, so the next real connection requires removing that record in Mac Settings and pairing the phone again.

Subsequent UI runs use `adb install -r` and direct `am instrument` rather than the Gradle connected-device task. These runs keep the APK and app data installed, and screenshot fixtures never start the real relay. Do not use Gradle device-test cleanup on a paired phone whose app data must be retained.

## Delivery

- Installed Android APK: `build/artifacts/DroidBridge-ui-refresh-debug.apk`.
- Signed Mac application archive: `build/artifacts/DroidBridge-ui-refresh-mac.zip`; the new connection window is running on this Mac.
- Test APK: `build/artifacts/DroidBridge-ui-refresh-androidTest.apk`.
- Android screen previews: `build/evidence/2026-09-28-ui/screenshots/`.
- The tunnel remains stopped and the Mac default route remains `en0`.
