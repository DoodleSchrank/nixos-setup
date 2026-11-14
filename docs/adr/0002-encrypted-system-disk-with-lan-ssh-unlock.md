---
status: accepted
---

# Encrypted System disk, unlocked only over SSH from the LAN

The Optiplex's System disk is one LUKS2 partition (plus the unencrypted ESP) holding btrfs and the swapfile. It boots into an initrd SSH server on port 2222 and waits there until Yannik types the passphrase from the home LAN. There is no TPM enrollment and no port forward. The point is to protect what the System disk holds at rest, above all `/etc/ssh/ssh_host_ed25519_key`, the sops-nix age identity that decrypts every secret in this repo. Each boot needing a human in the house is the deliberate price.

## Considered options

- **Unencrypted System disk** (rejected): unattended reboots just work, but the age identity and the decrypted secrets that swap can contain would sit in plaintext on a removable NVMe.
- **TPM2 auto-unlock with SSH as fallback** (rejected): ordinary reboots come up on their own, but a stolen box (not just a stolen disk) unlocks itself.
- **Forwarding the unlock port, or a VPN** (rejected for now): either would allow unlocking away from home. But the initrd has no firewall, and the old WireGuard VPN is retired.

## Consequences

- After any power cut or reboot, nothing runs until someone unlocks it from the LAN. That includes blocky, so the whole home has no DNS until then. This is accepted; the external monitor's host-down alert is the cue to go unlock it. Don't "fix" it by quietly adding TPM auto-unlock or a public port.
- The Data disk stays unencrypted ext4 (ticket 03). All State, including the databases, is **not** protected at rest by this decision; only the System disk is.
- The initrd SSH server has its own ed25519 host key, never the main one, because initrd secrets sit unencrypted on the ESP. The key is kept with the host-key copy in Backup so clients' known_hosts stays valid across reinstalls.
- nixos-anywhere installs need `--disk-encryption-keys`, and the first boot after the Cutover has to be unlocked from the LAN. The VM test harness rehearses the initrd unlock.

## Amendment (2026-11-10): the PC unlocks, without typing

Yannik no longer types the passphrase on each boot. The PC does it with one command, `machines/optiplex/unlock-optiplex.sh`. The passphrase lives in `secrets/luks.yaml` (key `luks_passphrase`), encrypted only to Yannik's age key, so the PC's sops key is the only way to read it.

What stays the same:

- A human still has to run the unlock from the home LAN after every boot. The PC is that human's device; the rule is "a person in the house triggers the unlock", not "a person types a passphrase".
- No TPM, no auto-unlock on the box, no forwarded port. The initrd still waits for a LAN SSH session.
- The initrd host key and the Data disk handling are unchanged.

What changes, and the cost:

- A stolen Optiplex alone still cannot unlock itself, because the passphrase is not on it. A stolen Optiplex together with the PC could be unlocked, because the PC's age key decrypts the file. The PC already holds the age key and the host-key copy, so this adds little exposure beyond what the PC already carries, but the risk is now "PC plus box" rather than "box alone".
- The passphrase exists only in `secrets/luks.yaml`. It was generated with `openssl rand` and never displayed, so there is no Vaultwarden entry or printout of it. The file is in git but encrypted; recovery depends entirely on the age key, which needs its own Vaultwarden copy and printout.

Rejected in the same review: the passphrase on the Optiplex itself (that is TPM-like auto-unlock by another name), and Tang network unlock (needs an always-on host on the LAN, which the PC is not).
