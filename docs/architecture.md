# Architecture

How the ExpressVPN app is put together, and what this repository does to make it run on NixOS. Read this before changing the package or the module: most lines in them exist because of something recorded here.

## The app

ExpressVPN ships one installer for all distros, `expressvpn-linux-universal-<version>_release.run`. It is a Makeself archive (a shell script followed by a gzipped tarball) with one payload per architecture:

```
x64/ or arm64/
  package.txt          version and build name
  install.sh           the installer
  installfiles/        service units, desktop entry, icon, helper scripts
  expressvpnfiles/     the app itself
    bin/               daemon, GUI, CLI and VPN helper binaries
    lib/               bundled Qt 6, OpenSSL, xcb and the app's own libraries
    plugins/  qml/     bundled Qt plugins and QML modules
    share/             license, browser helper manifests, translations
```

The app is built from the same code base as Private Internet Access (both belong to Kape), which shows in library names such as `kapps_core` and in its behaviour.

| Program | Role |
|---|---|
| `expressvpn-daemon` | Runs as root. Owns the tunnel, firewall rules, routing and DNS. Listens on `/opt/expressvpn/var/daemon.sock` |
| `expressvpn-client` | The Qt GUI. Talks to the daemon over that socket |
| `expressvpnctl` | The command-line client, over the same socket |
| `expressvpn-lightway`, `expressvpn-lightway-rs`, `expressvpn-openvpn`, `expressvpn-amneziawg-go` | One helper per VPN protocol, started by the daemon |
| `expressvpn-unbound`, `expressvpn-ss-local`, `browser_helper`, `expressvpn-support-tool`, `expressvpn-mcp` | Local resolver, Shadowsocks proxy, browser extension bridge, diagnostics UI, MCP server |

### Where it expects to live

- **`/opt/expressvpn` is compiled in.** The daemon keeps settings in `/opt/expressvpn/etc` and logs, the socket and scratch files in `/opt/expressvpn/var`. `qt.conf` and the support tool launcher refer to `/opt/expressvpn/{bin,lib,plugins,qml}`.
- **Its own programs are found relative to the running binary,** not through `/opt`. The daemon started from the Nix store runs its helpers from the Nix store.
- **System tools are found through `/bin/bash` and PATH.** The daemon runs nearly everything (`iptables`, `ip`, `mount`, `realpath`, `awk`, ...) as `/bin/bash -c "<command>"`. Some commands run with the daemon's PATH, others with PATH fixed to `/usr/bin:/bin:/usr/local/bin:/usr/sbin:/sbin`.

### What the vendor installer does

`install.sh` is the specification the NixOS module replaces. It:

1. installs distro packages (`iptables`, `iproute2`, `psmisc`, `libnl`, `libxkbcommon`, ...);
2. creates the `expressvpn` and `expressvpnhnsd` groups;
3. copies the app to `/opt/expressvpn` and gives `expressvpn-unbound` the `cap_net_bind_service` capability;
4. installs the icon, the desktop entry and a `/usr/local/bin/expressvpnctl` link;
5. tells NetworkManager not to manage `wgexpressvpn*` interfaces;
6. installs and starts `expressvpn-service.service`;
7. writes browser native-messaging manifests into the user's home.

## The package

`pkgs/expressvpn/package.nix` turns the installer into a store path that keeps the vendor layout under `$out/opt/expressvpn`.

- **Source:** `source.json` holds the version, URL and hash, so the update script can rewrite it without touching Nix code.
- **Unpacking:** reads the payload offset from the Makeself header and extracts the tarball directly. The vendor's header script is never run.
- **Libraries:** `autoPatchelfHook` points every binary at the bundled libraries and at nixpkgs for the rest (glibc, libstdc++, fontconfig, dbus, libglvnd, wayland, ...). `appendRunpaths` covers libraries opened by name at runtime: `libnl` by the daemon, the bundled OpenSSL by Qt's TLS plugin.
- **Unused Qt plugins:** the vendor ships plugins for Qt modules it does not bundle (virtual keyboard, eglfs, test helpers). Their missing libraries are ignored, as they would be on any other distro.
- **Scripts:** `patchShebangs` rewrites `#!/bin/bash`. The updater and uninstaller scripts are left out.

### The up/down script's PATH

OpenVPN runs `openvpn-updown.sh` with an empty environment, and the script calls `tr` before it sets PATH from its arguments. On other distros bash falls back to a built-in default PATH. Bash from nixpkgs is built without one, so the script failed with "command not found", which OpenVPN reports as "could not execute external program". The package inserts a fallback `PATH` line at the top of the script.

### The GUI's hardcoded paths

The GUI refers to a few absolute paths that do not exist on NixOS:

| Path | Used for |
|---|---|
| `/usr/share/applications/expressvpn.desktop` | Copied to `~/.config/autostart` for "Launch on Startup" |
| `/usr/share/pixmaps/expressvpn.png` | Window and notification icon |
| `/usr/bin/xrdb`, `/usr/bin/gsettings` | Reading the display scale |
| `/usr/bin/pkexec` with `/bin/systemctl` | The "restart the service" action |
| `/usr/bin/xdg-open`, `/bin/bash` | Opening links and running commands |

