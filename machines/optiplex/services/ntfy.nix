# ntfy (https://ntfy.nnik.dev, public): the push channel of the Optiplex's alerts. Failed units
# (notify-failure@), smartd and healthchecks all post to one topic; the Android app subscribes to it
# over the public vhost.
#
#   * services.ntfy-sh on loopback (25581), behind Caddy (`behind-proxy`), `auth-default-access =
#     deny-all`: nobody reads or writes anything without a login or token.
#   * Users and tokens are declarative (environment file from a sops template, see below). Two users:
#     `yannik` (password hash from sops, read-only on the topic, for the phone) and `publisher` (no
#     usable password, only ever used through its token, write-only on the topic, for the host).
#   * No State to back up: user.db and the message cache live in the module's DynamicUser
#     /var/lib/ntfy-sh on the System disk and are rebuilt from the environment on every start.
#   * The host pushes over loopback (optiplex.monitoring.ntfy.url below), so alerts still go out when
#     blocky or Caddy is broken. The monitoring.nix hook and smartd both read that option.
#   * Stays on in restoreMode: no State, and alerts during the restore window are worth having.
#
# Secrets (secrets/optiplex/ntfy.yaml): `yannik_password_hash` (bcrypt, `htpasswd -nbBC 10 x <pw>`
# without the `x:`; the clear password goes to Vaultwarden only) and `publisher_token` (`tk_` plus 29
# characters of [a-z0-9]). If the file is missing, ntfy stays off and the alert hook only logs.
{
  config,
  lib,
  ...
}: let
  cfg = config.optiplex;
  ntfySecrets = cfg.secretsDir + "/ntfy.yaml";
  haveSecrets = builtins.pathExists ntfySecrets;

  port = 25581;
  topic = config.optiplex.monitoring.ntfy.topic;
  tokenPath = config.sops.secrets."ntfy/publisher_token".path;

  wrapPy = name: body: "def ${name}():\n" + lib.concatMapStringsSep "\n" (l: "    " + l) (lib.splitString "\n" body) + "\n${name}()\n";

  # Placeholder hash for the token-only user: well formed, but no password has this bcrypt hash.
  unusableHash = "$2a$10$" + lib.concatStrings (lib.genList (_: ".") 53);
