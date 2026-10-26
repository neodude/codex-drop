# Roadmap and current limits

The current scope is source-built, same-Wi-Fi image and recording sharing into an unsent Codex draft. These are follow-ups and limits, not promises of a release date.

- Complete fresh-clone signing/build validation with independent local configuration and fresh real-phone acceptance after application identity and runtime-storage changes.
- Investigate intermittent Mac Accessibility-window acquisition refusals and broaden multi-window/live Codex compatibility testing without weakening destination guards.
- Complete remaining mixed-batch and platform video acceptance, including original-byte identity, unchanged drafts and clipboard restoration. Keep the exact testing inventory in ignored local artifacts.
- Expand supported Android runtime coverage and longer physical-device reliability checks.
- Evaluate distribution packaging separately: self-contained Python, universal Mac builds, notarization, and store delivery are outside the current source-only release.
- Per-phone revocation and remote/cellular transport are unsupported. Same-Wi-Fi use remains the supported workflow.

See [development and known gaps](development.md#validation-and-known-gaps) for the evidence behind these limits. UI previews, local automated checks, signed builds, and real-device delivery are distinct validation layers.

Shipping application identifiers use `guide.guidelabs.*`. Older names in historical diagnostics or standalone fixtures do not require a shipping-identity migration.
