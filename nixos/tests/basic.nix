# Boots a machine with the module enabled and checks that the daemon, the CLI
# and the GUI all work. The test VM has no internet access, so it does not log
# in or connect; see docs/testing.md for the end-to-end procedure.
{ pkgs, ... }:

{
  name = "expressvpn-basic";

  nodes.machine =
    { modulesPath, ... }:
    {
      imports = [
        ../module.nix
        (modulesPath + "/../tests/common/x11.nix")
        (modulesPath + "/../tests/common/user-account.nix")
      ];

      test-support.displayManager.auto.user = "alice";

      programs.expressvpn.enable = true;

      # The same network stack as a typical desktop install.
      networking.networkmanager.enable = true;

      environment.systemPackages = [ pkgs.jq ];

      virtualisation.memorySize = 2048;
    };

  testScript = ''
    import json

    machine.wait_for_unit("expressvpn-service.service")
    machine.wait_for_file("/opt/expressvpn/var/daemon.sock")

    with subtest("the CLI talks to the daemon"):
        machine.wait_until_succeeds("expressvpnctl get connectionstate | grep -x Disconnected")
        status = machine.succeed("expressvpnctl status")
        assert "Not logged in" in status, status

    with subtest("the daemon found the tools it shells out to"):
        # It creates its firewall chains through /bin/bash and iptables.
        machine.wait_until_succeeds("iptables -S | grep -q -- '-N evpn.'")
        machine.wait_until_succeeds("grep -q evpnrt /etc/iproute2/rt_tables")
        machine.succeed("getent group expressvpn expressvpnhnsd")

    with subtest("the update check is turned off"):
        machine.wait_for_unit("expressvpn-settings.service")
        machine.succeed(
            "expressvpnctl --unstable dump daemon-settings | jq -e '.updateChannel == \"\"'"
        )

    with subtest("settings are written to the state directory"):
        machine.succeed("expressvpnctl set allowlan false")
        machine.wait_until_succeeds("jq -e '.allowLAN == false' /opt/expressvpn/etc/settings.json")

    with subtest("the GUI starts and connects to the daemon"):
        machine.wait_for_x()
        machine.wait_for_file("/home/alice/.Xauthority")
        machine.succeed("xauth merge ~alice/.Xauthority")
        machine.succeed("su - alice -c 'DISPLAY=:0 expressvpn-client >/tmp/client.log 2>&1 &'")
        machine.wait_for_window("ExpressVPN")
        machine.wait_until_succeeds("grep -q 'Client connected, loading UI' /tmp/client.log")
        machine.sleep(5)
        machine.screenshot("gui")

    with subtest("the desktop entry and browser manifests are installed"):
        machine.succeed("grep -x 'Exec=env XDG_SESSION_TYPE=X11 expressvpn-client %u' /run/current-system/sw/share/applications/expressvpn.desktop")
        manifest = json.loads(machine.succeed("cat /etc/chromium/native-messaging-hosts/com.expressvpn.helper.json"))
        machine.succeed(f"test -x {manifest['path']}")
  '';
}
