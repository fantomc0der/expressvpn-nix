# Updating to a new ExpressVPN release

## The short version

```bash
nix develop
scripts/update.sh                 # rewrites pkgs/expressvpn/source.json
nix flake check                   # lint, build, VM test
scripts/e2e-test.sh <code-file>   # real connection, every protocol
scripts/e2e-test.sh <code-file> resolved
```

If all of that passes, commit on a branch and open a pull request (`main` only takes pull requests; see [testing.md](testing.md#ci-and-pull-requests)). The script also updates the version shown in `README.md`.

## What `scripts/update.sh` does

1. Asks ExpressVPN's installers API for the current Linux release (key `linux_qt`). This is the API behind <https://www.expressvpn.com/latest>.
2. Downloads the installer and its detached signature.
3. Verifies the signature against `pkgs/expressvpn/release-key.asc`, in a throwaway keyring, and checks that the signing key's fingerprint is `1D0B09AD6C93FEE93FDDBD9DAFF2A1415F6A3A38`.
4. Compares the SHA-256 with the one the API lists.
5. Writes the version, URL and hash to `source.json` and adds the installer to the Nix store.

It does nothing if `source.json` is already current. Pass a version to pin one (`scripts/update.sh 14.3.1.15429`), which builds the URL from the usual pattern and skips the API.

If the API ever moves, open <https://www.expressvpn.com/latest>, read `API_BASE_URL` from the page source, and update `installers_api` in the script. Passing the version by hand keeps working either way.

The weekly `update` workflow runs this script and opens a pull request when there is a new release. GitHub holds CI on pull requests opened by a workflow until a maintainer approves it: click **Approve and run workflows** on the pull request (details in [testing.md](testing.md#pull-requests-opened-by-the-update-workflow)). CI cannot run the end-to-end test, so do that locally before merging.

## When a new release breaks

Vendor updates can move files, add tools the daemon shells out to, or change hardcoded paths. Work through this list; [testing.md](testing.md) describes each technique.

1. **The build fails in `installPhase`.** A `--replace-fail` no longer matches, or the version check trips. Extract the installer and compare with what the package expects:

   ```bash
   src=$(nix build --no-link --print-out-paths .#expressvpn.src)
   skip=$(head -n 100 "$src" | sed -n 's/^skip="\([0-9]\+\)"$/\1/p')
   mkdir /tmp/xv && tail -n "+$((skip + 1))" "$src" | tar -xz -C /tmp/xv
   ls /tmp/xv/x64 /tmp/xv/x64/installfiles
   ```

   Extract the previous release the same way (check out the old `source.json`) and diff the two `install.sh` files. New installer steps (groups, files, capabilities) need mirroring in the module.

2. **`autoPatchelfHook` reports a missing library.** Add the nixpkgs package that provides it to `buildInputs`. Only `libQt6*.so.6` is allowed to be missing.

3. **The VM test fails on "the daemon found the tools it shells out to".** Turn on the daemon log and look for `(127)` exit codes. Add the missing tool to `daemonTools` in the module.

4. **The end-to-end test fails for one protocol.** Trace the daemon in a VM and read the helper's own output. Check for new hardcoded paths in the helper:

   ```bash
   strings -n 5 /tmp/xv/x64/expressvpnfiles/bin/<helper> | grep -E '^/(usr|bin|sbin|etc|opt)/'
   ```

   Qt programs store their strings as UTF-16, so also run `strings -el`.

5. **The GUI is missing an icon, cannot open links, or a toggle does nothing.** Trace `expressvpn-client` for `ENOENT` and add the path to `redirects` in the package.

6. **"Connected" but no traffic.** See [testing.md](testing.md#connected-but-no-traffic).

Record anything new in [architecture.md](architecture.md), with the symptom, so the next update is easier.

## Updating nixpkgs

```bash
nix flake update
nix flake check
```

The repository's nixpkgs pin only affects its own checks and `nix build`. Users of the module build against their own nixpkgs. CI also tests against the current stable NixOS release.
