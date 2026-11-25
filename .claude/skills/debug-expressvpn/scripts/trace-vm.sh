#!/usr/bin/env bash
# Boots a throwaway NixOS VM with the ExpressVPN daemon running under strace,
# optionally logs in and connects, and saves what the daemon did.
#
# Usage: trace-vm.sh [options] [-- <nix-build args>]
#
#   --online <code-file>   log in with this activation code file and connect
#                          (the VM then gets internet access; without this it
#                          only traces startup, offline)
#   --protocol <name>      protocol to connect with: lightwayudp, lightwaytcp,
#                          openvpnudp, openvpntcp or wireguard (default: auto)
#   --resolved             use systemd-resolved in the VM instead of resolvconf
#   --gui                  also start the GUI under strace and take a screenshot
#   --seconds <n>          how long to let things run before collecting (default 15)
#   --out <dir>            where to put the results (default: a new temp directory)
#
# By default it builds against <nixpkgs>, which is usually already cached.
# Pass nix-build arguments after "--" to change that.
#
# The results can contain server addresses and account identifiers. Keep them
# out of the repository.
set -euo pipefail

usage() {
  sed -n '2,/^set -/{/^set -/d;s/^# \{0,1\}//;p}' "$0" >&2
  exit 2
}

code_file=
protocol=
resolved=false
gui=
seconds=15
out=

while [ $# -gt 0 ]; do
  case "$1" in
    --online)
      code_file=$(realpath "$2")
      shift 2
      ;;
    --protocol)
      protocol=$2
      shift 2
      ;;
    --resolved)
      resolved=true
      shift
      ;;
    --gui)
      gui=1
      shift
      ;;
    --seconds)
      seconds=$2
      shift 2
      ;;
    --out)
      out=$(realpath -m "$2")
      shift 2
      ;;
    --)
      shift
      break
      ;;
    *) usage ;;
  esac
done

if [ -n "$code_file" ] && [ ! -s "$code_file" ]; then
  echo "activation code file '$code_file' is missing or empty" >&2
  exit 1
fi

skill=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
repo=$(cd "$skill/../../.." && pwd)
[ -n "$out" ] || out=$(mktemp -d "${TMPDIR:-/tmp}/expressvpn-trace.XXXXXX")
mkdir -p "$out"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

nix-build "$skill/assets/trace-vm.nix" -A driver -o "$work/driver" \
  --arg repo "$repo" --arg useResolved "$resolved" "$@" >/dev/null

# The driver runs outside the Nix sandbox, so the VM can reach the internet.
cd "$work"
status=0
EXPRESSVPN_ACTIVATION_CODE_FILE=$code_file \
  EXPRESSVPN_PROTOCOL=$protocol \
  EXPRESSVPN_TRACE_GUI=$gui \
  EXPRESSVPN_TRACE_SECONDS=$seconds \
  TMPDIR=$work NO_COLOR=1 \
  "$work/driver/bin/nixos-test-driver" -o "$out" >"$out/driver.log" 2>&1 || status=$?

if [ -d "$out/trace-out" ]; then
  mv "$out/trace-out"/* "$out/"
  rmdir "$out/trace-out"
fi

echo "results: $out"
ls "$out"
if [ "$status" -ne 0 ]; then
  echo "the test driver exited with status $status; see $out/driver.log" >&2
fi
exit "$status"
