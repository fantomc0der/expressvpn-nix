---
name: update-expressvpn
description: Move this repository's ExpressVPN package to a new upstream release and verify it. Use this whenever the user asks to update, bump or upgrade ExpressVPN, asks whether a newer version is out, mentions a new ExpressVPN release, or is reviewing or finishing one of the automated "Update ExpressVPN" pull requests, even if they only say "check for updates".
---

# Updating ExpressVPN

A new release is a new closed binary. The version bump itself is one script, but the release only counts as working once it has made a real connection, because the failures that matter (a protocol that will not connect, DNS that does not resolve) do not show up in a build or in the offline VM test.

## Steps

1. **Start clean, on a branch.** `git status` should show no changes, so the update is its own commit. `main` only takes pull requests, so create a branch first (`git switch -c update-expressvpn`). If you are finishing one of the automated "Update ExpressVPN" pull requests, check out its branch instead and skip step 2.

2. **Run the update script** inside the dev shell:

   ```bash
   nix develop --command scripts/update.sh
   ```

   It asks ExpressVPN's installers API for the current Linux release, downloads the installer, verifies its GPG signature against `pkgs/expressvpn/release-key.asc`, and rewrites `pkgs/expressvpn/source.json` and the version in `README.md`. "already at <version>" means there is nothing to do: tell the user and stop.

   If the signature check fails, stop and report it. Do not work around it, and do not replace the key file: a mismatch means either the vendor rotated its key or the download is not what it claims to be, and the user has to decide which.

   To pin a specific version instead, pass it: `scripts/update.sh 14.3.1.15429`.

3. **Build and run the offline checks.**

   ```bash
   git add -A          # flakes only see tracked files
   nix flake check -L
   ```

   This is the lint, the package build and the VM test. Read the auto-patchelf output for new "could not satisfy dependency" lines: only `libQt6*.so.6` may be missing.

4. **Run the end-to-end test** for both DNS setups, one after the other (two at once block each other):

   ```bash
   scripts/e2e-test.sh <code-file>
   scripts/e2e-test.sh <code-file> resolved
   ```

   This needs the path to a file holding an ExpressVPN activation code. Ask the user for the path if you do not have it. Pass the path only: never read, print or copy the file, and never put the code on a command line.

   Each run takes a few minutes and should end with a `finished: subtest` line for connecting and disconnecting over each of the five protocols.

5. **Look at what changed upstream.** Extract the old and new installers (commands in `docs/updating.md`) and diff `x64/install.sh` and `x64/installfiles/`. New installer steps, new helper binaries or a changed service unit may need mirroring in `nixos/module.nix` even when every test passes.

6. **Commit** `source.json` and `README.md` (plus any fixes) with a message that names both versions, for example "Update ExpressVPN from 14.3.1.15429 to 14.4.0.15601".

7. **Open a pull request** (`git push -u origin <branch>`, then `gh pr create --fill`) and say in it what the end-to-end test covered. Merge once the `checks passed` check is green, asking the user first unless they have already said to merge.

## If something fails

Use the `debug-expressvpn` skill. Do not guess at a fix from the symptom: the daemon hides the output of its helper programs, and the real cause is usually visible only in a trace. `docs/updating.md` has a checklist of what tends to break and where each kind of fix belongs.

Record any new problem in `docs/architecture.md` with its symptom.

## If the end-to-end test cannot be run

Without an activation code or internet access, say so plainly in your summary: the build and the offline VM test passed, and a real connection has not been tested. Do not describe the update as verified.

## Reporting back

Tell the user the old and new versions, what was tested (which checks, which protocols, which DNS setups), anything that changed in the installer, and anything left untested.
