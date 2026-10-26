# Public repository privacy

Treat tracked files, commit messages, Git metadata and pushed refs as public.

- Describe product behavior, declared compatibility requirements, generic test coverage and known limitations.
- Keep contributor computer/device inventories, actual tested OS/toolchain versions, account details, personal paths, signing/provisioning identities, device identifiers, recording provenance and detailed execution receipts in ignored `.codex-artifacts/` files.
- Do not copy private diagnostic or conversation narratives into documentation, plans or commit messages. Use generic descriptions of manual coverage and outstanding gates.
- Preserve legitimate compatibility targets, public branding/copyright attribution and clearly synthetic test fixtures.
- Review the staged diff and proposed commit message for private details before committing. Use a public-safe GitHub noreply identity and UTC commit metadata.
- Do not merge or push pre-sanitization local branches or snapshot refs. Rebase or cherry-pick needed changes onto the sanitized public history first.
