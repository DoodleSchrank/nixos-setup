# Public DNS: a host-side updater keeps A + AAAA of nnik.dev and *.nnik.dev current at
# Porkbun (replaces DuckDNS and the fixed apex A record). Porkbun v3 API, no State.
#
#   ddns-porkbun [--dry-run]
#
# Owns exactly four records on nnik.dev: A and AAAA for the apex and for `*`, TTL 600.
# It reads the zone first and only edits what differs. It never touches other records
# and never deletes anything: a CNAME on a name it needs is a hard error (at the
# Cutover the old `*` CNAME is deleted by hand first).
#   IPv4  the caller's address as seen by Porkbun (`ping`, forced over IPv4)
#   IPv6  the global address on the LAN NIC that ends in ::20 (IPv6Token), never the ULA,
#         a temporary or a deprecated one. None -> AAAA stays untouched and the run fails
#         (A is still updated).
# --dry-run prints what would change and writes nothing.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.optiplex;
  dcfg = cfg.ddns;

  ddns = pkgs.writeShellApplication {
    name = "ddns-porkbun";
    runtimeInputs = [pkgs.curl pkgs.jq pkgs.iproute2 pkgs.coreutils];
    text = ''
      dry_run=0
      case "''${1:-}" in
        --dry-run) dry_run=1 ;;
        "") ;;
        *) echo "usage: ddns-porkbun [--dry-run]" >&2; exit 2 ;;
      esac

      domain=nnik.dev
      ttl=600
      api="''${PORKBUN_API_BASE:-https://api.porkbun.com/api/json/v3}"
      keydir="''${CREDENTIALS_DIRECTORY:-}"
      apikey_file="''${PORKBUN_API_KEY_FILE:-$keydir/porkbun_api_key}"
      secret_file="''${PORKBUN_SECRET_API_KEY_FILE:-$keydir/porkbun_secret_api_key}"
      rc=0

      # POST <path> [extra json fields]; the keys go through stdin, never argv.
      call() {
        local path="$1" extra="''${2:-{\}}"
        jq -n --rawfile k "$apikey_file" --rawfile s "$secret_file" --argjson e "$extra" \
          '{apikey: ($k | rtrimstr("\n")), secretapikey: ($s | rtrimstr("\n"))} + $e' \
          | curl --silent --show-error --fail-with-body --max-time 30 "''${@:3}" \
              -H 'Content-Type: application/json' --data @- "$api$path"
      }

      # --- IPv4: our public address as the API sees it (forced over IPv4) ---
      v4=$(call /ping '{}' --ipv4 | jq -r '.yourIp // empty')
      if ! [[ "$v4" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        echo "ERROR: no IPv4 address from the Porkbun ping (got '$v4')" >&2
        exit 1
      fi

      # --- IPv6: the global ...::20 address on the LAN NIC ---
      if [ -n "''${DDNS_INTERFACE:-}" ]; then
        iface="$DDNS_INTERFACE"
      else
        iface=$(ip -j link | jq -r --arg mac "''${DDNS_MAC:?DDNS_MAC or DDNS_INTERFACE must be set}" \
          '[.[] | select((.address // "") | ascii_downcase == $mac)][0].ifname // empty')
        if [ -z "$iface" ]; then
          echo "ERROR: no interface with MAC $DDNS_MAC" >&2
          exit 1
        fi
      fi
      v6=$(ip -j -6 addr show dev "$iface" scope global | jq -r '
        [.[].addr_info[]
          | select(.family == "inet6" and .scope == "global")
          | select(.local | test("^[23]"))                       # 2000::/3, not the ULA fd00::/8
          | select(.local | test("::20$"))                       # the IPv6Token
          | select(((.temporary // false) or (.deprecated // false) or (.tentative // false) or (.dadfailed // false)) | not)
          | .local][0] // empty')
      if [ -z "$v6" ]; then
        echo "ERROR: no global ::20 IPv6 address on $iface; AAAA records left untouched" >&2
        rc=1
      fi

      # --- the zone, read once ---
      zone=$(call "/dns/retrieve/$domain")
      if [ "$(jq -r '.status' <<<"$zone")" != SUCCESS ]; then
        echo "ERROR: could not read the zone: $zone" >&2
        exit 1
      fi

      sync_record() { # <name: "" or "*"> <type> <content>
        local sub="$1" type="$2" content="$3" fqdn id cur
        fqdn="$domain"
        [ -n "$sub" ] && fqdn="$sub.$domain"

        if [ "$(jq --arg n "$fqdn" '[.records[] | select(.name == $n and .type == "CNAME")] | length' <<<"$zone")" -gt 0 ]; then
          echo "ERROR: $fqdn is a CNAME; delete it at Porkbun first (not touched)" >&2
          rc=1; return
        fi
        local matches
        matches=$(jq -c --arg n "$fqdn" --arg t "$type" '[.records[] | select(.name == $n and .type == $t)]' <<<"$zone")
        case "$(jq length <<<"$matches")" in
          0)
            echo "$type $fqdn -> $content (create)"
            [ "$dry_run" = 1 ] && return
            call "/dns/create/$domain" "$(jq -n --arg n "$sub" --arg t "$type" --arg c "$content" --arg l "$ttl" \
              '{name: $n, type: $t, content: $c, ttl: $l}')" | jq -e '.status == "SUCCESS"' >/dev/null \
              || { echo "ERROR: create $type $fqdn failed" >&2; rc=1; }
            ;;
          1)
            cur=$(jq -r '.[0] | "\(.content) \(.ttl)"' <<<"$matches")
            if [ "$cur" = "$content $ttl" ]; then
              echo "$type $fqdn = $content (unchanged)"
              return
            fi
            id=$(jq -r '.[0].id' <<<"$matches")
            echo "$type $fqdn: $cur -> $content $ttl (edit)"
            [ "$dry_run" = 1 ] && return
            call "/dns/edit/$domain/$id" "$(jq -n --arg n "$sub" --arg t "$type" --arg c "$content" --arg l "$ttl" \
              '{name: $n, type: $t, content: $c, ttl: $l}')" | jq -e '.status == "SUCCESS"' >/dev/null \
              || { echo "ERROR: edit $type $fqdn failed" >&2; rc=1; }
            ;;
          *)
            echo "ERROR: several $type records on $fqdn; not touching them" >&2
            rc=1
            ;;
        esac
      }

      for sub in "" "*"; do
        sync_record "$sub" A "$v4"
        [ -n "$v6" ] && sync_record "$sub" AAAA "$v6"
      done
      exit "$rc"
    '';
  };
in {
  options.optiplex.ddns = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Run the Porkbun DDNS updater. Stays on in restoreMode. Switch it off in any VM
        that is not meant to rewrite the real records.
      '';
    };
    apiBase = lib.mkOption {
      type = lib.types.str;
      default = "https://api.porkbun.com/api/json/v3";
      description = "Porkbun API base URL (a stub in the VM tests).";
    };
    interface = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Interface carrying the ::20 address. Null: the NIC with `optiplex.network.mac`.";
    };
  };

  config = lib.mkIf dcfg.enable {
    environment.systemPackages = [ddns]; # `ddns-porkbun --dry-run` by hand (as root: set the *_FILE variables)

    systemd.services.ddns-porkbun = {
      description = "Update A + AAAA of nnik.dev and *.nnik.dev at Porkbun";
      after = ["network-online.target"];
      wants = ["network-online.target"];
      environment =
        {PORKBUN_API_BASE = dcfg.apiBase;}
        // (
          if dcfg.interface != null
          then {DDNS_INTERFACE = dcfg.interface;}
          else {DDNS_MAC = lib.toLower cfg.network.mac;}
        );
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe ddns;
        TimeoutStartSec = "2min";
        DynamicUser = true;
        LoadCredential = [
          "porkbun_api_key:${cfg.edge.porkbun.apiKeyFile}"
          "porkbun_secret_api_key:${cfg.edge.porkbun.secretApiKeyFile}"
        ];
        CapabilityBoundingSet = "";
        NoNewPrivileges = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictAddressFamilies = ["AF_INET" "AF_INET6" "AF_NETLINK"];
        RestrictNamespaces = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        SystemCallArchitectures = "native";
        SystemCallFilter = ["@system-service" "~@privileged" "~@resources"];
      };
    };

    # Once at boot (after network-online) and then 5 minutes after every run.
    systemd.timers.ddns-porkbun = {
      wantedBy = ["timers.target"];
      timerConfig = {
        OnBootSec = "30s";
        OnUnitInactiveSec = "5min";
      };
    };
  };
}
