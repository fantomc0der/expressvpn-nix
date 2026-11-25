# expressvpn-nix

Packages the official ExpressVPN Linux app (GUI, `expressvpnctl`, daemon) for NixOS. The app is a closed binary shipped as a self-extracting installer; this repository repacks it and supplies the NixOS module it needs.

## Layout

| Path | What it is |
|---|---|
| `pkgs/expressvpn/package.nix` | The package: extracts the installer, patches libraries, wraps the GUI |
| `pkgs/expressvpn/source.json` | Version, URL and hash. Written by `scripts/update.sh`, not by hand |
| `pkgs/expressvpn/release-key.asc` | ExpressVPN's release signing key, used to verify downloads |
| `nixos/module.nix` | `programs.expressvpn`: daemon service, `/opt/expressvpn`, firewall and DNS integration |
| `nixos/tests/basic.nix` | Offline VM test, part of `nix flake check` |
| `nixos/tests/e2e.nix` | Real-connection test, run by `scripts/e2e-test.sh` |
| `scripts/` | `update.sh` and `e2e-test.sh` |
| `docs/` | Installation, architecture, testing, updating, troubleshooting |
| `.claude/skills/` | `update-expressvpn` and `debug-expressvpn` |

## Read before changing the package or module

`docs/architecture.md` explains why each non-obvious line exists. Most of them fix a specific failure that took a trace to find, and the comments in the code are deliberately short. Removing something that "looks unnecessary" will likely bring one of those failures back.

## Commands

```bash
nix fmt                         # format Nix files
git add -A && nix flake check   # lint, build, VM test (flakes ignore untracked files)
scripts/e2e-test.sh <code-file> [resolvconf|resolved]   # real connection, needs an account
nix develop --command scripts/update.sh                 # move to the latest ExpressVPN release
```

For quick local iteration, build against the system's nixpkgs, which is usually cached:

```bash
nix-build -A package --arg pkgs 'import <nixpkgs> { config.allowUnfree = true; }'
nix-build -A tests.basic --arg pkgs 'import <nixpkgs> { config.allowUnfree = true; }'
```

## Branches and pull requests

`main` is protected on GitHub: direct pushes are rejected for everyone, and a pull request can only merge once the `checks passed` status check is green. Work on a branch:

```bash
git switch -c short-description
git push -u origin short-description
gh pr create --fill            # gh comes with the dev shell: nix develop
gh pr checks --watch
gh pr merge --squash --delete-branch
```

Do not get around the rule (no bypass, no editing the ruleset to land a change). If CI fails, fix the branch. Details are in `docs/testing.md`.

## Before committing

- `nix flake check` passes.
- A change to `package.nix`, `module.nix` or `source.json` has also passed `scripts/e2e-test.sh` for both `resolvconf` and `resolved`. The offline test cannot see connection failures. If you could not run it, say so; do not call the change verified.
- New behaviour or a newly found problem is recorded in `docs/` (problems go in `docs/architecture.md`, with the symptom).

Commit messages are a plain sentence saying what changed, with a body explaining why when it is not obvious. One logical change per commit.

## Rules

- **Never commit the installer or an activation code.** `.gitignore` covers the usual file names. The installer is fetched by Nix; nothing proprietary lives in the repository.
- **Handle activation codes by file path only.** Never read, print or copy the file, and never put the code on a command line, in the Nix store or in a log. The test scripts take a path and pass the file into the VM through the test driver's shared directory.
- **Never run the vendor installer.** The package extracts the archive directly. To inspect a release, extract it to a scratch directory (commands in `docs/updating.md`).
- **Test in VMs, not on the host.** The daemon rewrites firewall rules, routes and DNS. Everything can be reproduced in a NixOS test VM without root. Changing the user's own system needs their say-so.
- **Find the cause before fixing.** The daemon hides its helpers' output, so guesses are often wrong. Use the `debug-expressvpn` skill to trace what actually happens.
- **Give the app the environment it expects rather than patching it.** Where a patch is unavoidable, use `--replace-fail` or an explicit check so it breaks the build when it stops applying.
- **Keep module defaults overridable** with `lib.mkDefault` when they change system-wide behaviour.

## Things that will surprise you

- The daemon runs every external command through `/bin/bash`, and some with PATH fixed to FHS directories. Its service therefore has `/bin` and `/usr/bin` replaced by a tools directory, and `PATH=/usr/bin:/bin`. The PATH must stay short: it is passed on an OpenVPN command line that is cut off after 16 words.
- The daemon's own binaries are found relative to the running executable, but its state is always in `/opt/expressvpn/etc` and `/opt/expressvpn/var`.
- Qt programs store string literals as UTF-16. Use `strings -el` as well as `strings` when looking for paths in the binaries.
- In the offline test VM the daemon takes about 30 seconds to start and 90 seconds to stop. Neither is a bug in the packaging.
- Two NixOS test drivers started at the same time block each other. Run end-to-end tests one at a time.
- CI tests against a named stable NixOS branch in `.github/workflows/ci.yml`. Bump it when a new NixOS release comes out. The branch rule requires only the `checks passed` job, so changing the matrix needs no change to the repository settings.
