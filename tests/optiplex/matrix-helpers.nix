# Shared by the VM checks of the Matrix stack (services/synapse.nix, mautrix-*.nix, coturn.nix).
# Returns the Python environment of the test client and Python source with helpers for the checks
# (the checks of one tier share a namespace, but each check includes this text itself so it runs alone).
{pkgs}: rec {
  # matrix-nio with end-to-end encryption (vodozemac, not libolm) as the test client, pyyaml to read configs
  py = pkgs.python3.withPackages (ps: [(ps.matrix-nio.override {withVodozemac = true;}) ps.pyyaml ps.bcrypt]);

  user = "testuser";
  password = "Correct-Horse-Battery-9!"; # satisfies Synapse's password policy

  helpers = ''
    MX_USER, MX_PASS = "${user}", "${password}"
    MX_PY = "${py}/bin/python3"

    def mx_ensure_user():
        # created over loopback with the registration shared secret, like the admin does
        rc, out = optiplex.execute(
            f"matrix-synapse-register_new_matrix_user -u {MX_USER} -p '{MX_PASS}' --no-admin 2>&1"
        )
        assert rc == 0 or "already taken" in out or "User ID already taken" in out, out

    def mx_dm(bot, command="help"):
        # encrypted DM with the bridge bot; prints and returns the decrypted reply
        store = f"/tmp/nio-{bot}"
        optiplex.succeed(f"rm -rf {store}; mkdir -p {store}")
        out = optiplex.succeed(
            f"{MX_PY} ${./matrix-e2ee-dm.py} http://127.0.0.1:8008 @{MX_USER}:nnik.dev '{MX_PASS}' @{bot}:nnik.dev {store} {command} 2>&1",
            timeout=300,
        )
        print(out)
        return out
  '';
}
