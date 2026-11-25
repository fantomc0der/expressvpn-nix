# expressvpn-nix

The official ExpressVPN app for Linux (GUI, `expressvpnctl` and the daemon), packaged for NixOS.

nixpkgs only carries the legacy 3.x command-line client. This repository packages the current app, which ExpressVPN ships as a self-extracting installer for mainstream distros, and adds the NixOS module it needs to run.

This is an unofficial packaging effort and is not affiliated with ExpressVPN. The app itself is proprietary: Nix downloads it from ExpressVPN's servers at build time, and you need an ExpressVPN subscription to use it.

## Status

| | |
|---|---|
| App version | 14.3.0.1 |
| Platforms | `x86_64-linux` tested. `aarch64-linux` is packaged but untested |
| NixOS | 26.05 and nixos-unstable |

What has been verified, in NixOS test VMs against the real ExpressVPN service:

- **Protocols:** Lightway UDP, Lightway TCP, OpenVPN UDP, OpenVPN TCP and WireGuard each connect, carry traffic and DNS through the tunnel, and restore the network on disconnect.
- **DNS setups:** NixOS's default resolvconf and systemd-resolved.
- **GUI:** starts, signs in, connects and disconnects under X11.
- **CLI:** `expressvpnctl` login, connect, settings and status.

It has also been installed on one real machine (NixOS 26.05, Hyprland with XWayland): the GUI signed in with an activation code and connected over Lightway UDP, with traffic and DNS going through the tunnel.

Not verified: the browser extension helper, split tunneling in use, and the `aarch64-linux` build. See [Known limitations](#known-limitations).

## Quick start

With flakes:

```nix
{
  inputs.expressvpn.url = "github:fantomc0der/expressvpn-nix";

  outputs = { nixpkgs, expressvpn, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      modules = [
        expressvpn.nixosModules.default
        {
          nixpkgs.config.allowUnfree = true;
          programs.expressvpn.enable = true;
        }
      ];
    };
  };
}
```

Without flakes, in `configuration.nix`:

```nix
{
  imports = [ /path/to/expressvpn-nix/nixos/module.nix ];

  nixpkgs.config.allowUnfree = true;
  programs.expressvpn.enable = true;
}
```

Rebuild, then sign in. Either open **ExpressVPN** from your launcher, or use the command line:

```bash
expressvpnctl login /path/to/file-with-activation-code
expressvpnctl connect
expressvpnctl status
```

[docs/installation.md](docs/installation.md) has the details, including how to allow only this one unfree package and how to remove everything again.

## Options

| Option | Default | Meaning |
|---|---|---|
| `programs.expressvpn.enable` | `false` | Install the app and run its daemon |
| `programs.expressvpn.package` | this repository's package | The ExpressVPN package to use |
| `programs.expressvpn.checkForUpdates` | `false` | Let the app tell you about new versions. In-app installation is always off, because it cannot work on NixOS |

## What the module changes on your system

- **Runs a root daemon,** `expressvpn-service.service`, which manages the tunnel, firewall rules, routing and DNS.
- **Creates `/opt/expressvpn`.** The app's install prefix is compiled into its binaries. The directory holds links into the Nix store plus the app's state in `etc` and `var`.
- **Relaxes the firewall's reverse-path check to `"loose"`.** With the strict check, NixOS drops the VPN server's replies. Set `networking.firewall.checkReversePath` yourself to override, but the VPN will not pass traffic under `true`.
- **Adds the `expressvpn` and `expressvpnhnsd` groups,** which the daemon uses for its helper processes and firewall rules.
- **Tells NetworkManager to leave `wgexpressvpn*` interfaces alone.**
- **Registers the browser extension helper** for Firefox and Chromium-based browsers.

The daemon itself also writes its routing table names to `/etc/iproute2/rt_tables`.

## Known limitations

- **X11 only.** The app forces the X11 backend, so a Wayland session needs XWayland.
- **In-app update and uninstall do nothing.** Update through this repository and uninstall by removing the module.
- **Stopping the daemon while offline can take 90 seconds.** It waits on a network request during shutdown until systemd kills it. Online, it stops in a few seconds.
- **The browser extension helper is installed but untested.**

More in [docs/troubleshooting.md](docs/troubleshooting.md).

## Documentation

- [docs/installation.md](docs/installation.md): installing, signing in, removing
- [docs/architecture.md](docs/architecture.md): how the app works and what was needed to make it run on NixOS
- [docs/testing.md](docs/testing.md): the checks, the VM test and the end-to-end test
- [docs/updating.md](docs/updating.md): moving to a new ExpressVPN release
- [docs/troubleshooting.md](docs/troubleshooting.md): common problems and where the logs are

## Development

```bash
nix develop          # shell with the tools the scripts need
nix fmt              # format
nix flake check      # lint, build the package, run the VM test
scripts/update.sh    # move to the latest ExpressVPN release
scripts/e2e-test.sh <activation-code-file>   # test against the real service
```

Changes go to `main` through pull requests, which CI checks. See [docs/testing.md](docs/testing.md#ci-and-pull-requests).

## License

The packaging code in this repository is under the [MIT license](LICENSE). ExpressVPN is proprietary software under [ExpressVPN's terms of service](https://www.expressvpn.com/tos) and is not distributed here.
