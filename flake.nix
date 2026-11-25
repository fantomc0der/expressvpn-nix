{
  description = "ExpressVPN desktop app (GUI, CLI and daemon) for NixOS";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      inherit (nixpkgs) lib;

      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      # ExpressVPN is proprietary, so nixpkgs has to be told it may be built.
      pkgsFor =
        system:
        import nixpkgs {
          inherit system;
          config.allowUnfreePredicate = pkg: lib.getName pkg == "expressvpn";
        };

      forAllSystems = f: lib.genAttrs systems (system: f (pkgsFor system));
    in
    {
      packages = forAllSystems (pkgs: rec {
        expressvpn = pkgs.callPackage ./pkgs/expressvpn/package.nix { };
        default = expressvpn;
      });

      nixosModules = rec {
        expressvpn = ./nixos/module.nix;
        default = expressvpn;
      };

      checks = forAllSystems (
        pkgs:
        {
          package = self.packages.${pkgs.stdenv.hostPlatform.system}.expressvpn;

          lint =
            pkgs.runCommand "expressvpn-nix-lint"
              {
                nativeBuildInputs = [
                  pkgs.deadnix
                  pkgs.nixfmt
                  pkgs.shellcheck
                  pkgs.statix
                ];
              }
              ''
                cd ${self}
                find . -name '*.nix' -exec nixfmt --check {} +
                statix check .
                deadnix --fail .
                shellcheck scripts/*.sh
                touch $out
              '';
        }
        # The VM test needs KVM, which CI only has on x86_64.
        // lib.optionalAttrs pkgs.stdenv.hostPlatform.isx86_64 {
          basic = pkgs.testers.runNixOSTest ./nixos/tests/basic.nix;
        }
      );

      formatter = forAllSystems (pkgs: pkgs.nixfmt-tree);

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShellNoCC {
          packages = [
            pkgs.curl
            pkgs.deadnix
            pkgs.gnupg
            pkgs.jq
            pkgs.nixfmt-tree
            pkgs.shellcheck
            pkgs.statix
          ];
        };
      });
    };
}
