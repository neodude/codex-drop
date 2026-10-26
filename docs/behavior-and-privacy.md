# Behavior and privacy

This describes Codex Drop’s original-file delivery. Previous versions converted non-PNG images to PNG on the phone. On Android that included sRGB bitmap rendering; both paths could discard animation or other representations. The original-file path removes those operations.

## Files and metadata

Codex Drop preserves the exact file bytes supplied by the source sharing app. It does not decode image pixels, resize, recompress, convert formats, normalize orientation/color, strip metadata, or flatten animation. When an iPhone source offers multiple concrete image representations, Codex Drop prefers the first PNG, JPEG, GIF or WebP in the source's ordering. If none is offered, the first concrete image is still checked and refused by the receiver if unsupported. Photos or another source app can choose an edited/exported representation before handing it to Codex Drop; the preservation boundary starts with that supplied file, not the underlying camera/library asset.

Some iPhone sources advertise JPEG but provide a serialized `UIImage` container. For that known container, Codex Drop can extract the embedded encoded image bytes unchanged. It uses a restricted secure decoder for the image-data field without creating a `UIImage` or rendering pixels. Containers without a readable embedded image, with unexpected object classes, animation fields, or separate rotation/mirroring are refused rather than rendered or converted. The extracted file's actual format is still checked by the Mac.

The limits are 50 MiB per file, 100 MiB per batch, and 1–10 files. JPEG, PNG, GIF and WebP remain supported images. MP4 and QuickTime MOV are accepted as original file attachments when bounded container checks identify a video track and supported visual sample description; audio-only or encrypted recordings are refused. Video validation reads container metadata, never frames or audio samples. Video duration is not separately capped; the byte limits still apply. Audio, timestamps, orientation metadata and other original bytes are preserved. HEIC/HEIF and other unsupported formats are refused before attachment; there is no automatic conversion. These checks do not promise that Codex itself can play or analyze every accepted codec.

On iPhone, a format refusal includes diagnostic details identifying the detected container, byte count, requested type, and source-advertised types. Container identification reads metadata without decoding pixels. These details appear on the failure sheet; they do not include filenames, paths, image contents, or embedded metadata values.

Photos sharing options control its export: Automatic chooses a format for the destination; Most Compatible can supply JPEG; Current prevents file-format conversion and can therefore supply an HEIC that Codex Drop will refuse. Codex Drop does not change those settings. See [Apple’s sharing guide](https://support.apple.com/guide/iphone/share-photos-and-videos-iphf28f17237/ios).

Embedded EXIF location, timestamps, comments, color profiles and other metadata remain in the original bytes. Remove sensitive metadata yourself before sharing if desired. Original filenames are not transmitted; private receiver copies use generated names with the detected format’s extension. Codex controls its own subsequent copying, rendering, upload and processing.

Phone clients use app-private temporary storage during transfer. Normal completion, errors and cancellation release those copies; Android unlinks its temporary spool immediately. An interrupted iOS process can leave a temporary file for OS-managed cleanup. No phone photo-library originals are removed or modified.

## Mac clipboard, foreground and draft access

The receiver brings the already running Codex app forward, focuses the last active conversation’s composer, and leaves Codex foreground. It reads the draft, attachment labels and window identity through Accessibility to guard the destination and preserve existing content. It never presses Send.

Before pasting, it reads advertised clipboard representations into memory so it can restore them. Readable representations are preserved byte-for-byte. If a PNG or JPEG representation is advertised but unavailable, it can generate that alternate representation from a readable, single-image PNG, TIFF, HEIC, HEIF, or JPEG on the same clipboard item, preserving the original representation and image orientation. If UTF-8 or external UTF-16 plain text is advertised but unavailable, it can reconstruct that encoding from a readable valid equivalent on the same item; existing readable bytes remain unchanged. External UTF-16 sources require a byte-order mark. Invalid text, other unreadable formats, or images that cannot supply those alternatives still block delivery. There is no explicit snapshot byte/count limit. It temporarily replaces the clipboard with a file URL to a stable private original-file copy, then restores the saved clipboard only if nobody has replaced it. A newer user clipboard is preserved. Clipboard-history tools may observe the temporary item or retain its file reference.

Uploaded bytes, queue hashes and handoff file bytes are checked for integrity. “Verified attached” means the Accessibility checks observed an added attachment with the existing draft and attachments intact. It is not a hash comparison with Codex’s internal copy or confirmation of a cloud upload. Codex may stage/upload an attachment before Send; an unsent message is not a no-cloud-processing guarantee.

## Network and credentials

Image transfers go directly from phone to paired Mac over HTTPS; there is no hosted Codex Drop relay or OpenAI API key. Bonjour discovers the advertised `_codexshot._tcp` service. The receiver normally listens on all IPv4 interfaces at TCP 9443; it does not enforce a particular Wi-Fi SSID or subnet. Certificate pinning and a shared bearer credential authenticate requests. Clients refuse redirects.

The pairing QR contains a credential and must remain private. iPhone pairing and timing counters use device-only Keychain storage shared with the extension. Android pairing is encrypted with an Android Keystore key; pairing/receipts are excluded from backup and device transfer. An authenticated paired client can list queue receipt metadata. Forgetting pairing on one phone removes its local pairing; Android receipt history remains. It does not revoke that credential on the Mac. There is no per-phone revocation UI.

Android QR pairing uses Google Play services code scanner. Its module may download before first use. Google says scanning inputs/results stay on-device and its ML Kit APIs can contact Google for updates and send performance/utilization metrics. See [Google code scanner](https://developers.google.com/ml-kit/vision/barcode-scanning/code-scanner) and [ML Kit privacy](https://developers.google.com/ml-kit/terms). This dependency is separate from image transfers. No custom Codex Drop analytics endpoint was found in the source audit; runtime traffic from every dependency has not been exhaustively measured.

## Storage, lifetime and automatic actions

Mac runtime files live under `~/Library/Application Support/Codex Drop/`, with account-private directory/file permissions. The app does not add application-level encryption to those files. It stores original images and handoff copies, queue records, hashes, receipts, credentials, TLS identity and structural logs. Draft text is used in memory for guards; diagnostics record structural metadata rather than raw draft text.

Receiver-owned images, handoff copies, result/manifests and abandoned uploads become eligible for deletion after 30 days. Maintenance runs at startup and daily while running, protects active deliveries and retries failed deletion later. Receipts, hashes, credentials, queue history and logs remain. It does not delete source photos, Codex copies or clipboard-manager history. See [storage and removal](../README.md#storage-and-privacy).

Opening the Mac app starts its receiver. Close Window keeps it running; Quit confirms before stopping it. Open at Login is opt-in and launches hidden. No automatic updater is implemented.

All files stage before a batch commits. Cancellation before commit prevents attachment; closing the phone sheet after commit cannot undo Mac delivery. The receiver attaches in order and stops an uncertain batch. It does not automatically retry failed/uncertain shares; receipt polling only checks an existing request. Interrupted work is quarantined on restart. A fresh share can proceed independently of an old uncertain result.
