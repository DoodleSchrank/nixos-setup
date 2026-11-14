# One line per Kept service ticket: ./<service>.nix
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
