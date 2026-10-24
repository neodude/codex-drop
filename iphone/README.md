# Codex Drop for iPhone

Share 1–10 images into the last active Codex draft on your Mac. The Mac brings the running Codex app forward, preserves draft text and existing attachments, and leaves the message unsent.

## Build and install

Build with Xcode supporting the configured SDK targets and required Swift concurrency features. Personal Team support for the app, extension and shared-Keychain capability set remains unverified.

From the repository root, copy `scripts/codex-drop.local.example.json` to ignored `codex-drop.local.json` and set your `apple_team_id`. Configure `ios_bundle_id` and `keychain_group_suffix` there if the defaults are unavailable to your team. The app ID defaults to `guide.guidelabs.codexdrop`; the extension derives `.Share`. The group suffix defaults to `guide.guidelabs.codexdrop.shared`. See [shared configuration](../README.md#build-and-install-the-mac-receiver) for environment/CLI precedence.

```sh
python3 scripts/configure-iphone.py
xcodegen generate --spec iphone/project.yml
open iphone/CodexShot.xcodeproj
```

The configuration script writes ignored `iphone/Local.xcconfig`. Regenerate it after changing local configuration, then regenerate the Xcode project. Do not manually set `AppIdentifierPrefix`; Xcode expands the signing prefix for the app and share extension. Both targets must use the same shared Keychain group.

In Xcode, select the **CodexShot** scheme, your connected iPhone, and your own development team. Allow Xcode to manage development provisioning, resolve any account-specific signing issue, then Build and Run. The visible app is **Codex Drop**. Install both the host app and its embedded share extension. No App Store or TestFlight distribution is supplied here.

## Pair and share

1. Open Codex Drop on your Mac, confirm the receiver and Accessibility status, and choose **Pair Phone…**. Keep Codex running and the Mac awake/unlocked on the same Wi-Fi.
2. Open Codex Drop on iPhone, allow Camera and Local Network access when asked, and scan the QR. Keep it private: it contains a bearer credential. The app verifies pinned HTTPS before saving pairing.
3. Select the intended conversation on the Mac. On iPhone, select images and choose **Share → Codex Drop**. Add the extension to share-sheet favourites if needed.
4. Wait for verification. A fully verified share dismisses automatically. A partial, blocked, or uncertain result requires inspection of the Mac draft.

The extension prepares/uploads images in selection order before committing the complete batch. Cancel before commit prevents attachment. After commit, **Close** stops waiting on the phone; Mac delivery may continue. It never automatically retries an uncertain request. A fresh share remains possible after an older blocked or uncertain result.

## Limits and privacy

- At most 10 images, 20 MiB per input/prepared PNG, 12 million pixels per image, and 100 MiB of prepared PNGs per batch.
- PNG input remains byte-identical; other supported images convert to PNG. The phone does not persist image bytes.
- Pairing uses `WhenUnlockedThisDeviceOnly` shared Keychain storage. HTTPS sessions pin the paired leaf certificate and refuse redirects. Bonjour discovers the receiver; it does not establish trust.
- Transfers use local Wi-Fi without a relay or OpenAI API key. Codex may stage/upload attachments before Send.
- Mac runtime files live in `~/Library/Application Support/Codex Drop/`. Receiver image artifacts become eligible for cleanup 30 days from receipt; credentials, receipts, hashes, and logs remain. Phone originals and Codex copies are unaffected. See [storage details](../README.md#storage-and-privacy).

An upload receipt alone is not attachment verification. Confirmation is polled for up to 120 seconds; interruption or timeout requires Mac review. Do not resend verified images blindly.

## Update, unpair, and remove

Keep your Apple team, app/extension bundle IDs, and shared Keychain suffix unchanged for updates. Install the new build over the existing app through Xcode. Changing identifiers creates a separate installation and may lose access to existing pairing; the old personal namespace has no automatic migration into the current one. Re-pair the new installation.

**Forget pairing** clears this phone's local credential without rotating the Mac identity or disconnecting other phones. Use it before removing the app if you want to clear local pairing: iOS can retain Keychain entries after app deletion. Remove the app through iOS's normal controls.

If sharing fails, check Local Network permission, the Mac's lock/sleep state, Accessibility permission, and selected conversation. Review partial results on the Mac before starting a new share. See [troubleshooting](../README.md#troubleshooting).

## Development

`project.yml` is the XcodeGen source; generated projects and `Local.xcconfig` are ignored. Run `./run-iphone-checks.command` from the repository root for isolated LAN/TLS/client/image checks. These do not target the live Codex draft or general clipboard. Signed app/extension builds, physical installation, permissions, and real sharing are separate validation steps.

The simulator-only **CodexSharePreview** scheme renders the same share status view without pairing, receiver access, shared images, or clipboard use. Build for a simulator with `CODE_SIGNING_ALLOWED=NO`. Launch with `--scenario uploading`, `finding`, `confirming`, `unpaired`, `blocked`, or `uncertain`; add `--compact --large-text` for a compact accessibility preview. This fixture is not embedded in the shipping app.

Historical physical shares passed on earlier builds. The current identity/configuration and storage changes still require fresh real-device sharing; see [validation gaps](../docs/development.md#validation-and-known-gaps).
