# Entry point for setups that do not use flakes.
#
#   let expressvpn = import /path/to/expressvpn-nix { inherit pkgs; }; in ...
#
# `module` is the NixOS module; `package` is the app built against `pkgs`.
{
  pkgs ? import <nixpkgs> { config.allowUnfree = true; },
}:

{
  package = pkgs.callPackage ./pkgs/expressvpn/package.nix { };
  module = ./nixos/module.nix;
  tests.basic = pkgs.testers.runNixOSTest ./nixos/tests/basic.nix;
}
