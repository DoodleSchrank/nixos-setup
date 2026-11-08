## Agent skills

### Issue tracker

Local markdown: issues live as files under `.scratch/<feature>/` in this repo. See `docs/agents/issue-tracker.md`.

### Triage labels

Default vocabulary: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: one `GLOSSARY.md` and `docs/adr/` at the repo root. See `docs/agents/domain.md`.

## Secrets and external infrastructure

- **Secrets**: adding, editing or re-encrypting a sops file, changing age recipients, or recovering a lost key → `secrets/README.md`.
- **Cloud resources outside NixOS** (OpenTofu, one directory per provider under `infra/`): changing them, rotating their keys, rebuilding them, or restoring the off-site Backup → `infra/<provider>/README.md` (today: `infra/scaleway/`).
