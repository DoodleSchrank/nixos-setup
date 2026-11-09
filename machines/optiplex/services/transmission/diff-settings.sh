#!/usr/bin/env bash
# Pre-Cutover check: which settings of the live Arch daemon would the NixOS config silently drop?
#
#   machines/optiplex/services/transmission/diff-settings.sh <live settings.json> [flake dir]
#
# Prints every key of the live settings.json whose value differs from transmission's own default
# (so somebody set it) AND from what the NixOS config generates. Each line is either deliberate
# (umask 022 -> 002, rpc-whitelist-enabled, rpc-password: no auth) or a setting that still has
# to be carried into `services.transmission.settings` in transmission.nix. Empty output after
# the known ones = nothing is lost.
#
# Transmission 4.1 names keys with underscores and reads the dashed ones too, and writes
# `encryption` as a word: keys and that value are normalised before comparing.
# Needs nix and jq. For tests: PKG (a transmission store path) and GEN (a settings JSON file)
# replace the `nix build` / `nix eval`.
set -euo pipefail

live=${1:?usage: diff-settings.sh <live settings.json> [flake dir]}
flake=${2:-.}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

if [ -z "${PKG:-}" ]; then
  PKG=$(nix build --no-link --print-out-paths "$flake#nixosConfigurations.optiplex.pkgs.transmission_4^out")
fi
if [ -z "${GEN:-}" ]; then
  nix eval --json "$flake#nixosConfigurations.optiplex.config.services.transmission.settings" >"$tmp/gen.json"
  GEN=$tmp/gen.json
fi

"$PKG/bin/transmission-daemon" -g "$tmp/cfg" --dump-settings >"$tmp/default.json"

jq -n \
  --slurpfile live "$live" --slurpfile def "$tmp/default.json" --slurpfile gen "$GEN" '
  def norm: with_entries(.key |= gsub("-"; "_"))
    | if has("encryption") and (.encryption | type) == "number"
      then .encryption |= ({"0": "tolerated", "1": "preferred", "2": "required"}[tostring])
      else . end;
  ($live[0] | norm) as $l | ($def[0] | norm) as $d | ($gen[0] | norm) as $g
  | $l | del(.rpc_username)
  | to_entries
  | map(select(.key != "rpc_password"))   # the hash is never printed
  | map(select(.value != $d[.key] and .value != $g[.key]))
  | map({key, live: .value, default: $d[.key], nixos: $g[.key]})
  ' | jq -c '.[]'
