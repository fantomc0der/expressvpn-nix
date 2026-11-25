# Troubleshooting

## Where things are

| What | Where |
|---|---|
| Daemon service | `systemctl status expressvpn-service` |
| Daemon journal | `journalctl -u expressvpn-service` |
| Daemon log (after `expressvpnctl set debuglogging true`) | `/opt/expressvpn/var/daemon.log` |
| Daemon settings and account data | `/opt/expressvpn/etc/` |
| GUI settings | `~/.config/expressvpn/clientsettings.json` |
| Autostart entry | `~/.config/autostart/expressvpn-client.desktop` |
| Routing table names | `/etc/iproute2/rt_tables` |

## The build refuses: "has an unfree license"

Allow the package. See [installation.md](installation.md#allowing-the-unfree-package).

## `expressvpnctl` prints "Timed out"

The daemon is not answering.

- **Just started:** it takes a few seconds to build its firewall rules before it opens its socket. Try again.
- **Not running:** check `systemctl status expressvpn-service` and the journal.
- **`/opt/expressvpn/var/daemon.sock` is missing:** the daemon could not write its state directory. Check that `/opt/expressvpn/etc` and `/opt/expressvpn/var` exist and belong to root.

## The GUI says it cannot reach the service

Same causes as above. The GUI reconnects on its own once the daemon is back.

## Connected, but nothing loads

1. Check that the reverse-path filter is in loose mode:

   ```bash
   nixos-option networking.firewall.checkReversePath     # expect "loose"
   ```

   If your configuration sets it to `true`, the VPN server's replies are dropped. See the firewall section of [architecture.md](architecture.md).

2. Check DNS: `cat /etc/resolv.conf`, or `resolvectl dns` with systemd-resolved. While connected, the VPN's DNS server should be listed.

3. Try another protocol: `expressvpnctl set protocol lightwaytcp`, then reconnect.

## DNS stops working some time after connecting

Without systemd-resolved, the daemon overwrites `/etc/resolv.conf` while connected, and NetworkManager or resolvconf can write it back when the network changes. The daemon blocks other DNS servers while connected, so lookups fail instead of leaking.

Reconnecting fixes it. To avoid it altogether, use systemd-resolved, where the VPN's DNS server is attached to the tunnel link and nothing is overwritten:

```nix
services.resolved.enable = true;
```

## No DNS after a crash or power loss

If the machine went down while connected (and you do not use systemd-resolved), `/etc/resolv.conf` may still hold the VPN's DNS server. The daemon keeps the original in `/opt/expressvpn/var/expressvpn.resolv.conf` while connected. Put it back:

```bash
sudo cp /opt/expressvpn/var/expressvpn.resolv.conf /etc/resolv.conf
```

or restart NetworkManager, which regenerates the file.

## Stopping the daemon or shutting down takes 90 seconds

When the machine is offline, the daemon finishes its cleanup (firewall rules and DNS are restored within seconds) but then waits on a network request and never exits. systemd kills it after its default 90 second timeout. Nothing is left behind. Online, the daemon stops in a few seconds.

## The GUI does not start at login

The app writes a standard XDG autostart entry, which bare compositors such as Hyprland and Sway do not run. Add a line to the compositor's configuration instead; [installation.md](installation.md#starting-the-gui-at-login) has the lines for Hyprland.

If you have added one and the app still does not start, check that the entry exists, because the examples start the app only while it does:

```bash
ls ~/.config/autostart/expressvpn-client.desktop
expressvpn-client --enable-launch-on-login     # writes it if it is missing
```

## The GUI window is blank or does not appear on Wayland

The app uses X11 and needs XWayland. On Hyprland that is `programs.hyprland.xwayland.enable = true` (the default). If the window appears but stays blank, start the app with `expressvpn-client --safe-mode` to use software rendering.

## "Enable Auto-update" turns itself off

That is the module. The app's updater cannot work on NixOS, so the setting is switched off every time the daemon starts. Update through this repository instead; see [updating.md](updating.md).

## "Uninstall ExpressVPN" in the app does nothing

The vendor's uninstaller is not included. Remove the module from your configuration; see [installation.md](installation.md#removing).

## Split tunneling

The daemon reports whether it can do split tunneling:

```bash
expressvpnctl --unstable dump daemon-state | jq .splitTunnelSupportErrors
```

An empty list means the kernel support it needs (the `net_cls` cgroup controller) is there. Rules are set per program path, and on NixOS a program's real path is in `/nix/store` and changes with every update of that program, so rules need re-adding after updates. Split tunneling in use has not been tested with this packaging.

## Both `programs.expressvpn` and `services.expressvpn` are enabled

`services.expressvpn` is nixpkgs' module for the old 3.x client. The two daemons would fight over the firewall and DNS, so the build stops with an assertion. Enable only one.

## Collecting details for a bug report

```bash
expressvpnctl set debuglogging true
# reproduce the problem
expressvpnctl status
journalctl -u expressvpn-service -b --no-pager | tail -n 100
sudo tail -n 200 /opt/expressvpn/var/daemon.log
```

The daemon log can contain server addresses and account identifiers. Read it before posting it anywhere.
