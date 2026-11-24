{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.programs.expressvpn;

  # Where the app keeps its state. The path is compiled into the binaries.
  stateDir = "/opt/expressvpn";

  ctl = "${cfg.package}/bin/expressvpnctl";

  # Programs the daemon shells out to. It runs every command through
  # /bin/bash, and some of them with PATH fixed to the usual FHS directories,
  # so the service also gets this set mounted at /bin and /usr/bin.
  daemonTools = pkgs.buildEnv {
    name = "expressvpn-daemon-tools";
    paths = [
      pkgs.bash
      pkgs.coreutils
      pkgs.gawk
      pkgs.gnugrep
      pkgs.iproute2
      pkgs.iptables
      pkgs.kmod
      pkgs.procps
      pkgs.psmisc
      pkgs.util-linux
      pkgs.which
      config.systemd.package
    ]
    ++ lib.optional config.networking.resolvconf.enable config.networking.resolvconf.package;
    pathsToLink = [ "/bin" ];
    ignoreCollisions = true;
  };

  # The daemon reads this setting to decide where to look for new versions; an
  # empty channel turns the check off.
  updateSettings = builtins.toJSON {
    updateChannel = if cfg.checkForUpdates then "release" else "";
    betaUpdateChannel = "";
  };

  # The daemon only accepts settings over its socket, which appears a few
  # seconds after it starts (once it has built its firewall rules).
  applyUpdateSettings = pkgs.writeShellScript "expressvpn-apply-update-settings" ''
    for _ in $(seq 1 60); do
      if ${ctl} --timeout 2 --unstable applysettings ${lib.escapeShellArg updateSettings} 2>/dev/null; then
        exit 0
      fi
      sleep 1
    done
    echo "the daemon did not accept the update-check setting" >&2
    exit 1
  '';
in
{
  options.programs.expressvpn = {
    enable = lib.mkEnableOption "the ExpressVPN desktop app (GUI, CLI and daemon)";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ../pkgs/expressvpn/package.nix { };
      defaultText = lib.literalExpression "pkgs.callPackage ./pkgs/expressvpn/package.nix { }";
      description = "The ExpressVPN package to use.";
    };

    checkForUpdates = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether the app checks ExpressVPN's servers for new versions and
        offers to install them.

        The built-in updater downloads and runs the vendor's installer, which
        cannot work on NixOS, so this is off by default. Update by updating
        the package instead.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];

    # The daemon runs its helper processes under these groups and uses them in
    # its firewall rules.
    users.groups.expressvpn = { };
    users.groups.expressvpnhnsd = { };

    boot.kernelModules = [ "tun" ];

    # Leave the app's WireGuard interface alone, as the vendor installer does.
    networking.networkmanager.unmanaged = [ "interface-name:wgexpressvpn*" ];

    systemd = {
      tmpfiles.rules = [
        "d ${stateDir} 0755 root root -"
        "d ${stateDir}/etc 0755 root root -"
        "d ${stateDir}/var 0755 root root -"
      ];

      services.expressvpn-service = {
        description = "ExpressVPN daemon";
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" ];
        path = [ daemonTools ];
        serviceConfig = {
          ExecStart = "${cfg.package}/opt/expressvpn/bin/expressvpn-daemon";
          Restart = "always";
          BindReadOnlyPaths = [
            "${daemonTools}/bin:/bin"
            "${daemonTools}/bin:/usr/bin"
          ];
        };
      };

      # Runs after every daemon start, without holding up the daemon's own
      # startup.
      services.expressvpn-settings = {
        description = "Apply NixOS-managed ExpressVPN settings";
        wantedBy = [ "expressvpn-service.service" ];
        after = [ "expressvpn-service.service" ];
        partOf = [ "expressvpn-service.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = applyUpdateSettings;
        };
      };
    };

    # Let the ExpressVPN browser extension find the app's helper.
    environment.etc = {
      "chromium/native-messaging-hosts/com.expressvpn.helper.json".source =
        "${cfg.package}/etc/chromium/native-messaging-hosts/com.expressvpn.helper.json";
      "opt/chrome/native-messaging-hosts/com.expressvpn.helper.json".source =
        "${cfg.package}/etc/opt/chrome/native-messaging-hosts/com.expressvpn.helper.json";
    };
    programs.firefox.nativeMessagingHosts.packages = [ cfg.package ];
  };
}
