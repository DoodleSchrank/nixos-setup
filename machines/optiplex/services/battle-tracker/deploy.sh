# battle-tracker-deploy: build the head of `main` of the app repo and switch the profile to it.
# Prepended by the unit: set -euo pipefail and the settings below, all from the environment.
#   BT_SOURCE         flake URL of the repo without a ref
#   BT_PROFILE        the Nix profile (generations of { web, server, rev })
#   BT_FARM           farm.nix (see there for the rest of its environment)
#   BT_KEEP           generations to keep
#   BT_SERVICE        the sync service
#   BT_HEALTH_URL     the sync server's /health
#   BT_WEB_URL        the public URL of the web bundle; BT_WEB_RESOLVE pins it to loopback (curl --resolve)
#   BT_WEB_CACERT     optional CA file for BT_WEB_URL (the VM test's cert is from a test CA)
#   BT_FAILED_FILE    remembers the head that failed, so the hourly timer does not redeploy it
# Steps and failure behaviour are in the ticket "battle-tracker" (39), "Scope".

log() { echo "battle-tracker-deploy: $*"; }

probe() { # probe <url> [curl args]
  local url="$1"
  shift
  curl -fsS --max-time 10 -o /dev/null "$@" "$url"
}

healthy() { # healthy <attempts>: the sync server and the web bundle through Caddy, 2 s apart
  local n curl_web=(--resolve "$BT_WEB_RESOLVE")
  [ -z "${BT_WEB_CACERT:-}" ] || curl_web+=(--cacert "$BT_WEB_CACERT")
  for ((n = 0; n < $1; n++)); do
    if probe "$BT_HEALTH_URL" && probe "$BT_WEB_URL/" "${curl_web[@]}" && probe "$BT_WEB_URL/main.dart.js" "${curl_web[@]}"; then
      return 0
    fi
    sleep 2
  done
  log "health check failed: $BT_HEALTH_URL, $BT_WEB_URL/ and $BT_WEB_URL/main.dart.js (last error above)"
  return 1
}

live_rev() { cat "$BT_PROFILE/rev" 2>/dev/null || true; }

generation() { # number of the current generation (empty without a profile)
  local link
  link=$(readlink "$BT_PROFILE" 2>/dev/null) || return 0
  [[ $link =~ -([0-9]+)-link$ ]] && echo "${BASH_REMATCH[1]}"
  return 0
}

failed_before() { [ "$(cat "$BT_FAILED_FILE" 2>/dev/null || true)" = "$1" ]; }

# A push that lands while a build runs finds the unit busy (the path unit's start is absorbed), so look
# again after each deploy; a few rounds are plenty.
for _round in 1 2 3; do
  head=$(nix flake metadata --refresh --json "$BT_SOURCE?ref=main" | jq -r '.revision // empty')
  if [ -z "$head" ]; then
    log "cannot resolve main of $BT_SOURCE"
    exit 1
  fi
  if [ "$head" = "$(live_rev)" ]; then
    log "main is at $head, which is live"
    exit 0
  fi
  if failed_before "$head"; then
    log "main is at $head, which failed to deploy before; waiting for a new commit"
    exit 0
  fi

  log "building $head"
  if ! out=$(BT_REV=$head nix build --impure --no-link --print-out-paths --file "$BT_FARM"); then
    log "build of $head failed; the profile is untouched"
    echo "$head" >"$BT_FAILED_FILE"
    exit 1
  fi

  previous=$(generation)
  nix-env --profile "$BT_PROFILE" --set "$out"
  current=$(generation)
  log "switched to generation $current ($head)"
  systemctl restart "$BT_SERVICE"

  if ! healthy 30; then
    echo "$head" >"$BT_FAILED_FILE"
    if [ -n "$previous" ]; then
      log "rolling back to generation $previous"
      nix-env --profile "$BT_PROFILE" --switch-generation "$previous"
      nix-env --profile "$BT_PROFILE" --delete-generations "$current"
      systemctl restart "$BT_SERVICE"
      healthy 30 || log "still unhealthy after the rollback"
    fi
    exit 1
  fi

  nix-env --profile "$BT_PROFILE" --delete-generations "+$BT_KEEP"
  log "deployed $head"
done
