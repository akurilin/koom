#!/usr/bin/env bash

set -euo pipefail

IDENTITY_NAME="${KOOM_CODESIGN_IDENTITY:-koom Local Dev}"
LOGIN_KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"
VALID_DAYS=3650
FORCE_RECREATE=false

usage() {
    cat >&2 <<EOF
Usage: ./scripts/setup-dev-codesign.sh [--force]

Creates a self-signed macOS code-signing identity for local koom development
and trusts it for the \`codeSign\` policy so repeated rebuilds keep a stable
Keychain access identity.

Options:
  --force    Recreate the identity even if a valid one already exists.
  --help     Show this help text.

Environment:
  KOOM_CODESIGN_IDENTITY
      Common Name for the self-signed identity.
      Default: koom Local Dev
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --force)
            FORCE_RECREATE=true
            shift
            ;;
        --help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage
            exit 1
            ;;
    esac
done

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Required command not found: $1" >&2
        exit 1
    fi
}

refresh_user_keychain_search_list() {
    local line found_login=false
    local keychains=()

    while IFS= read -r line; do
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line#\"}"
        line="${line%\"}"
        [[ -z "$line" ]] && continue
        keychains+=("$line")
        if [[ "$line" == "$LOGIN_KEYCHAIN" ]]; then
            found_login=true
        fi
    done < <(security list-keychains -d user)

    if [[ "$found_login" == false ]]; then
        keychains+=("$LOGIN_KEYCHAIN")
    fi

    security list-keychains -d user -s "${keychains[@]}" >/dev/null
}

valid_identity_exists() {
    security find-identity -v -p codesigning "$LOGIN_KEYCHAIN" |
        grep -F "\"$IDENTITY_NAME\"" >/dev/null
}

delete_existing_certificates() {
    while security find-certificate -a -c "$IDENTITY_NAME" "$LOGIN_KEYCHAIN" >/dev/null 2>&1; do
        security delete-certificate -c "$IDENTITY_NAME" "$LOGIN_KEYCHAIN" >/dev/null 2>&1 || break
    done
}

verify_codesign_works() {
    local temp_dir temp_binary
    temp_dir="$(mktemp -d)"
    temp_binary="$temp_dir/true"
    trap 'rm -rf "$temp_dir"' RETURN

    cp /usr/bin/true "$temp_binary"
    codesign --force --sign "$IDENTITY_NAME" "$temp_binary" >/dev/null
    codesign --verify --verbose=1 "$temp_binary" >/dev/null
}

require_command openssl
require_command certtool
require_command security
require_command codesign

if [[ ! -f "$LOGIN_KEYCHAIN" ]]; then
    echo "Login keychain not found at $LOGIN_KEYCHAIN" >&2
    exit 1
fi

refresh_user_keychain_search_list

if [[ "$FORCE_RECREATE" == false ]] && valid_identity_exists; then
    echo "Valid codesigning identity already present: $IDENTITY_NAME" >&2
    verify_codesign_works
    echo "$IDENTITY_NAME"
    exit 0
fi

temp_dir="$(mktemp -d)"
cleanup() {
    rm -rf "$temp_dir"
}
trap cleanup EXIT

delete_existing_certificates

cat >"$temp_dir/openssl.cnf" <<EOF
[ req ]
distinguished_name = dn
prompt = no

[ dn ]
CN = $IDENTITY_NAME

[ codesign ]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
subjectKeyIdentifier = hash
EOF

openssl genrsa -traditional -out "$temp_dir/key.rsa" 2048 >/dev/null 2>&1
openssl req \
    -new \
    -key "$temp_dir/key.rsa" \
    -out "$temp_dir/key.csr" \
    -config "$temp_dir/openssl.cnf" >/dev/null 2>&1
openssl x509 \
    -req \
    -days "$VALID_DAYS" \
    -in "$temp_dir/key.csr" \
    -signkey "$temp_dir/key.rsa" \
    -out "$temp_dir/key.crt" \
    -extfile "$temp_dir/openssl.cnf" \
    -extensions codesign >/dev/null 2>&1

certtool i "$temp_dir/key.crt" k="$LOGIN_KEYCHAIN" r="$temp_dir/key.rsa" >/dev/null
security add-trusted-cert \
    -r trustRoot \
    -p codeSign \
    -k "$LOGIN_KEYCHAIN" \
    "$temp_dir/key.crt" >/dev/null
refresh_user_keychain_search_list

if ! valid_identity_exists; then
    echo "Created certificate, but macOS does not consider it a valid codesigning identity yet." >&2
    exit 1
fi

verify_codesign_works
echo "Created and trusted local codesigning identity: $IDENTITY_NAME" >&2
echo "$IDENTITY_NAME"
