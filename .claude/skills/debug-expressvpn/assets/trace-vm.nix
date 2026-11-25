# A throwaway NixOS VM that runs the ExpressVPN daemon under strace and
# collects what it did. Driven by ../scripts/trace-vm.sh; see ../SKILL.md.
{
  # Path to the repository checkout.
  repo,
  pkgs ? import <nixpkgs> { config.allowUnfree = true; },
  useResolved ? false,
}:

pkgs.testers.runNixOSTest {
  name = "expressvpn-trace";

  nodes.machine =
    {
      config,
      lib,
      pkgs,
      modulesPath,
      ...
    }:
    let
      daemon = "${config.programs.expressvpn.package}/opt/expressvpn/bin/expressvpn-daemon";

      # Reduces the raw trace to files that are safe and small enough to read.
      # Writes to anything but stdout and stderr are dropped first: the daemon
      # writes account data to files and sockets, and that must not leave the VM.
      collect = pkgs.writeShellScript "expressvpn-trace-collect" ''
        out=/tmp/trace-out
        mkdir -p "$out"

        for name in daemon client; do
          raw=/tmp/$name.strace
          [ -f "$raw" ] || continue
          trace=$out/$name.trace
          grep -vE ' write\(([3-9]|[0-9]{2,}), ' "$raw" > "$trace"

          # Programs it tried to run but could not find.
          grep -E 'execve\(.* = -1 ENOENT' "$trace" | sed -E 's/^[0-9]+ +//' | cut -c1-240 |
            sort | uniq -c | sort -rn > "$out/$name.failed-execs.txt"

          # Programs it did run, most frequent first.
          grep -E 'execve\(' "$trace" | grep -E ' = 0$' |
            sed -E 's/^[0-9]+ +execve\("([^"]+)".*/\1/' |
            sort | uniq -c | sort -rn > "$out/$name.programs-run.txt"

          # Paths it looked for outside the Nix store and did not find.
          grep ENOENT "$trace" | grep -oE '"/[^"]*"' |
            grep -vE '^"/(nix/store|proc|sys|dev|tmp|home|run/user|opt/expressvpn/(etc|var))' |
            sort | uniq -c | sort -rn | head -n 300 > "$out/$name.missing-paths.txt"

          # What each of the app's own helper programs printed, and how it exited.
          grep -E 'execve\("[^"]*/opt/expressvpn/(bin|share)/[^"]+"' "$trace" | grep -v ' = -1 ' |
            grep -v '/expressvpn-daemon"' |
            while read -r pid rest; do
              echo "### pid $pid: $(cut -c1-700 <<<"$rest")"
              grep -E "^$pid +(write\([12], |\+\+\+ )" "$trace" |
                sed -E 's/^[0-9]+ +write\([12], "//; s/\\n", [0-9]+\) += [0-9]+$//' |
                cut -c1-400 | tail -n 60
              echo
            done > "$out/$name.helper-output.txt"

          gzip -f "$trace"
        done

        cp /opt/expressvpn/var/daemon.log "$out/" 2>/dev/null
        cp /tmp/client.log "$out/" 2>/dev/null
        journalctl -b --no-pager > "$out/journal.txt"
        expressvpnctl --unstable dump daemon-state 2>/dev/null |
          jq '{ vpnSupportErrors, splitTunnelSupportErrors, osUnsupported, connectionProblem, connectionState }' \
            > "$out/daemon-health.json"

        {
          echo "## expressvpnctl status";  expressvpnctl status
          echo "## ip -br addr";           ip -br addr
          echo "## ip route";              ip route
          echo "## ip rule";               ip rule
          for table in evpnrt evpnOnlyrt evpnWgrt evpnFwdrt; do
            echo "## ip route show table $table"; ip route show table "$table"
          done
          echo "## /etc/resolv.conf";      cat /etc/resolv.conf
          echo "## resolvectl dns";        resolvectl dns
          echo "## reverse-path filter";   iptables -t mangle -L nixos-fw-rpfilter -v -n
          echo "## interface counters";    ip -s link
          echo "## /etc/iproute2/rt_tables"; cat /etc/iproute2/rt_tables
        } > "$out/network.txt" 2>&1
      '';
    in
    {
      imports = [
        (repo + "/nixos/module.nix")
        (modulesPath + "/../tests/common/x11.nix")
        (modulesPath + "/../tests/common/user-account.nix")
      ];

      test-support.displayManager.auto.user = "alice";

      programs.expressvpn.enable = true;
      networking.networkmanager.enable = true;
      services.resolved.enable = useResolved;

      # "%" is doubled because systemd expands it in unit files.
      systemd.services.expressvpn-service.serviceConfig.ExecStart = lib.mkForce (
        "${pkgs.strace}/bin/strace -f --seccomp-bpf -s 600"
        + " -e trace=execve,openat,access,statx,write"
        + " -o /tmp/daemon.strace ${daemon}"
      );

      # Log from the first moment of the daemon's life.
      systemd.tmpfiles.rules = [ "f /opt/expressvpn/var/.expressvpn-early-debug 0644 root root -" ];

      environment.systemPackages = [
        pkgs.curl
        pkgs.jq
        pkgs.strace
        pkgs.xdotool
      ];
      environment.etc."expressvpn-trace-collect".source = collect;

      virtualisation = {
        memorySize = 3072;
        cores = 4;
        diskSize = 4096;
      };
    };

  testScript = ''
    import os

    code_file = os.environ.get("EXPRESSVPN_ACTIVATION_CODE_FILE", "")
    protocol = os.environ.get("EXPRESSVPN_PROTOCOL", "")
    trace_gui = os.environ.get("EXPRESSVPN_TRACE_GUI", "") != ""
    settle = int(os.environ.get("EXPRESSVPN_TRACE_SECONDS", "15"))

    machine.wait_for_unit("expressvpn-service.service")
    # Slower than usual: every program the daemon starts is being traced.
    machine.wait_until_succeeds("expressvpnctl get connectionstate", timeout=300)
    machine.succeed("expressvpnctl set debuglogging true")
    machine.succeed("expressvpnctl set vpnloglevel debug")

    try:
        if code_file:
            machine.wait_until_succeeds(
                "curl -fsS --max-time 15 -o /dev/null https://www.expressvpn.com", timeout=120
            )
            # Through the shared directory, so the code stays out of the log.
            machine.copy_from_host(code_file, "/root/activation-code")
            try:
                machine.succeed("expressvpnctl login /root/activation-code")
            finally:
                machine.succeed("rm -f /root/activation-code")
            machine.succeed("expressvpnctl background enable")
            if protocol:
                machine.succeed(f"expressvpnctl set protocol {protocol}")
            machine.execute("expressvpnctl connect")
            machine.execute(
                "for i in $(seq 1 45); do"
                " expressvpnctl get connectionstate | grep -qx Connected && break; sleep 1; done"
            )

        if trace_gui:
            machine.wait_for_x()
            machine.execute(
                "su - alice -c 'DISPLAY=:0 strace -f -s 300 -e trace=execve,openat,access,statx"
                " -o /tmp/client.strace expressvpn-client >/tmp/client.log 2>&1 &'"
            )
            machine.wait_until_succeeds(
                "grep -q 'Client connected, loading UI' /tmp/client.log", timeout=180
            )

        machine.sleep(settle)
        if trace_gui:
            machine.screenshot("gui")
        print(machine.execute("expressvpnctl status")[1])
        machine.succeed("/etc/expressvpn-trace-collect")
        machine.copy_from_machine("/tmp/trace-out")
    finally:
        if code_file:
            machine.execute("expressvpnctl disconnect")
            machine.execute("expressvpnctl logout")
  '';
}
