# Entry point for setups that do not use flakes.
#
#   let expressvpn = import /path/to/expressvpn-nix { inherit pkgs; }; in ...
#
# Without an argument it builds against the nixpkgs revision pinned in
# flake.lock, so flake and non-flake builds give the same result.
let
  lock = builtins.fromJSON (builtins.readFile ./flake.lock);
  pinned = lock.nodes.nixpkgs.locked;
  nixpkgs = fetchTarball {
    url = "https://github.com/${pinned.owner}/${pinned.repo}/archive/${pinned.rev}.tar.gz";
    sha256 = pinned.narHash;
  };
in
{
  pkgs ? import nixpkgs {
    config.allowUnfreePredicate = pkg: (pkg.pname or "") == "expressvpn";
  },
}:

let
  test = pkgs.testers.runNixOSTest;
in
{
  # The app, built against `pkgs`.
  package = pkgs.callPackage ./pkgs/expressvpn/package.nix { };

  # The NixOS module, for `imports`.
  module = ./nixos/module.nix;

  tests = {
    basic = test ./nixos/tests/basic.nix;

    # These need internet access and an account; see scripts/e2e-test.sh.
    e2e = {
      resolvconf = test (import ./nixos/tests/e2e.nix { useResolved = false; });
      resolved = test (import ./nixos/tests/e2e.nix { useResolved = true; });
    };
  };
}
