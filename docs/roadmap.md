# Roadmap and current limits

The current scope is source-built, same-Wi-Fi screenshot sharing into an unsent Codex draft. These are follow-ups and limits, not promises of a release date.

- Complete fresh-clone signing/build validation with independent local configuration and fresh real-phone acceptance after application identity and runtime-storage changes.
- Investigate intermittent Mac Accessibility-window acquisition refusals and broaden multi-window/live Codex compatibility testing without weakening destination guards.
- Add phone-to-Codex video sharing for recordings from iPhone and Android. First verify Codex's video attachment support, supported formats, and size/duration limits, then extend transfer and attachment verification while preserving the unsent draft. This is a later follow-up after image-delivery reliability.
- Investigate remaining visible `com.guidelabs.*` names and legacy or cached app registrations. Current identifiers use `guide.guidelabs.*`; reconcile older references while preserving signing, pairing, Keychain access, and Accessibility permissions.
- Expand Android runtime coverage to the unrun supported versions, including API 28–29 and 31–35, and longer physical-device reliability checks.
- Evaluate distribution packaging separately: self-contained Python, universal Mac builds, notarization, and store delivery are outside the current source-only release.
- Per-phone revocation and remote/cellular transport are unsupported. Same-Wi-Fi use remains the supported workflow.

See [development and known gaps](development.md#validation-and-known-gaps) for the evidence behind these limits. UI previews, local automated checks, signed builds, and real-device delivery are distinct validation layers.