in {
  config = lib.mkMerge [
    {
      warnings = lib.optional (!haveSecrets) ''
        secrets/optiplex/ntfy.yaml does not exist (looked in ${toString cfg.secretsDir}): ntfy stays off and failed units only log.
        Create it with fresh values (keys: yannik_password_hash, publisher_token); the clear password goes to Vaultwarden:
          pw="$(openssl rand -base64 18)"; echo "ntfy password for Vaultwarden: $pw"
          hash="$(nix shell nixpkgs#apacheHttpd -c htpasswd -nbBC 10 x "$pw" | cut -d: -f2)"
          tok="tk_$(openssl rand -hex 32 | head -c 29)"
          (cd secrets && printf "yannik_password_hash: '%s'\npublisher_token: %s\n" "$hash" "$tok" | sops --encrypt --input-type yaml --output-type yaml --filename-override optiplex/ntfy.yaml /dev/stdin > optiplex/ntfy.yaml)
        and `git add` it.
      '';
    }

    (lib.mkIf haveSecrets {
      sops.secrets."ntfy/yannik_password_hash" = {
        sopsFile = ntfySecrets;
        key = "yannik_password_hash";
        restartUnits = ["ntfy-sh.service"];
      };
      sops.secrets."ntfy/publisher_token" = {
        sopsFile = ntfySecrets;
        key = "publisher_token";
        restartUnits = ["ntfy-sh.service"];
      };
      sops.templates."ntfy.env" = {
        content = ''
          NTFY_AUTH_USERS=yannik:${config.sops.placeholder."ntfy/yannik_password_hash"}:user,publisher:${unusableHash}:user
          NTFY_AUTH_ACCESS=yannik:${topic}:read-only,publisher:${topic}:write-only
          NTFY_AUTH_TOKENS=publisher:${config.sops.placeholder."ntfy/publisher_token"}:optiplex-host
        '';
        restartUnits = ["ntfy-sh.service"];
      };

      services.ntfy-sh = {
        enable = true;
        environmentFile = config.sops.templates."ntfy.env".path;
        settings = {
          base-url = "https://ntfy.nnik.dev";
          listen-http = "127.0.0.1:${toString port}";
          behind-proxy = true;
          auth-default-access = "deny-all";
        };
      };

      # The alert hook (monitoring.nix) and smartd push to the local server with the publisher token.
      optiplex.monitoring.ntfy = {
        url = "http://127.0.0.1:${toString port}";
        tokenFile = tokenPath;
      };

      # useACMEHost = "nnik.dev" comes from the Edge helper. No body-size or timeout tuning: Caddy
      # streams long polls and upgrades websockets by itself; flush_interval -1 keeps the JSON
      # stream of /<topic>/json from being buffered.
      services.caddy.virtualHosts."ntfy.nnik.dev".extraConfig = ''
        import security
        reverse_proxy 127.0.0.1:${toString port} {
            flush_interval -1
        }
      '';

      # --- VM check --------------------------------------------------------------------------------------
      # Through Caddy from the LAN client and the internet client. The test secrets: user yannik has the
      # password "test" (bcrypt hash in the mirror, see gen-test-secrets.sh). The topic is the harness's `test`.
      optiplex.vmTest.checks.ntfy.script = wrapPy "ntfy_main" ''
        optiplex.wait_for_unit("ntfy-sh.service")
        optiplex.wait_until_succeeds("curl -fsS http://127.0.0.1:${toString port}/v1/health | grep -q '\"healthy\":true'")
        # loopback only
        optiplex.succeed("test -z \"$(ss -H -ltn 'sport = :${toString port}' | grep -v 127.0.0.1)\"")
        # State: none on /state, the System disk holds the module's own directory
        optiplex.fail("ls /state | grep -i ntfy")
        tok = optiplex.succeed("cat ${tokenPath}").strip()
        assert tok.startswith("tk_") and len(tok) == 32, tok
        topic = "${topic}"

        def curl(client, addr, args):
            return client.succeed(f"curl -sk --resolve ntfy.nnik.dev:443:{addr} {args}")

        for client, addr in ((lan, "192.168.178.20"), (outside, "203.0.113.1"), (lan, "fd65:c1a5:7d2b::20")):
            # public vhost: the health endpoint answers from everywhere, on both families
            client.wait_until_succeeds(f"curl -fsk --resolve ntfy.nnik.dev:443:{addr} https://ntfy.nnik.dev/v1/health | grep -q healthy", timeout=120)
        ADDR = {"lan": "192.168.178.20", "outside": "203.0.113.1"}

        def code(client, args, path=""):
            addr = ADDR["outside" if client is outside else "lan"]
            return curl(client, addr, f"-o /dev/null -w '%{{http_code}}' {args} https://ntfy.nnik.dev/{topic}{path}").strip()

        # deny-all: no login, no publish, no read
        assert code(outside, "-d nope") == "403", code(outside, "-d nope")
        assert code(outside, "-H 'Authorization: Bearer tk_wrongwrongwrongwrongwrongwrong'") in ("401", "403")
        # the publisher token publishes, but cannot read; yannik reads, but cannot publish
        assert code(lan, f"-H 'Authorization: Bearer {tok}' -d 'alert from the ntfy check'") == "200"
        assert code(lan, f"-H 'Authorization: Bearer {tok}'", "/json?poll=1&since=all") == "403"
        assert code(lan, "-u yannik:test -d nope") == "403"
        assert code(lan, "-u yannik:wrong", "/json?poll=1") == "401"
        got = curl(lan, "192.168.178.20", f"-u yannik:test 'https://ntfy.nnik.dev/{topic}/json?poll=1&since=all'")
        assert "alert from the ntfy check" in got, got
        # a long poll through Caddy delivers a message published while it waits
        optiplex.succeed(f"(curl -sk --max-time 20 -u yannik:test --resolve ntfy.nnik.dev:443:192.168.178.20 'https://ntfy.nnik.dev/{topic}/json' > /tmp/ntfy-stream.log &) ; sleep 2")
        optiplex.succeed(f"curl -fsS -H 'Authorization: Bearer {tok}' -d 'streamed message' http://127.0.0.1:${toString port}/{topic}")
        optiplex.wait_until_succeeds("grep -q 'streamed message' /tmp/ntfy-stream.log", timeout=20)
      '';
    })
  ];
}
