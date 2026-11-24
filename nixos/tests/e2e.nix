# End-to-end test against the real ExpressVPN service: log in, connect over
# each protocol, check that traffic and DNS go through the tunnel, disconnect
# and log out.
#
# It needs internet access and an account, so it cannot run in the Nix sandbox
# or in CI. Run it with scripts/e2e-test.sh, which builds the test driver and
# starts it outside the sandbox. See docs/testing.md.
{
  # Which DNS setup the machine uses: NixOS's default resolvconf, or
  # systemd-resolved. The daemon handles the two differently.
  useResolved ? false,
}:

{ pkgs, ... }:

{
  name = "expressvpn-e2e-${if useResolved then "resolved" else "resolvconf"}";

  nodes.machine = {
    imports = [ ../module.nix ];

    programs.expressvpn.enable = true;

    networking.networkmanager.enable = true;
    services.resolved.enable = useResolved;

    environment.systemPackages = [
      pkgs.curl
      pkgs.jq
    ];

    virtualisation.memorySize = 2048;
    virtualisation.cores = 2;
  };

  testScript = ''
    import os

    code_file = os.environ.get("EXPRESSVPN_ACTIVATION_CODE_FILE", "")
    assert os.path.isfile(code_file), (
        "set EXPRESSVPN_ACTIVATION_CODE_FILE to a file holding an activation code"
    )
    protocols = os.environ.get(
        "EXPRESSVPN_PROTOCOLS", "lightwayudp lightwaytcp openvpnudp openvpntcp wireguard"
    ).split()

    # Prints the address the internet sees this machine as.
    public_ip = "curl -fsS --max-time 15 https://api.ipify.org"


    machine.wait_for_unit("expressvpn-settings.service")
    machine.wait_until_succeeds(f"{public_ip} > /tmp/ip-direct", timeout=120)
    machine.succeed("cat /etc/resolv.conf > /tmp/resolv-direct")

    with subtest("log in"):
        # Copied through the driver's shared directory, so the code never
        # appears in the test log.
        machine.copy_from_host(code_file, "/root/activation-code")
        try:
            machine.succeed("expressvpnctl login /root/activation-code")
        finally:
            machine.succeed("rm -f /root/activation-code")
        # Without the GUI running, the daemon only connects in background mode.
        machine.succeed("expressvpnctl background enable")

    try:
        for protocol in protocols:
            with subtest(f"connect over {protocol}"):
                machine.succeed(f"expressvpnctl set protocol {protocol}")
                machine.succeed("expressvpnctl connect")
                machine.wait_until_succeeds(
                    "expressvpnctl get connectionstate | grep -x Connected", timeout=120
                )
                print(machine.succeed("expressvpnctl status"))

                # Traffic leaves through the VPN, and names still resolve.
                machine.wait_until_succeeds(
                    f'ip=$({public_ip}) && test "$ip" != "$(cat /tmp/ip-direct)"', timeout=60
                )
                machine.succeed("curl -fsS --max-time 15 -o /dev/null https://www.expressvpn.com")
                machine.fail("diff -q /etc/resolv.conf /tmp/resolv-direct")

            with subtest(f"disconnect from {protocol}"):
                machine.succeed("expressvpnctl disconnect")
                machine.wait_until_succeeds(
                    "expressvpnctl get connectionstate | grep -x Disconnected", timeout=60
                )
                machine.wait_until_succeeds(
                    f'ip=$({public_ip}) && test "$ip" = "$(cat /tmp/ip-direct)"', timeout=60
                )
                machine.wait_until_succeeds("diff /etc/resolv.conf /tmp/resolv-direct", timeout=30)
    finally:
        # Best effort, so that a failure above is what gets reported.
        machine.execute("expressvpnctl disconnect")
        machine.execute("expressvpnctl logout")
  '';
}
