# Development and verification

Build instructions live in the [main README](../README.md), [iPhone guide](../iphone/README.md), and [Android guide](../android/README.md). Keep signing settings in ignored local files. Generated projects, bundles, signing keys, runtime state, and evidence logs must remain untracked.

## Isolated checks

From the repository root on a Mac with the documented Apple toolchain:

```sh
python3 -m unittest discover -s scripts -p 'test_*.py'
./scripts/test-receiver.zsh
./scripts/test-iphone.zsh
./scripts/test-macos.zsh
```

The standard runner builds the native helper, exercises delivery-policy checks, HTTP queue/batch/storage tests, and private pasteboard/lock checks. The iPhone runner exercises LAN/TLS transport and Swift client/image checks. Mac lifecycle/presentation/shutdown tests use temporary fake receiver processes and a separate fixture. These commands do not establish real phone-to-Codex attachment success.

For Python-only receiver checks:

```sh
python3 -m unittest discover -s receiver -p 'test_*.py'
```

Android build/unit/lint and disposable-emulator commands are in the [Android guide](../android/README.md#development-and-verification). Emulator transport checks use real Python HTTPS with disposable pins and fake attachment delivery. They cannot validate Accessibility behavior in Codex.

## Interactive diagnostics

The optional UI runner, `./scripts/test-receiver-ui.zsh`, opens an isolated AppKit fixture and uses a private pasteboard. It does not target Codex.

Build the native helper with `zsh receiver/build.zsh` and inspect `./MacAttachmentReceiver --help` for diagnostic modes. Live attachment checks are available directly through `receiver/live_test.py`. These developer tools can inspect Accessibility, change focus, manipulate the clipboard or attempt an attachment. Read the relevant source before running them. Never point fixtures at the normal runtime store; use an explicit temporary `--data-dir` where supported. Stop a Terminal receiver before starting the packaged app.

Keep detailed logs and captures in ignored `.codex-artifacts/`. Do not commit QR codes, credentials, device identifiers, personal screenshots, private draft text, or signing/provisioning material. Synthetic protocol fixtures and required third-party notices belong in source control.

## Validation and known gaps

Automated checks cover transfer bounds, pinning and authentication, byte preservation, mixed batches, cancellation, queue recovery, clipboard restoration, destination guards, application lifecycle and synthetic media validation. Real-device image and single-video attachment have also been checked. Exact device inventories, installed builds, toolchain versions, diagnostic receipts and testing-session narratives belong only in ignored local artifacts.

Some lifecycle instrumentation coverage remains unresolved. Remaining manual coverage includes broader platform/provider behavior, mixed image/video shares on phones, maximum-size files through Codex itself, clean-configuration builds, and optimized release builds. Compatibility requirements come from the checked-in deployment targets and build configuration; they are not a description of a particular contributor's computer.

An optimized iOS build can encounter a compiler assertion in the share controller. A Debug build is useful for isolating that failure, but Debug validation does not establish Release readiness. Distribution packaging, notarization, and fresh-install/runtime acceptance remain separate gates.

## Real-device acceptance checklist

Use a disposable unsent draft with known text and existing attachments. Confirm pairing and permissions, then a single image, video, and mixed batch. Verify the destination, unchanged draft, preserved existing attachments, new attachments in order, automatic phone dismissal on success, and no sent message. Repeat the relevant background/lock/provider scenarios. Inspect blocked or uncertain results rather than retrying blindly.

Keep detailed receipts, original-file hash comparisons and device/build records in ignored `.codex-artifacts/`. A locked or unavailable destination must block safely. After restoring the destination, a fresh share must work without replaying an earlier request. Clipboard delivery restores saved contents only while it still owns the clipboard; newer copied contents are preserved. Interactive fixture checks require an explicit handoff and a bounded timeout.
