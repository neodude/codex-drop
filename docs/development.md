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

Automated checks and manual acceptance are separate. Keep exact device, build, toolchain, sample and execution records in ignored local artifacts; publish only generic coverage and known limitations.
