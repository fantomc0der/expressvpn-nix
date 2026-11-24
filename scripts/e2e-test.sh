#!/usr/bin/env bash
# Runs the end-to-end test: a throwaway NixOS VM logs in to ExpressVPN,
# connects over each protocol, checks the tunnel and logs out again.
#
# The VM reaches the internet through QEMU's user-mode networking, so nothing
# on the host changes and no root access is needed (only /dev/kvm).
#
# Usage: scripts/e2e-test.sh <activation-code-file> [resolvconf|resolved] [-- <nix-build args>]
#
# The second argument picks the DNS setup inside the VM (default: resolvconf).
# Anything after "--" goes to nix-build, for example to test against the
# system's nixpkgs instead of the pinned one:
#
#   scripts/e2e-test.sh code.txt resolved -- \
#     --arg pkgs 'import <nixpkgs> { config.allowUnfree = true; }'
#
# Environment:
#   EXPRESSVPN_PROTOCOLS  space-separated protocols to test (default: all)
set -euo pipefail

usage() {
  sed -n '2,/^set -/{/^set -/d;s/^# \{0,1\}//;p}' "$0" >&2
  exit 2
}

[ $# -ge 1 ] || usage
code_file=$(realpath "$1")
shift

variant=resolvconf
if [ $# -gt 0 ] && [ "$1" != "--" ]; then
  variant=$1
  shift
fi
if [ "${1:-}" = "--" ]; then
  shift
fi

case "$variant" in
  resolvconf | resolved) ;;
  *)
    echo "unknown variant '$variant': expected resolvconf or resolved" >&2
    exit 2
    ;;
esac

if [ ! -s "$code_file" ]; then
  echo "activation code file '$code_file' is missing or empty" >&2
  exit 1
fi

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

nix-build "$repo" -A "tests.e2e.$variant.driver" -o "$work/driver" "$@"

# The driver keeps the VM's disk and the shared directory under TMPDIR.
cd "$work"
EXPRESSVPN_ACTIVATION_CODE_FILE=$code_file TMPDIR=$work "$work/driver/bin/nixos-test-driver"
