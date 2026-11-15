## Agent skills

### Issue tracker

Local markdown: issues live as files under `.scratch/<feature>/` in this repo. See `docs/agents/issue-tracker.md`.

### Triage labels

Default vocabulary: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: one `GLOSSARY.md` and `docs/adr/` at the repo root. See `docs/agents/domain.md`.

## Working agreements

- **Every change is made in a git worktree**, never in the main checkout: code, docs, ADRs, `GLOSSARY.md` and issues under `.scratch/` alike. Enter a worktree before the first edit; a subagent that changes files gets its own worktree. Only read-only investigation stays in the main checkout. Commit inside the worktree; never push to `master`.

## Secrets and external infrastructure

- **Secrets**: adding, editing or re-encrypting a sops file, changing age recipients, or recovering a lost key → `secrets/README.md`.
- **Cloud resources outside NixOS** (OpenTofu, one directory per provider under `infra/`): changing them, rotating their keys, rebuilding them, or restoring the off-site Backup → `infra/<provider>/README.md` (today: `infra/scaleway/`).
