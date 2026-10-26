# Architecture

Codex Drop has native iPhone and Android clients, a Python HTTPS receiver, and a signed Mac app with a native Accessibility attachment helper. It uses the existing Codex desktop composer. No API key or remote relay is involved.

## Pairing and transport

The Mac advertises a Bonjour service (`_codexshot._tcp`) and normally listens on TCP 9443. A private QR supplies the receiver identity, exact TLS certificate pin, and bearer credential. Discovery locates a service; it never substitutes for the saved trust information. Clients pin the paired leaf certificate and refuse redirects.

The iPhone app and extension share device-only Keychain pairing. Android encrypts pairing with a device-only Android Keystore key and excludes pairing/receipts from backup and device transfer. Forgetting pairing on a phone removes only its local state. There is no per-phone revocation UI, remote-network transport, or established IPv6-only support.

## Batch delivery

A share contains 1–10 images. Clients bound original files to 50 MiB each, with 100 MiB per batch and no pixel quota. They preserve the exact bytes supplied by the source app. There is no image decoding, resizing, re-encoding, color conversion, rotation or metadata stripping. Source apps may supply exported representations. The receiver detects allowed containers from bytes and uses matching internal filename extensions. All images stage before commit. Cancellation before commit prevents delivery; dismissing the phone UI after commit cannot undo a Mac attachment.

Both clients prepare the first image while discovering and connecting to the Mac. The first image upload waits for both operations to finish; later image preparation and uploads remain sequential. A failed or cancelled startup cancels and joins its pending work and releases the prepared file or image buffer.

The receiver serializes delivery and preserves compact request receipts. Each image must verify before the next is attempted. The native helper brings the running Codex app forward, locates the last active conversation, and checks its window, editor, draft, and clipboard ownership before Paste. It preserves existing text and attachments and never invokes Send. The helper hands off a stable private original file using only a file URL on the clipboard, avoiding bitmap-paste conversion. Original-byte hashes protect upload/storage and handoff files. Attachment acknowledgement observes the Codex UI; it does not verify what Codex later stores, renders, or uploads. It conditionally restores the clipboard only while it still owns the clipboard lease; a newer user clipboard is left intact.

A blocked result means the guard refused delivery. An uncertain result means an attachment may have occurred but could not be verified. A recovered interrupted delivery is not assumed successful. Neither state is automatically replayed. Review the draft before starting another share; new requests remain possible while older results are retained.

Accessibility is an external UI dependency. Codex changes, multiple possible editors, selected draft text, lock/sleep, unexpected focus changes, and unavailable AX windows may stop delivery. Some intermittent AX-window acquisition refusals remain unexplained. Safe refusal is part of the current behavior, not proof of universal compatibility.

## Private runtime storage

The canonical runtime directory is `~/Library/Application Support/Codex Drop/`. The Mac app migrates an older checkout-local `receiver-data/` store on first launch after old receivers stop. The move preserves pairing/TLS identities and queue/receipt state, rewrites stored image paths, and supports interrupted-migration recovery. Conflicting stores and cross-volume moves stop for review rather than silently merging or deleting data.

Startup and daily maintenance expire eligible receiver-owned image, result, manifest, and abandoned-upload artifacts 30 days from receipt. Active jobs are protected. Failed removals are retried later. Receipts/hashes remain for duplicate protection; credentials, queue history, and logs are retained. This cleanup does not remove phone originals, Codex copies, or clipboard-manager history.

## Mac packaging

The local Mac bundle contains signed native helpers and receiver Python sources, but uses an external Python executable and records a stable source checkout path. The current distribution is a native-architecture development build for macOS 26.0+, not a standalone Python runtime, universal binary, or notarized release.

The app runs without a Dock icon or status item. Closing its window keeps it running; Quit confirms and waits for active delivery. Login startup is optional and hidden. See [development](development.md) for isolated checks and the distinction between build evidence and live delivery.
