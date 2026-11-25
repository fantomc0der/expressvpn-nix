---
name: debug-expressvpn
description: Diagnose why the packaged ExpressVPN app misbehaves on NixOS (the daemon will not start, a protocol will not connect, "Connected" but no traffic, DNS breaks, the GUI is missing icons or cannot open links, a test in this repository fails). Use this whenever something in this repository's package, module or tests stops working, especially after a new ExpressVPN release or a nixpkgs update, and before changing package.nix or module.nix to "fix" a symptom whose cause has not been seen in a trace or log.
---

# Debugging the ExpressVPN package

The app is a closed binary built for mainstream distros. When it fails on NixOS the cause is almost always one of four things: a hardcoded path that does not exist, a tool missing from the daemon's environment, an assumption about the shell environment, or a NixOS default (firewall, DNS) that the daemon does not expect.

The daemon rarely says which. It does not log the output of the helper programs it starts, and it retries silently. So the method is to **watch what it actually executes**, not to reason from the symptom. Every fix in this repository was found that way, and several first guesses were wrong (see "Lessons" below).

Read `docs/architecture.md` first. It records each known problem with its symptom, so check whether you are looking at a known one that has come back.

## 1. Reproduce it in a VM

Never debug on the user's machine first. A VM is disposable, needs no root, and cannot break their network.

```bash
# Startup only, offline
.claude/skills/debug-expressvpn/scripts/trace-vm.sh

# Log in and connect with one protocol
.claude/skills/debug-expressvpn/scripts/trace-vm.sh --online <code-file> --protocol openvpnudp

# With systemd-resolved, and with the GUI traced as well
.claude/skills/debug-expressvpn/scripts/trace-vm.sh --online <code-file> --resolved --gui
```

It boots a NixOS VM with the module enabled, runs the daemon under `strace`, and writes a results directory:

| File | What it answers |
|---|---|
| `daemon-health.json` | Does the daemon itself report a problem? Did it reach `Connected`? |
| `daemon.failed-execs.txt` | Which programs could it not find? |
| `daemon.missing-paths.txt` | Which paths outside the Nix store did it look for and not find? |
| `daemon.helper-output.txt` | What did OpenVPN, Lightway and the scripts print, and how did they exit? |
| `daemon.programs-run.txt` | What does it shell out to? |
| `daemon.log` | The daemon's debug log |
| `network.txt` | Routes, rules, DNS configuration, firewall drop counters, interface counters |
| `client.*`, `gui.png` | The same for the GUI, with `--gui` |
| `daemon.trace.gz` | The full trace, for anything the summaries miss |

The activation code: pass the file path, never read or print the file. The driver copies it into the VM through its shared directory. Ask the user for the path if you do not have one.

The results can hold server addresses and account identifiers. Put them in a scratch directory, not in the repository, and delete them when done.

## 2. Read the results in this order

1. **`daemon-health.json`.** Non-empty `vpnSupportErrors` or `splitTunnelSupportErrors` name the problem directly.
2. **`daemon.failed-execs.txt`.** Anything here is a hardcoded program path. Most entries are harmless probes for other VPN software; look for ones the app needs.
3. **`daemon.helper-output.txt`.** Find the helper for the failing protocol and read its last lines. An exit status other than 0 right after a script starts is the lead to follow.
4. **`daemon.log`.** Lines from `src/exec.cpp` and `src/newexec.cpp` show each shell command with its exit status in parentheses. `(127)` is "command not found".
5. **`network.txt`**, when it connects but nothing flows. `RX` at 0 on the tunnel with the `nixos-fw-rpfilter` DROP counter climbing is the reverse-path filter.
6. **`daemon.missing-paths.txt`.** Long and mostly noise (certificate directories, `/etc/localtime`). Use it to confirm a suspicion, not to go fishing.

To look inside the binaries for hardcoded paths, extract the installer (see `docs/updating.md`) and run both `strings -n 5` and `strings -el -n 5`. Qt stores its string literals as UTF-16, which plain `strings` does not show.

## 3. Fix it in the right place

| Cause | Fix |
|---|---|
| The daemon or a script needs a tool | Add it to `daemonTools` in `nixos/module.nix` |
| The GUI needs a path | Add it to `redirects` in `pkgs/expressvpn/package.nix` |
| A vendor script assumes something about the environment | Patch the script in `installPhase`, with a check that fails the build if the script changes shape |
| A NixOS default conflicts with the daemon | Set the option in the module with `lib.mkDefault`, so users can override it |
| A new step in the vendor's `install.sh` | Mirror it in the module |

Keep fixes as small as the cause. Prefer giving the app the environment it expects over patching its files, because patches have to survive every vendor release. Use `--replace-fail` or an explicit check so a patch that stops applying breaks the build instead of silently doing nothing.

## 4. Prove it and write it down

- Re-run the trace and confirm the symptom is gone for the reason you think.
- Run `nix flake check`, then `scripts/e2e-test.sh <code-file>` for both `resolvconf` and `resolved`. A fix for one protocol or one DNS setup can break another.
- If the automated tests did not catch the problem, add a check to `nixos/tests/basic.nix` or `nixos/tests/e2e.nix` that would have.
- Add the problem to `docs/architecture.md`: the symptom, the cause and the fix. The symptom matters most, because that is what the next person will search for.

## Lessons from past debugging

These are here because each one cost time.

- **A plausible cause is not a found cause.** OpenVPN has `/sbin/ip` compiled in and NixOS has no `/sbin`, which looked like the reason OpenVPN failed. The trace showed the daemon already passes `--iproute` with the right path. A wrapper added on that guess made things worse.
- **"could not execute external program" can mean the program ran.** OpenVPN prints it when a script exits with status 127, which is what bash returns for "command not found" inside the script.
- **The environment a helper sees is not the daemon's.** OpenVPN runs its script with an empty environment. Bash from nixpkgs has no built-in default PATH, unlike bash on other distros.
- **Limits in the vendor's tools are part of the environment.** OpenVPN keeps only 16 words of a script command line, and the daemon passes PATH on that command line. A long PATH silently truncated the script's arguments.
- **Offline VMs behave differently.** The daemon hangs on exit when it has no network. That is why stopping it takes 90 seconds in the sandboxed test and a few seconds on a real machine.
- **One driver at a time.** Two NixOS test drivers started together block each other.
