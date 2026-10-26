# Phone Video Sharing Implementation Plan

> **For agentic workers:** Use the existing task's parallel ownership boundaries below. Follow the failing-test, implementation, and verification steps for each task; do not commit, install, or control devices independently.

**Goal:** Share original MP4/MOV recordings from iPhone and Android into the current unsent Codex draft alongside existing image support.

**Architecture:** Extend the original-file pipeline and its metadata validation to video containers. Preserve the existing batch wire protocol, file-URL Paste, clipboard recovery/restoration, destination guards, and attachment acknowledgement. No transcoding or frame extraction during transfer.

**Tech Stack:** Python receiver, Swift/AppKit native delivery, Swift iOS share extension, Kotlin Android share client.

**Spec:** Original MP4/MOV files supplied by mobile share providers; the constraints below define transfer, verification and limits.

## Global Constraints

- Accept original MP4 and QuickTime MOV files containing a video track; audio-only containers remain unsupported.
- Keep images supported exactly as before, including Threads UIImage archive extraction and strict HEIC refusal.
- Keep limits at 50 MiB per file, 100 MiB per batch, 1–10 files; preserve audio and metadata unchanged.
- Keep existing routes, manifest fields, error-code compatibility, pairing, IDs, signing, and private storage.
- Single and mixed image/video batches retain order, original-byte hashes, cancellation, no replay, and no automatic retry.
- Never press Send. Preserve the draft, existing attachments, and newer user clipboard contents.
- No desktop takeover or phone installation without the normal explicit handoff. Local checks are distinct from real-device acceptance.

## Review Focus

- Audio-only MP4, HEIC/AVIF, malformed atom lengths, and filename/MIME spoofing must not become video attachments.
- Representative supported recordings must retain their complete original bytes through storage and native handoff.
- Video acknowledgement must match the expected new attachment while preserving existing content.
- Mixed batches and multi-item share activation must preserve order and stop on an unconfirmed item.
- Over-limit, interrupted, and unknown-provider inputs must release temporary files and leave the clipboard untouched before delivery.

## Task 1: Receiver validation and integration (root)

**Files:** `receiver/mac_receiver.py`, receiver Python tests except `test_native_batch.py`, documentation.

- [x] Add failing tests for MP4/MOV acceptance, original-byte persistence, mixed batches, malformed boxes, audio-only input, and unchanged HEIC refusal.
- [x] Extend legacy `validate_image(data)` to identify and validate supported video containers without decoding their pixels or altering bytes. Return `mp4` or `mov` for videos; existing image results and protocol remain compatible.
- [x] Run the complete receiver Python suite and validate representative synthetic recordings without modifying their bytes.

## Task 2: Native delivery (native worker)

**Files:** `receiver/DeliveryCore.swift`, `receiver/ReceiverMain.swift`, `receiver/MacPlatform.swift`, `receiver/CoreTests.swift`, `receiver/test_native_batch.py`, native build scripts if needed.

**Interface:** Add `.mp4` and `.mov` to `OriginalImageType` (retain legacy names for compatibility), classify real video containers before ImageIO image validation, extend supported attachment acknowledgements. `OriginalImage` and existing batch manifests remain unchanged.

- [x] Add failing tests for native video validation, audio-only/malformed refusal, and video/mixed acknowledgement behavior.
- [x] Implement bounded container validation and original-file staging with existing clipboard semantics.
- [x] Inspect the installed Codex file-attachment labels read-only; retain strict destination and draft guards. Report any remaining live-verification gap.
- [x] Run policy/native tests and synthetic-video original-file self-test without touching the general clipboard or Codex UI.

## Task 3: iPhone share flow (iOS worker)

**Files:** `iphone/**` only.

**Interface:** Existing batch upload accepts original supported files regardless of media kind; no wire-format change. MP4/MOV must be copied from the provider and sent unchanged. Legacy `ImageInput` APIs may remain for compatibility.

- [x] Add failing tests for movie-provider selection, limits, cancellation, mixed uploads, and original MP4/MOV byte identity.
- [x] Enable movie shares and generalize visible copy to attachments/files while preserving image archive handling.
- [x] Increment the iPhone build number and run the iPhone checks; build the app if practical without installation.

## Task 4: Android share flow (Android worker)

**Files:** `android/**` only.

**Interface:** Existing batch upload; original MP4/MOV bytes, current limits, matching image/video MIME checks.

- [x] Add failing tests for video share extraction, mixed ordering, spool cleanup, limits and original-byte transfer.
- [x] Enable video sharing and appropriate mixed-share handling, update media wording, preserve pairing and signing.
- [x] Increment versionCode and run build/unit/lint checks. Do not start an emulator or reserve physical devices.

## Integration gate

- [x] Review all worker diffs and integrate without overwriting unrelated roadmap edits.
- [x] Run receiver, iPhone, Mac and script checks plus Android checks and signed builds as appropriate.
- [x] Verify original-file byte identity and keep detailed execution metadata only in ignored local artifacts.
- [x] Prepare installable candidates and record manual acceptance privately; keep committed material limited to the feature contract and generic coverage gaps.
