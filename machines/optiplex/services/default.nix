# One line per Kept service ticket: ./<service>.nix
# The files in _draft/ are reference material from the Oct 2024 draft; a service
# ticket deletes its draft when it writes the real file. Nothing there is imported.
{
  imports = [
    ./blocky.nix
    ./caddy.nix
    ./databases.nix
    ./ddns.nix
    ./etesync.nix
    ./gitea.nix
    ./gitea-runners.nix
    ./coturn.nix
    ./homeassistant.nix
    ./mautrix-telegram.nix
    ./mautrix-whatsapp.nix
    ./transmission.nix
    ./nfs.nix
    ./seafile.nix
    ./paperless.nix
    ./restic.nix
    ./ntfy.nix
    ./healthchecks.nix
    ./synapse.nix
    ./vaultwarden.nix
  ];
}