`$out/bin/expressvpn-client` is a wrapper that preloads nixpkgs' `libredirect` with a `NIX_REDIRECTS` list mapping each of these to a store path. A GUI process cannot get a private filesystem view without a sandbox, and a sandbox would also wrap everything the GUI launches, so redirecting the handful of paths is the lighter option.

The tools among them are small shim scripts rather than the real binaries. A shim removes `libredirect` from `LD_PRELOAD` and unsets `NIX_REDIRECTS` before running the real tool, so that a browser opened from the app does not inherit them. The same `xdg-open` shim is put first on the GUI's PATH, because the app normally finds `xdg-open` there.

The desktop entry launches `expressvpn-client` by name instead of by store path. The app copies that file into `~/.config/autostart`, where a store path would go stale at the next update.

## The module

`nixos/module.nix` does what `install.sh` does, declaratively.

### `/opt/expressvpn`

`systemd-tmpfiles` creates:

```
/opt/expressvpn/
  bin lib plugins qml share   -> links into the package
  etc/                           settings, account data, cached server list
  var/                           daemon.sock, daemon.log, DNS backup, generated VPN configs
```

The links are refreshed on every activation. `etc` and `var` are plain directories that survive updates.

### The daemon's filesystem view

The service runs with a private mount namespace in which `/bin` and `/usr/bin` are replaced by one directory of tools (`daemonTools` in the module): bash, coreutils, findutils, gawk, grep, sed, iproute2, iptables, kmod, procps, psmisc, util-linux, e2fsprogs, which, systemd's tools and resolvconf when the system uses it. That satisfies `/bin/bash`, the fixed FHS PATH and `/usr/bin/resolvectl` in the up/down script, without touching the host.

Everything else is the host's filesystem. Mounts the daemon makes (the `net_cls` cgroup for split tunneling, at `/opt/expressvpn/etc/cgroup/net_cls`) stay inside its namespace.

### The daemon's PATH

The service sets `PATH=/usr/bin:/bin` instead of the usual NixOS service PATH.

The daemon passes its PATH to `openvpn-updown.sh` on the command line, split into `--path` chunks. OpenVPN keeps only the first 16 words of a script command. The normal NixOS service PATH is several hundred characters of store paths, which became eight chunks and pushed the script's `--dns` argument and its `--` terminator off the end. The script then treated OpenVPN's own arguments as options and exited with an error. With the two-directory PATH the command is six words long.

### Firewall

`networking.firewall.checkReversePath` defaults to `"loose"` when the module is enabled.

The daemon marks its own packets and uses policy routing: unmarked traffic follows a table whose default route is the tunnel. Replies from the VPN server arrive unmarked on the physical interface. NixOS's strict reverse-path filter looks up the route back to the server, gets the tunnel, and drops the packet. The symptom is a connection that reports "Connected" but passes no traffic, with the drop counter of the `nixos-fw-rpfilter` chain climbing. Loose mode only requires that some route to the source exists.

### DNS

The daemon decides how to set DNS by looking at `/etc/resolv.conf`:

| System | What the daemon does |
|---|---|
| systemd-resolved (`resolv.conf` resolves to a path containing `systemd`) | `resolvectl` sets the VPN's DNS server on the tunnel link. Nothing is overwritten |
| Debian-style resolvconf (`resolv.conf` is a link to `/run/resolvconf/resolv.conf`) | `resolvconf -a` |
| Anything else, including NixOS's default openresolv | Saves `/etc/resolv.conf` to `/opt/expressvpn/var/expressvpn.resolv.conf`, overwrites it with the VPN's DNS server, and restores it on disconnect |

Both NixOS cases are covered by the end-to-end test. The overwrite path is the same one the vendor uses on Arch. systemd-resolved is the tidier of the two, because the VPN's DNS server is attached to the tunnel link rather than written over a file that NetworkManager also manages.

### Updates

The app's updater downloads the installer and runs it in a terminal, which cannot work on NixOS. A small oneshot unit, `expressvpn-settings.service`, runs after each daemon start and applies two settings through `expressvpnctl --unstable applysettings`: an empty update channel (unless `checkForUpdates` is set) and `enableAutoUpdate = false`. It is a separate unit so that the daemon's own startup is not held up while the settings are applied.

### The rest

- **Groups:** `expressvpn` and `expressvpnhnsd`.
- **Kernel module:** `tun` is loaded at boot.
- **NetworkManager:** `wgexpressvpn*` interfaces are unmanaged.
- **Browser helper:** manifests under `/etc/chromium` and `/etc/opt/chrome`, and through `programs.firefox.nativeMessagingHosts`.
- **Legacy client:** an assertion stops the module being enabled together with nixpkgs' `services.expressvpn` (the 3.x client).

## Not handled

- **`expressvpn-unbound` has no `cap_net_bind_service`.** Store paths cannot carry file capabilities. Nothing in the tested paths needed it.
- **Routing table names.** The daemon appends its four table names to `/etc/iproute2/rt_tables` itself, creating the file if needed. The module leaves that to the daemon, as the vendor does.
- **Native Wayland.** The app sets `XDG_SESSION_TYPE=X11` for itself and uses XWayland.
