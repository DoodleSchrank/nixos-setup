# Test overlay for the hermetic nixosTest (tests/optiplex/vm.nix): the real machines/optiplex
# plus what a qemu VM without the real hardware needs. Everything here is test-only.
#
#   - disko off, qemu-vm filesystems with the Data disk re-added (real UUID)
#   - the NIC matched by the MAC qemu gives the vlan interface; the real static address works
#   - test secrets (secrets/test/optiplex, test age key) and a test ssh key for yannik
#   - DDNS / restic timers off (optiplex.vmTest.offlineTimers)
#   - ntfy stub, a failing unit, the demo service
{withDataDisk}: {
  config,
  lib,
  pkgs,
  ...
}: let
  qemuCommon = import (pkgs.path + "/nixos/lib/qemu-common.nix") {inherit lib; inherit (pkgs) stdenv;};
  nodeNumber = config.virtualisation.test.nodeNumber;

  # An ext4 Data disk with the real UUID and an empty state/ directory. Attached with
  # snapshot=on, so the store image stays read-only and a run starts from it fresh.
  dataDisk = pkgs.runCommand "optiplex-data-disk.img" {nativeBuildInputs = [pkgs.e2fsprogs];} ''
    mkdir -p seed/state
    truncate -s 256M $out
    mkfs.ext4 -q -F -E root_owner=0:0 -U 70ca9b25-a1cd-46fa-bcbd-66780935c999 -L tbssd -d seed $out
  '';
in {
  imports = [./test-secrets.nix ./offline.nix ./demo-service.nix];

  # --- real config, adapted --------------------------------------------------------------
  disko.enableConfig = false; # the test framework brings its own root

  boot.loader.systemd-boot.enable = lib.mkForce false;
  boot.loader.efi.canTouchEfiVariables = lib.mkForce false;
  # The initrd unlock is the install test's job (tests/optiplex/install.nix).
  boot.initrd.network.ssh.enable = lib.mkForce false;
  boot.initrd.systemd.network.enable = lib.mkForce false;

  # qemu-vm.nix replaces every fileSystems entry with virtualisation.fileSystems.
  virtualisation.fileSystems = config.optiplex.dataFileSystems;
  virtualisation.qemu.drives = lib.optional withDataDisk {
    name = "data";
    file = "${dataDisk}";
    driveExtraOpts = {
      format = "raw";
      snapshot = "on";
    };
    deviceExtraOpts.serial = "tbssd";
  };

  virtualisation.memorySize = lib.mkDefault 3072;
  virtualisation.cores = lib.mkDefault 2;

  # --- network: the LAN as 192.168.178.0/24 + the ULA, and a separate "internet" vlan ------
  # eth1 (vlan 1) is the LAN NIC, eth2 (vlan 2) the public side. The addresses are assigned here.
  virtualisation.vlans = lib.mkForce [];
  virtualisation.interfaces = {
    eth1 = {vlan = 1;};
    eth2 = {vlan = 2;};
  };
  optiplex.network.mac = qemuCommon.qemuNicMac 1 nodeNumber;
  systemd.network.networks."10-lan".address = ["fd65:c1a5:7d2b::20/64"]; # the RA-derived ::20 address
  systemd.network.networks."20-outside" = {
    matchConfig.Name = "eth2";
    address = ["203.0.113.1/24" "2001:db8:2::1/64"];
    networkConfig.IPv6AcceptRA = false;
  };

  # marker for the test script: which mode did this boot come up in
  environment.etc."optiplex-restore-mode".text = if config.optiplex.restoreMode then "1" else "0";

  # --- ACME against pebble (node `acme`, DNS-01 through its challenge test server) -----------------
  # Keeps the lego/ACME wiring of the edge service file and swaps only the CA and the DNS hook.
  # Applies to the cert `nnik.dev` (decided in ticket 21), when Caddy is enabled.
  networking.hosts."192.168.178.60" = ["acme.test"];
  security.pki.certificateFiles = [(pkgs.path + "/nixos/tests/common/acme/server/ca.cert.pem")];
  security.acme.defaults.server = "https://acme.test/dir";
  security.acme.certs."nnik.dev" = lib.mkIf config.services.caddy.enable {
    server = "https://acme.test/dir";
    dnsProvider = lib.mkForce "exec";
    dnsPropagationCheck = lib.mkForce false;
    dnsResolver = lib.mkForce "192.168.178.60:53"; # pebble-challtestsrv
    credentialFiles = lib.mkForce {};
    environmentFile = pkgs.writeText "acme-test.env" ''
      EXEC_PATH=${pkgs.writeShellScript "acme-dns-hook" ''
        set -euo pipefail
        # lego's exec provider: <present|cleanup> <fqdn> <value>
        if [ "$1" = present ]; then
          ${pkgs.curl}/bin/curl -fsS --data "{\"host\": \"$2\", \"value\": \"$3\"}" http://192.168.178.60:8055/set-txt
        else
          ${pkgs.curl}/bin/curl -fsS --data "{\"host\": \"$2\"}" http://192.168.178.60:8055/clear-txt
        fi
      ''}
      EXEC_POLLING_INTERVAL=1
      EXEC_PROPAGATION_TIMEOUT=1
      EXEC_SEQUENCE_INTERVAL=1
    '';
  };
  optiplex.vmTest.checks.acme-test-ca = lib.mkIf config.services.caddy.enable {
    script = ''
      # lego got the wildcard cert from the test CA (pebble) through the DNS-01 hook
      optiplex.wait_until_succeeds("openssl x509 -in /var/lib/acme/nnik.dev/cert.pem -noout -issuer | grep -i pebble", timeout=90)
      san = optiplex.succeed("openssl x509 -in /var/lib/acme/nnik.dev/cert.pem -noout -ext subjectAltName")
      assert "DNS:nnik.dev" in san and "DNS:*.nnik.dev" in san, san
    '';
  };

  # --- failure alerts: a stub ntfy and a unit that fails on purpose -------------------------------
  optiplex.monitoring.ntfy = {
    url = lib.mkForce "http://127.0.0.1:8080";
    topic = lib.mkForce "test";
    tokenFile = lib.mkForce null;
  };
  systemd.services.ntfy-stub = {
    wantedBy = ["multi-user.target"];
    script = ''
      exec ${pkgs.python3}/bin/python3 -u - <<'PY'
      import http.server
      class H(http.server.BaseHTTPRequestHandler):
          def do_POST(self):
              n = int(self.headers.get("Content-Length", 0))
              body = self.rfile.read(n).decode()
              with open("/tmp/ntfy.log", "a") as f:
                  f.write("PATH=%s\nTITLE=%s\nPRIO=%s\n%s\n---\n" % (self.path, self.headers.get("Title"), self.headers.get("Priority"), body))
              self.send_response(200); self.end_headers()
      http.server.HTTPServer(("127.0.0.1", 8080), H).serve_forever()
      PY
    '';
  };
  systemd.services.failing = {
    # started by the test, not at boot
    serviceConfig.Type = "oneshot";
    script = "echo about-to-fail-marker; exit 3";
  };

  environment.systemPackages = [pkgs.python3 pkgs.e2fsprogs pkgs.openssl];
}
