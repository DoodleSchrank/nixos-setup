# Secrets (sops-nix)

Every secret the NixOS configs need lives here, encrypted with [sops](https://github.com/getsops/sops) to age keys. sops-nix decrypts them on the target host at activation time. Never commit a secret in clear.

## Recipients (`.sops.yaml`)

| Anchor | age recipient | Private key lives in |
|---|---|---|
| `yannik` | `age17pp73lun70gl0gyuqeg6grk4mq3zcm76gfz3d0tltcdg7a02npqqhfdy9k` | `~/.config/sops/age/keys.txt` on the PC (created 2023-09-12). Copies: Vaultwarden, printout |
| `optiplex` | `age1af8w3qyudp0ydghyfpzdgauansycaadprwa49wjqmuug5zy25ycsjqd3hn` | derived from the Optiplex's `/etc/ssh/ssh_host_ed25519_key` |

Rules:
- `optiplex/*.yaml` is encrypted to `yannik` + `optiplex`.
- Everything else to `yannik` only.

The Optiplex's host key is kept across reinstalls: nixos-anywhere re-injects it with `--extra-files` from the copy in Backup. That's why its age recipient stays the same.

## Layout

One file per service, mirroring `machines/optiplex/services/<service>.nix`: `optiplex/<service>.yaml`. The full list of planned files and keys is in the wayfinder ticket *Harvest Portainer compose secrets* (`.scratch/optiplex-nixos-migration/issues/25-…`). Key files (signing keys, PEMs, whole config files) go in too, as multi-line values placed by sops-nix with owner and mode. Only data the apps rewrite themselves stays in `/state`.

Present so far:
- `optiplex/restic.yaml`: off-site Backup bucket and repository password. See `infra/scaleway/README.md`.
- `optiplex/host.yaml`: `yannik_password_hash`, yannik's console password (hash from `nix shell nixpkgs#mkpasswd -c mkpasswd -m yescrypt`). If the file is missing, the build only warns and there is no console login.

## Recipes

```sh
cd secrets
sops optiplex/<service>.yaml        # create or edit (needs ~/.config/sops/age/keys.txt)
```

**Derive a host's age recipient** from its SSH host key:
```sh
ssh-keyscan -p 25560 -t ed25519 optiplex | ssh-to-age
```
(`ssh-to-age` is not in the Arch repos: use `nix run nixpkgs#ssh-to-age` on a Nix machine, or the AUR package.)

**After changing recipients** in `.sops.yaml`, re-encrypt every affected file:
```sh
sops updatekeys optiplex/*.yaml
```

**The Optiplex's host key is lost** (for example, a reinstall without `--extra-files`):
1. Derive the new host's recipient.
2. Replace `optiplex` in `.sops.yaml`.
3. Run `sops updatekeys` with your own key.
4. Deploy.

**Your own key is lost:** the files can still be decrypted on the Optiplex with its host key (`SOPS_AGE_SSH_PRIVATE_KEY_FILE=/etc/ssh/ssh_host_ed25519_key sops -d …`, as root). Generate a new key with `age-keygen`, replace `yannik`, and run `sops updatekeys` there. Then back up the new key (Vaultwarden, printout).
