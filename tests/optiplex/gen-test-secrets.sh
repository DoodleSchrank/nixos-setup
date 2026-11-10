#!/usr/bin/env bash
# Regenerates secrets/test/optiplex/*.yaml: a dummy mirror of secrets/optiplex/*.yaml.
#
# TEST ONLY. The mirror holds made-up values and is encrypted to the committed, public
# test age key (secrets/test/age-key.txt, rule `test/optiplex/` in secrets/.sops.yaml).
# The VM tests point `optiplex.secretsDir` at it. Nothing here protects anything real.
#
# Only the key NAMES of the real files are read (they are plaintext in a sops file);
# no real value is decrypted, so this needs no private key.
#
# usage: tests/optiplex/gen-test-secrets.sh        (from anywhere; needs sops, ssh-keygen, openssl, python3)
#        tests/optiplex/gen-test-secrets.sh --check  (fail if the mirror lacks a file or key of the real side)
#
# Typed values come from the generator map in `gen_value` below (matched on the key name).
# A key that matches nothing gets "test-<key>". Add a case when a service ticket introduces a
# typed secret (PEM, signing key, YAML, ...), otherwise the service sees an invalid dummy.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
real="$root/secrets/optiplex"
mirror="$root/secrets/test/optiplex"
testpub="$(sed -n 's/^# public key: //p' "$root/secrets/test/age-key.txt")"
check=0
[ "${1:-}" = "--check" ] && check=1
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Top-level key names of a sops yaml file, in file order (everything before the `sops:` block).
key_names() {
  python3 -I - "$1" <<'PY'
import re, sys
for line in open(sys.argv[1]):
    if line.startswith("sops:"):
        break
    m = re.match(r"^([A-Za-z0-9_.-]+):", line)
    if m:
        print(m.group(1))
PY
}

# gen_value <file> <key>  -> prints the dummy value (may be multi-line)
gen_value() {
  local file="$1" key="$2"
  case "$key" in
    *password_hash)
      case "$file" in
        ntfy.yaml)
          # ntfy wants bcrypt: hash of the password "test" (made with `htpasswd -nbBC 10 x test`)
          echo '$2y$10$ztHQaYkIMXiwABM2EcOZvOL.jJBgQZmN4Q2U1kk.L/8BIi1N.X5Ri' ;;
        *)
          # hash of the password "test" (console login in VM tests)
          openssl passwd -6 -salt testsalt test ;;
      esac ;;
    publisher_token)
      # ntfy access token: "tk_" + 29 characters of [a-z0-9]
      printf 'tk_%s\n' "$(head -c 64 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 29)" ;;
    *ssh_host_ed25519_key|*host_ed25519_key)
      ssh-keygen -q -t ed25519 -N "" -C test-only -f "$tmp/k" && cat "$tmp/k" && rm -f "$tmp/k" "$tmp/k.pub" ;;
    *ssh_host_rsa_key|*host_rsa_key)
      ssh-keygen -q -t rsa -b 2048 -N "" -C test-only -f "$tmp/k" && cat "$tmp/k" && rm -f "$tmp/k" "$tmp/k.pub" ;;
    *ssh_host_ecdsa_key|*host_ecdsa_key)
      ssh-keygen -q -t ecdsa -b 256 -N "" -C test-only -f "$tmp/k" && cat "$tmp/k" && rm -f "$tmp/k" "$tmp/k.pub" ;;
    lfs_jwt_secret|oauth2_jwt_secret)
      # Gitea: base64url (no padding) of exactly 32 random bytes
      head -c 32 /dev/urandom | base64 -w0 | tr '+/' '-_' | tr -d '=' ; echo ;;
    jwt_private_pem)
      # Gitea's [oauth2] JWT_SIGNING_PRIVATE_KEY_FILE: a PKCS#8 RSA private key, nothing else in the file
      openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 2>/dev/null ;;
    rsa_key)
      # Vaultwarden's rsa_key.pem: a PKCS#1 RSA private key ("BEGIN RSA PRIVATE KEY")
      openssl genrsa -traditional 2048 2>/dev/null ;;
    secrets_yaml)
      # Home Assistant's secrets.yaml: a YAML mapping
      printf 'test_secret: test%s\n' "$(head -c 14 /dev/urandom | od -An -tx1 | tr -d ' \n')" ;;
    dav_htpasswd)
      # etesync-dav's htpaswd (Radicale "plain" encryption): one "user:password" line. The VM test
      # signs up the Etebase user `testuser` and logs in to DAV with this password.
      echo "testuser:testpassword1234" ;;
    *signing_key|*signing.key)
      # Synapse signing key: "<algorithm> <version> <unpadded base64 of 32 bytes>"
      printf 'ed25519 atest %s\n' "$(head -c 32 /dev/urandom | base64 -w0 | tr -d '=')" ;;
    registration_shared_secret|static_auth_secret|form_secret)
      # Synapse / coturn shared secrets: plain strings (the generic "*registration*" case below is for registrations)
      printf 'test%s\n' "$(head -c 14 /dev/urandom | od -An -tx1 | tr -d ' \n')" ;;
    api_id)
      # Telegram api_id: an integer
      echo 1234567 ;;
    registration)
      # appservice registration of a mautrix bridge, in the shape `--generate-registration` writes
      case "$file" in
        mautrix-whatsapp.yaml) bridge=whatsapp; port=29318 ;;
        mautrix-telegram.yaml) bridge=telegram; port=29317 ;;
        *) bridge=test-bridge; port=29399 ;;
      esac
      cat <<EOF
