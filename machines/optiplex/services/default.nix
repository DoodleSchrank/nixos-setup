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
    ./homeassistant.nix
    ./transmission.nix
    ./nfs.nix
    ./vaultwarden.nix
  ];
}
