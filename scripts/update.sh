#!/usr/bin/env bash
# Points the package at a new ExpressVPN release: downloads the installer,
# checks its signature against the vendor key kept in this repository, and
# rewrites pkgs/expressvpn/source.json.
#
# Usage: scripts/update.sh [version]
#
# Without an argument it asks ExpressVPN's installers API (the one behind
# https://www.expressvpn.com/latest) for the current Linux release. Pass a
# version such as 14.3.1.15429 to pin a specific one.
#
# Environment:
#   FORCE=1  re-download and rewrite even if source.json is already current
#
# Needs curl, jq, gnupg and nix on PATH; `nix develop` provides them.
set -euo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source_json=$repo/pkgs/expressvpn/source.json
release_key=$repo/pkgs/expressvpn/release-key.asc

# "ExpressVPN Release <release@expressvpn.com>", as published at
# https://www.expressvpn.com/expressvpn_release_public_key_0xAFF2A1415F6A3A38.asc
key_fingerprint=1D0B09AD6C93FEE93FDDBD9DAFF2A1415F6A3A38

installers_api=https://main-kp-site-gateway-http.prodv2.pac.xvservice.net/api/v2/installers
download_base=https://www.expressvpn.works/clients/linux

fail() {
  echo "error: $*" >&2
  exit 1
}

# Lets a CI workflow read the result.
report() {
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "$1" >>"$GITHUB_OUTPUT"
  fi
}

current=$(jq -r .version "$source_json")

if [ $# -ge 1 ]; then
  version=$1
  url=$download_base/expressvpn-linux-universal-${version}_release.run
  published_sha256=
else
  info=$(curl -fsSL --max-time 60 "$installers_api" | jq '(.installers // .).linux_qt') ||
    fail "could not read $installers_api; pass the version as an argument instead"
  version=$(jq -r '.version | sub("_release$"; "")' <<<"$info")
  url=$(jq -r '.locations.default' <<<"$info")
  published_sha256=$(jq -r '.checksums.sha256 // empty' <<<"$info")
fi

[[ $version =~ ^[0-9]+(\.[0-9]+){3}$ ]] || fail "unexpected version format: '$version'"
[[ $url == https://*.run ]] || fail "unexpected download URL: '$url'"

if [ "$version" = "$current" ] && [ -z "${FORCE:-}" ]; then
  echo "already at $version"
  report "updated=false"
  exit 0
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
installer=$work/$(basename "$url")

echo "downloading $url"
curl -fL --max-time 1800 --progress-bar -o "$installer" "$url"
curl -fsSL --max-time 60 -o "$installer.asc" "$url.asc"

# Verify with a throwaway keyring that holds only the vendor key from the repo.
export GNUPGHOME=$work/gnupg
mkdir -m 700 "$GNUPGHOME"
gpg --quiet --import "$release_key"
signature_status=$(gpg --status-fd 1 --verify "$installer.asc" "$installer" 2>/dev/null) || true
# VALIDSIG's last field is the fingerprint of the primary key that signed.
if ! awk -v fpr="$key_fingerprint" '$2 == "VALIDSIG" && $NF == fpr { ok = 1 } END { exit !ok }' \
  <<<"$signature_status"; then
  fail "the installer is not signed by the ExpressVPN release key ($key_fingerprint)"
fi
echo "signature ok"

sha256=$(sha256sum "$installer" | cut -d' ' -f1)
if [ -n "$published_sha256" ] && [ "$sha256" != "$published_sha256" ]; then
  fail "checksum mismatch: downloaded $sha256, API lists $published_sha256"
fi
hash=$(nix-hash --to-sri --type sha256 "$sha256")

# Put the installer in the Nix store so the next build does not fetch it again.
nix-store --add-fixed sha256 "$installer" >/dev/null

jq -n --arg version "$version" --arg url "$url" --arg hash "$hash" \
  '{ version: $version, url: $url, hash: $hash }' >"$source_json"

echo "updated $current -> $version"
echo "next: nix flake check, then scripts/e2e-test.sh (see docs/updating.md)"
report "updated=true"
report "version=$version"
report "previous=$current"
