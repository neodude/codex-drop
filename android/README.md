# Codex Drop for Android

Pair with the Mac receiver and share 1–10 photos or MP4/MOV videos into the last active Codex draft. Delivery preserves draft text and existing attachments, verifies each attachment, and never presses Send.

Requires Android 9 / API 28+, Google Play services for QR scanning, and the same reachable Wi-Fi as the Mac. Keep the Mac awake and unlocked with Codex running. Android 17 asks for Local Network access during pairing. The app requests no camera, photo-library, or storage permission. Google's QR scanner may need internet access for its first module download; file transfer itself stays on the LAN.

## Build and install

Use JDK 17 and Android SDK Platform 37, Build Tools 37.0.0, and Platform Tools. Set `ANDROID_HOME`, or create ignored `android/local.properties` containing `sdk.dir=/absolute/path/to/sdk`.

From the repository root:

```sh
./android/gradlew -p android :core:test :app:testDebugUnitTest :app:lintDebug :app:assembleDebug
```

The Gradle wrapper provides the pinned Gradle version. The debug APK is `android/app/build/outputs/apk/debug/app-debug.apk`. Select the intended available phone explicitly:

```sh
adb devices
adb -s PHONE_SERIAL install -r android/app/build/outputs/apk/debug/app-debug.apk
```

Replace `PHONE_SERIAL` with the intended device's serial. Debug builds use the local Android debug key; a different machine may generate a different key. Preserve the key if you expect to update that installation. These development APKs are not Play Store releases.

### Optional signed Release build

For an updateable Release APK, use your own stable keystore and keep it outside the public tree. Add the following keys to ignored `android/local.properties`:

```properties
codexDrop.storeFile=/absolute/path/to/your-release.keystore
codexDrop.storePassword=YOUR_LOCAL_STORE_PASSWORD
codexDrop.keyAlias=YOUR_KEY_ALIAS
codexDrop.keyPassword=YOUR_LOCAL_KEY_PASSWORD
```

Equivalent per-key environment overrides are `CODEX_DROP_ANDROID_STORE_FILE`, `CODEX_DROP_ANDROID_STORE_PASSWORD`, `CODEX_DROP_ANDROID_KEY_ALIAS`, and `CODEX_DROP_ANDROID_KEY_PASSWORD`. Relative keystore paths resolve from `android/`. All four values are required if any are set. Never commit signing material or print passwords in build logs.

```sh
./android/gradlew -p android :app:assembleRelease
```

With signing configured, the output is `android/app/build/outputs/apk/release/app-release.apk`; otherwise it is `app-release-unsigned.apk` in the same directory. An unsigned APK cannot be installed until signed. Install a signed APK using `adb -s PHONE_SERIAL install -r PATH_TO_APK`.

## Pair and share

1. Keep Codex Drop running on the Mac and open **Pair Phone…**.
2. Open Android Codex Drop → **Pair your Mac**. Allow Local Network access if asked, then scan the QR. Keep it private: it contains a credential. The app verifies pinned HTTPS before saving pairing.
3. Select the intended Codex conversation on the Mac. It may then stay in the background; you do not need to click its composer.
4. Share a screenshot, use the native screenshot preview's Share action, or select photos and videos → **Codex Drop**. Verified success closes the share Activity automatically. Review any error before closing.

Pairing uses device-only AES-GCM Android Keystore storage. Pairing and receipts are excluded from cloud backup and device transfer. **Forget pairing** removes this phone's pairing without rotating the Mac identity or disconnecting other phones.

## Interrupted and partial shares

Original files are copied/uploaded serially; attachment begins only after the full batch is staged. Limits are 10 files, 50 MiB per file and 100 MiB per batch, without a pixel quota. Codex Drop never decodes, converts, resizes, rotates, changes color profiles, or strips metadata. The sending app’s ContentProvider may supply an exported representation before Codex Drop receives it; the bytes it supplies are preserved exactly. JPEG, PNG, GIF, WebP, MP4 and QuickTime MOV are accepted; video containers must contain a video track. Audio-only files and other video containers are unsupported. Original video and audio tracks are preserved without transcoding. HEIC/HEIF and other unsupported formats are refused before attachment; they are never added as generic files. Original filenames are replaced with internal names. Unsupported formats fail rather than being converted. Cancel before commit prevents attachment. Close after commit stops waiting; the Mac may still finish attaching.

Check the Mac draft after uncertainty. Do not blindly resend files already attached. **Check receipt** and **Check last share** look up an existing request and never replay it. Rotation preserves the in-flight ViewModel; process restoration shows review/receipt lookup rather than replaying a share. Concurrent shares are refused rather than queued; a fresh share remains possible after an old uncertain result.

Transfers stay on local Wi-Fi without an API key or relay. Codex may stage/upload attachments before Send. Mac attachment artifacts become eligible for cleanup 30 days from receipt; receipts, hashes, credentials, and logs remain. See [storage details](../README.md#storage-and-privacy).

## Updates and removal

The application ID is `guide.guidelabs.codexdrop`. Keep it and your signing key unchanged for updates and increase `versionCode` for later releases. Install using `adb install -r` as above. If Android reports a signature mismatch, recover the original key or use a deliberately separate installation; uninstalling is not a routine repair because it discards data and pairing.

An older app using the previous application ID is a separate installation. No pairing migration is provided; pair the new application again. Keep the older installation until you have deliberately verified the new one. Remove an app through Android's normal controls when desired; this does not remove files already attached in Codex.

## Development and verification

```sh
./android/gradlew -p android :core:test :app:testDebugUnitTest :app:lintDebug :app:assembleDebug :app:assembleRelease
./android/gradlew -p android :app:assembleDebugAndroidTest
python3 android/scripts/test-emulator.py --serial emulator-5580
python3 android/scripts/harden-emulator.py --serial emulator-5580
```

Start a disposable emulator first and use its actual serial. Both Python runners reject physical devices. They use isolated receiver state and fake attachment delivery; they do not paste into Codex. The hardening runner supports `--groups`; API-specific permission cases are skipped where inapplicable. Logs, screenshots, and delivery audits are saved under ignored `.codex-artifacts/`.

If the emulator's `10.0.2.2` host route stalls, either runner accepts `--adb-reverse` to use a disposable localhost tunnel. It preserves pinned HTTPS and removes only its own port mapping afterward. This mode verifies client/protocol and lifecycle behavior but does not exercise the emulator LAN route or Android's network-layer Local Network permission enforcement.

Automated checks cover the original-file protocol, limits, cancellation and error handling. Physical-device/provider behavior and optimized Release builds require separate verification. Keep device, build, toolchain and execution records in ignored local artifacts.

Photo and video transfers use paired local HTTPS. QR pairing uses Google Play services code scanning; its module may download before first use, and Google documents SDK performance/utilization metrics. See [behavior and privacy](../docs/behavior-and-privacy.md) for that dependency, metadata, clipboard use and storage.