id: $bridge
url: http://localhost:$port
as_token: test-as-token-$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')
hs_token: test-hs-token-$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')
sender_localpart: test-sender-$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')
rate_limited: false
namespaces:
    users:
        - regex: ^@$bridge:nnik\.dev\$
          exclusive: true
        - regex: ^@${bridge}_.*:nnik\.dev\$
          exclusive: true
de.sorunome.msc2409.push_ephemeral: true
receive_ephemeral: true
EOF
      ;;
    *registration*|*registration_yaml)
      # appservice registration; the bridges fill the namespaces themselves, so a minimal valid file
      cat <<EOF
id: test-bridge
url: http://127.0.0.1:29318
as_token: test-as-token-$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')
hs_token: test-hs-token-$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')
sender_localpart: testbot
rate_limited: false
namespaces:
  users: []
  aliases: []
  rooms: []
EOF
      ;;
    *.pem|*_pem|*private_key_pem|*certificate*|*cert_key*)
      openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=test-only" -keyout "$tmp/k" -out "$tmp/c" 2>/dev/null
      cat "$tmp/k" "$tmp/c"; rm -f "$tmp/k" "$tmp/c" ;;
    *pickle_key|*secret_key|*_token|*api_key|*secret_api_key|*client_secret|*password|*passphrase|*key)
      # 32 hex chars: long enough for pickle keys and signing secrets, shell-safe
      printf 'test%s\n' "$(head -c 14 /dev/urandom | od -An -tx1 | tr -d ' \n')" ;;
    s3_endpoint) echo "s3.test.invalid" ;;
    s3_region) echo "test-region" ;;
    s3_bucket) echo "test-bucket" ;;
    *)
      echo "test-$key" ;;
  esac
}

# emit_yaml <file> <key...>: plain YAML with every value as a literal block (safe for any content)
emit_yaml() {
  local file="$1"; shift
  for key in "$@"; do
    echo "$key: |-"
    gen_value "$file" "$key" | sed 's/^/  /'
  done
}

mkdir -p "$mirror"
status=0
shopt -s nullglob
for f in "$real"/*.yaml; do
  name="$(basename "$f")"
  mapfile -t keys < <(key_names "$f")
  if [ "$check" = 1 ]; then
    [ -e "$mirror/$name" ] || { echo "missing: secrets/test/optiplex/$name"; status=1; continue; }
    for k in "${keys[@]}"; do
      grep -q "^$k:" "$mirror/$name" || { echo "missing key $k in secrets/test/optiplex/$name"; status=1; }
    done
    continue
  fi
  emit_yaml "$name" "${keys[@]}" > "$tmp/plain.yaml"
  # --filename-override picks the creation rule (test/optiplex/...); --age pins it to the test key anyway
  sops --encrypt --age "$testpub" --input-type yaml --output-type yaml \
    --filename-override "$mirror/$name" "$tmp/plain.yaml" > "$mirror/$name.new"
  mv "$mirror/$name.new" "$mirror/$name"
  echo "wrote secrets/test/optiplex/$name (${#keys[@]} keys)"
done

# Mirror files whose real counterpart is gone are stale.
for f in "$mirror"/*.yaml; do
  [ -e "$real/$(basename "$f")" ] || { echo "stale (no real file): secrets/test/optiplex/$(basename "$f")"; [ "$check" = 1 ] && status=1; }
done
exit "$status"
