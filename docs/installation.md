# Installation

## Requirements

- NixOS on `x86_64-linux`. (`aarch64-linux` is packaged but untested.)
- An ExpressVPN subscription.
- A desktop session with X11 or XWayland for the GUI. The command-line tool works without one.

## Allowing the unfree package

ExpressVPN is proprietary, so nixpkgs refuses to build it until you allow it. Either allow all unfree packages:

```nix
nixpkgs.config.allowUnfree = true;
```

or only this one:

```nix
nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [ "expressvpn" ];
```

## With flakes

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    expressvpn.url = "github:fantomc0der/expressvpn-nix";
  };

  outputs = { nixpkgs, expressvpn, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./configuration.nix
        expressvpn.nixosModules.default
        { programs.expressvpn.enable = true; }
      ];
    };
  };
}
```

The module builds the app against your system's `pkgs`, so it follows your nixpkgs and your unfree settings. The repository's own nixpkgs pin is only used for its checks and for `nix build`.

## Without flakes

Clone the repository somewhere the system build can read, then import the module by path:

```nix
# /etc/nixos/configuration.nix
{
  imports = [
    ./hardware-configuration.nix
    /path/to/expressvpn-nix/nixos/module.nix
  ];

  programs.expressvpn.enable = true;
}
```

A path import follows whatever is checked out there. To pin a commit instead:

```nix
imports = [
  "${builtins.fetchGit {
    url = "/path/to/expressvpn-nix";
    rev = "<commit>";
  }}/nixos/module.nix"
];
```

## First run

Rebuild (`sudo nixos-rebuild switch`). The daemon starts on its own:

```bash
systemctl status expressvpn-service
expressvpnctl status          # "Not logged in." until you sign in
```

### Sign in from the GUI

Open **ExpressVPN** from your launcher, or run `expressvpn-client`. Choose **Sign In**, then sign in with an email link, your password or an activation code.

### Sign in from the command line

Put your activation code (or your email and password on two lines) in a file that only you can read, and pass the file:

```bash
expressvpnctl login ~/expressvpn-activation-code
```

The command line can only connect while the GUI is running, unless you turn on background mode:

```bash
expressvpnctl background enable
expressvpnctl connect            # Smart Location
expressvpnctl connect "germany-frankfurt-1"   # see: expressvpnctl get regions
expressvpnctl disconnect
```

`expressvpnctl --help` lists everything else, including protocol selection, Network Lock and split tunneling.

## Starting the GUI at login

The app turns on **Profile > Launch ExpressVPN on Startup** by default. It writes `~/.config/autostart/expressvpn-client.desktop`, a standard XDG autostart entry.

Desktop environments such as GNOME and KDE run those entries, so there the app starts at login with nothing more to do.

Bare compositors such as Hyprland and Sway do not run them, unless you use an autostart tool (`dex -a`, or systemd's XDG autostart generator). There, start the app from the compositor's own configuration.

### Hyprland

With a Lua configuration:

```lua
hl.on("hyprland.start", function()
    local entry = io.open(os.getenv("HOME") .. "/.config/autostart/expressvpn-client.desktop")
    if entry then
        entry:close()
        hl.exec_cmd("expressvpn-client")
    end
end)
```

With a `hyprland.conf`:

```
exec-once = test -f ~/.config/autostart/expressvpn-client.desktop && expressvpn-client
```

Both start the app only while the autostart entry exists. The app creates the entry when **Launch ExpressVPN on Startup** is on and deletes it when the setting is off, so the setting in the app keeps working. To start the app regardless of the setting, run `expressvpn-client` unconditionally.

The Lua form is the one in use on the machine this package was first installed on. The `hyprland.conf` form has not been run.

### Changing the setting from a terminal

```bash
expressvpn-client --disable-launch-on-login   # removes the autostart entry
expressvpn-client --enable-launch-on-login    # writes it again
```

These work whether or not the app is already running.

## Updating

Update the repository (or the flake input) and rebuild. The daemon restarts into the new version. See [updating.md](updating.md) for moving the package itself to a new ExpressVPN release.

## Removing

1. Sign out: `expressvpnctl logout`.
2. Remove `programs.expressvpn.enable` (and the import) and rebuild. That stops the daemon and removes the package, the groups and the firewall setting.
3. Delete the state NixOS does not manage:

```bash
sudo rm -rf /opt/expressvpn
sudo rm -f /etc/iproute2/rt_tables     # only if nothing else on your system added entries to it
rm -rf ~/.config/expressvpn ~/.config/autostart/expressvpn-client.desktop
```

`/etc/iproute2/rt_tables` is written by the daemon and holds its four routing table names (`evpnrt`, `evpnOnlyrt`, `evpnWgrt`, `evpnFwdrt`). Check its contents before deleting it.
