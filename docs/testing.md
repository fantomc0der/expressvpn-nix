# Testing

There are three levels of testing. The first two run anywhere, including CI. The third needs an ExpressVPN account and internet access.

| Level | Command | Needs | Covers |
|---|---|---|---|
| Lint | `nix build .#checks.x86_64-linux.lint` | nothing | Formatting, statix, deadnix, shellcheck |
| VM test | `nix build .#checks.x86_64-linux.basic` | KVM | Daemon, CLI, firewall setup, settings, GUI start |
| End-to-end | `scripts/e2e-test.sh <code-file>` | KVM, internet, account | Login and a real connection over every protocol |

`nix flake check` runs the first two and builds the package.

## VM test

`nixos/tests/basic.nix` boots a NixOS VM with the module enabled and an X session, then checks that:

- the daemon starts and `expressvpnctl` reaches it;
- the daemon created its firewall chains and routing table names (which proves `/bin/bash` and the tools work);
- the daemon reports no VPN or split tunnel support errors;
- the update settings were applied;
- a changed setting lands in `/opt/expressvpn/etc/settings.json`;
- the GUI starts, connects to the daemon and writes its autostart entry;
- the desktop entry and browser manifests are in place.

A screenshot of the GUI is saved in the test's output (`result/gui.png`).

The test VM has no internet access, so it cannot log in or connect.

To poke at the VM by hand:

```bash
nix build .#checks.x86_64-linux.basic.driverInteractive
./result/bin/nixos-test-driver
>>> start_all()
>>> machine.shell_interact()
```

## End-to-end test

`nixos/tests/e2e.nix` is the same kind of test, run outside the Nix sandbox so the VM can reach the internet through QEMU's user-mode networking. Nothing on the host changes and no root access is needed.

```bash
scripts/e2e-test.sh ~/expressvpn-activation-code              # resolvconf, NixOS's default
scripts/e2e-test.sh ~/expressvpn-activation-code resolved     # systemd-resolved
```

For each protocol (`lightwayudp`, `lightwaytcp`, `openvpnudp`, `openvpntcp`, `wireguard`) it:

1. connects and waits for `Connected`;
2. checks that the machine's public address changed and that HTTPS and DNS work;
3. checks that the DNS configuration changed;
4. disconnects, and checks that the public address and DNS configuration are back.

It logs in at the start and logs out at the end. Run one variant at a time: two drivers started together block each other.

Useful variations:

```bash
# Only some protocols
EXPRESSVPN_PROTOCOLS="openvpnudp wireguard" scripts/e2e-test.sh ~/code

# Against your system's nixpkgs instead of the pinned one
scripts/e2e-test.sh ~/code resolvconf -- --arg pkgs 'import <nixpkgs> { config.allowUnfree = true; }'
```

### The activation code

The script takes a file path, never the code itself. The test driver copies the file into the VM through its shared directory and deletes it there after logging in, so the code does not appear in the test log or in the Nix store. Keep the file out of the repository; `.gitignore` covers `*activation-code*`.

## Checking the GUI by hand

After installing on a real machine:

1. Open ExpressVPN. The window shows the sign-in card or the location picker.
2. Sign in, then click the power button. The header turns green and shows **Protected**.
3. `expressvpnctl status` agrees with the GUI.
4. Disconnect. Your normal DNS servers are back in `/etc/resolv.conf` (or `resolvectl dns`).

## Debugging a failure

The daemon says little by default. These are the techniques that found every problem documented in [architecture.md](architecture.md).

### Turn on the daemon log

```bash
expressvpnctl set debuglogging true      # writes /opt/expressvpn/var/daemon.log
expressvpnctl set vpnloglevel debug      # more from the VPN helper processes
```

To log from the very start of the daemon, create `/opt/expressvpn/var/.expressvpn-early-debug` before it starts.

Lines from `src/exec.cpp` and `src/newexec.cpp` show each shell command the daemon ran and its exit status. `(127)` means "command not found": a tool is missing from `daemonTools` in the module.

### Ask the daemon what it thinks is wrong

```bash
expressvpnctl --unstable dump daemon-state | jq '{ vpnSupportErrors, splitTunnelSupportErrors, osUnsupported, connectionProblem }'
```

### Trace what the daemon executes

The daemon does not log the output of its helper processes. The quickest way to see it is the tracing VM that ships with the `debug-expressvpn` skill. It runs the daemon under `strace`, optionally logs in and connects, and writes summaries (programs not found, paths not found, each helper's output, network state) to a results directory:

```bash
.claude/skills/debug-expressvpn/scripts/trace-vm.sh --online <code-file> --protocol openvpnudp
```

To do the same by hand in a test VM, wrap the daemon in `strace`:

```nix
systemd.services.expressvpn-service.serviceConfig.ExecStart = lib.mkForce
  "${pkgs.strace}/bin/strace -f --seccomp-bpf -s 400 -e trace=execve,write -o /tmp/daemon.strace ${config.programs.expressvpn.package}/opt/expressvpn/bin/expressvpn-daemon";
```

Then look for:

- `execve(...) = -1 ENOENT`: a hardcoded path that does not exist.
- A helper's `write(1, ...)` and `write(2, ...)` lines: its own log. This is how OpenVPN's "could not execute external program" surfaced.
- `+++ exited with N +++` right after a script starts.

To find paths the GUI expects, trace `expressvpn-client` with `-e trace=openat,access,execve` and filter for `ENOENT` outside `/nix/store`.

### "Connected" but no traffic

```bash
ip -s link show tun0                                     # RX stays at 0?
sudo iptables -t mangle -L nixos-fw-rpfilter -v -n       # is the DROP counter climbing?
ip rule; ip route show table evpnWgrt
```

A climbing DROP counter means the reverse-path filter is strict again; see the firewall section of [architecture.md](architecture.md).
