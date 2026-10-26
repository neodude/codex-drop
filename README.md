# Codex Drop

Share screenshots and recordings from your iPhone or Android phone into a Codex draft on your Mac.

Choose 1–10 images or videos, share them to Codex Drop, and keep working. The Mac brings the running Codex app forward, attaches the files to the last active conversation, and leaves the message unsent. Existing draft text and attachments are preserved. If the receiver cannot establish a safe destination or verify an attachment, it stops for review.

Codex Drop is an independent utility, not an official OpenAI product or an OpenAI-endorsed integration. This repository provides source for local development builds. Store releases and notarized Mac downloads are not provided.

## How it works

1. Run Codex and Codex Drop on an awake, unlocked Mac.
2. Pair your phone by scanning the QR in **Pair Phone…** over the same Wi-Fi.
3. Select the intended conversation in Codex. You can then use another Mac app.
4. On your phone, select images or recordings and choose **Share → Codex Drop**. A verified share closes automatically.

The phone stages the complete batch over paired HTTPS before attachment starts. The Mac attaches files in order and **never presses Send**. An interrupted or uncertain share is never retried automatically; inspect the draft before sharing again. A new share can proceed while an older blocked or uncertain result remains in history.

Codex Drop copies the exact file bytes supplied by the sharing app: no conversion, resizing, recompression, rotation, color changes, metadata stripping, or removal of audio. Limits are **50 MiB per file, 100 MiB per batch, and 10 files**. Images can be JPEG, PNG, GIF or WebP; recordings can be MP4 or QuickTime MOV containing a supported video track. HEIC/HEIF, audio-only recordings, and unsupported formats are refused before attachment. Source apps such as Photos may supply an edited/exported representation before Codex Drop receives it. Video is attached as an original local file; Codex and its available tools determine how it is inspected.

No OpenAI API key, hosted server, or cloud relay is required. Codex itself may stage or upload attachments before you send the message. An unsent draft does not mean no cloud processing has occurred.

## Requirements

| Component | Requirement |
| --- | --- |
| Mac receiver | macOS 26.0+, running Codex desktop app, Accessibility permission, same reachable Wi-Fi as the phone |
| Apple build tools | Xcode with support for the configured SDK targets and required Swift concurrency features; Python 3.10+ with TLS and SQLite; XcodeGen for iPhone |
| Apple signing | Your own Apple Development certificate and team; see below |
| iPhone | iOS 18.0+; signed app and share extension |
| Android phone | Android 9 / API 28+; Google Play services for QR scanning |
| Android build tools | JDK 17, Android SDK Platform 37, Build Tools 37.0.0, Platform Tools (`adb`) |

The Swift compiler must support `@concurrent`; Swift language mode 6 alone is insufficient. Android's minimum version is a build requirement, not evidence of testing every supported version. See [validation and known gaps](docs/development.md#validation-and-known-gaps).

Guest Wi-Fi, client isolation, VPN routing, and firewalls can prevent discovery or transfer. The Mac must remain awake and unlocked. The receiver brings an already running Codex app forward; it does not launch Codex for you.

## Get the source

```sh
git clone https://github.com/neodude/codex-drop.git
cd codex-drop
```

Keep the checkout in a stable location. The Mac development bundle records the checkout and external Python executable; both must remain available. This build is not a self-contained, universal, or notarized distribution.

## Build and install the Mac receiver

Install Xcode and select its command-line tools, then check the tools you intend to use:

```sh
xcodebuild -version
xcrun swiftc --version
python3 --version
```

Copy the local configuration example:

```sh
cp scripts/codex-drop.local.example.json codex-drop.local.json
```

Set `apple_team_id` to your own 10-character Apple team ID. The ignored file is shared by the Mac builder and iPhone configuration generator. Optional `mac_signing_identity` selects an exact Apple Development identity or certificate SHA-1 when your team has multiple usable identities. Never copy someone else's certificate, private key, or provisioning profile.

The other defaults are `guide.guidelabs.codexdrop` for the iOS app, `guide.guidelabs.codexdrop.mac` for the Mac, and `guide.guidelabs.codexdrop.shared` for the shared Keychain suffix. Use identifiers available to your own team. Keep them stable for updates; the iOS extension ID is derived by appending `.Share`.

You can override each JSON key with its `CODEX_DROP_` environment variable: `CODEX_DROP_APPLE_TEAM_ID`, `CODEX_DROP_MAC_SIGNING_IDENTITY`, `CODEX_DROP_IOS_BUNDLE_ID`, `CODEX_DROP_MAC_BUNDLE_ID`, or `CODEX_DROP_KEYCHAIN_GROUP_SUFFIX`. Matching command-line options take precedence over environment variables, then local JSON, then defaults. Use `--help` on the scripts for options.

For an existing installation, quit Codex Drop normally and let active delivery finish **before building**. The builder replaces the destination bundle and refuses to replace an app or helper that is still running.

```sh
python3 scripts/build-mac-app.py
python3 scripts/verify-mac-app.py
open "Codex Drop.app"
```

The builder signs the launcher and native helpers, verifies the bundle, and preserves a prior bundle in ignored `.codex-artifacts/builds/`. It does not launch the app. The default output is `Codex Drop.app` at the checkout root. Use `--output` for another app location and the verifier's `--app` for that same location. Rebuild after moving the checkout or replacing its Python installation.

In the status window, confirm **Receiver running · same Wi-Fi** and **Accessibility: allowed**. Choose **Accessibility Settings…** if needed and enable Codex Drop or its signed helper if macOS lists that name. Allow local-network/firewall access on your trusted network if prompted. Do not disable the firewall globally.

**Close Window** keeps the receiver running. Reopen Codex Drop from Finder or Spotlight to show it again. **Quit Codex Drop…** confirms before stopping phone drops and waits for active delivery to settle. **Open at Login** is opt-in for new users; existing choices are preserved. Login launches keep the window hidden. There is no Dock icon or menu-bar status item.

## Build, install, and pair your phone

- [iPhone setup](iphone/README.md): configure signing, generate the Xcode project, install the app and share extension, then scan the Mac QR.
- [Android setup](android/README.md): build/install the APK with a stable signing key, then scan the Mac QR.

Keep the QR private: it contains a pairing credential. Each phone verifies the pinned HTTPS certificate before saving pairing. **Forget pairing** clears that phone's local pairing; it does not rotate the Mac credential or disconnect other phones. There is no per-phone revocation UI.

## Storage and privacy

Runtime data lives in **`~/Library/Application Support/Codex Drop/`**, separately from the checkout. It includes pairing credentials, TLS identity, queue, images, receipts, hashes, and logs. Runtime directories and files are restricted to your Mac account. Earlier repository-local `receiver-data/` is migrated on first launch; stop older receiver processes first. Conflicting stores or a cross-volume move stop safely for review.

Cleanup runs at startup and once a day while the receiver is running. Receiver-owned screenshot, result, manifest, and abandoned upload files become eligible for deletion **30 days from receipt**. Active deliveries are protected. Failed removals are retried at a later check. Compact receipts and hashes remain to prevent duplicate replay; credentials, queue history, and the append-only log are retained. This does not delete phone originals, copies held by Codex, or clipboard-manager history.

Image transfers go directly to the paired Mac. Android’s Google QR-scanning dependency can download its scanner and send SDK performance/usage metrics to Google; see [complete behavior and privacy details](docs/behavior-and-privacy.md). Bonjour discovery is not a trust decision: the saved certificate pin and bearer credential authenticate the paired receiver. See [architecture](docs/architecture.md) for the delivery guards and limits.

## Updates and removal

For Mac updates, quit before rebuilding and retain the same signing identity, bundle ID, and runtime directory. Do not delete pairing files to fix a build or startup problem. Changed signing identity may require renewed Accessibility permission and login-item registration.

For phone updates, keep the application ID and signing key/team stable. See the platform guides for installation commands and signing caveats. Builds using older application identifiers are separate installations; the current identifiers do not migrate their phone pairing. Pair a new installation again. A successful build is not proof of a successful device update.

To remove the Mac app, finish active delivery, turn off **Open at Login**, quit, then remove the bundle. This leaves the private runtime directory intact. If you also want to erase saved credentials, screenshots, receipts, and logs, remove that directory deliberately after quitting. Retained builds in `.codex-artifacts/builds/` can be removed separately. Deleting runtime identity requires phones to pair again; Codex's attachments and phone originals are unaffected. Remove phone apps through the normal OS app-removal controls; iOS may retain Keychain entries after app removal, so use **Forget pairing** first when you want to clear local pairing.

## Troubleshooting

| Symptom | Next step |
| --- | --- |
| Receiver unavailable | Open Codex Drop; check receiver status and **Reveal Receiver Log**. Keep the Mac awake/unlocked and both devices on reachable Wi-Fi. |
| Discovery fails | Check Local Network permission, guest-network isolation, VPN routes, firewall rules, and TCP 9443. Bonjour uses `_codexshot._tcp`. IPv6-only support is unverified. |
| Accessibility denied | Grant permission to the current signed app/helper, then inspect the draft before trying a new share. Rebuild/signing changes can invalidate prior approval. |
| No safe destination | Run Codex and select one intended conversation. Remove selected draft text; multiple possible composers or a changing window/thread can block delivery. |
| Partial or uncertain result | Inspect the Mac draft and keep verified images. Untried images were not pasted. Do not blindly resend the whole batch. Receipt lookup checks an existing request; it does not retry. |
| Image rejected | Use at most 10 images, 50 MiB per file and 100 MiB per batch. There is no pixel quota or automatic shrinking. A format that Codex cannot accept is not converted. |
| Startup/migration error | Stop old Terminal receivers and inspect the log for conflicting stores, paused state, port conflict, permissions, missing Python, or identity trouble. Another receiver is never killed or adopted. |
| Android update signature mismatch | Use the original signing key and application ID. Uninstalling is not a routine update repair: it discards app data and pairing. |

Known Accessibility-window acquisition refusals remain under investigation. The receiver refuses delivery when it cannot establish a safe target; later successful shares do not prove those intermittent cases are fixed.

## Development and license

See [development and verification](docs/development.md), [architecture](docs/architecture.md), and [roadmap](docs/roadmap.md). Maintained build and verification entrypoints live in `scripts/`; developer diagnostics are described in the verification guide.

Original code is licensed under [MIT](LICENSE), copyright 2026 Thomas Bukowski. Third-party dependencies and assets retain their own licenses and notices; the project license does not relicense third-party marks. Codex and OpenAI names identify the integration target.

See [third-party components and notices](THIRD_PARTY_NOTICES.md).
