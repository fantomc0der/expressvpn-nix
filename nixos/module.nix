{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.programs.expressvpn;

  # The app's install prefix, compiled into its binaries. It holds links to
  # the package plus the app's writable state.
  prefix = "/opt/expressvpn";

  ctl = "${cfg.package}/bin/expressvpnctl";

  # Programs the daemon and its helper scripts shell out to. The daemon runs
  # every command through /bin/bash, some of them with PATH fixed to the
  # usual FHS directories, so the service gets this set mounted at /bin and
  # /usr/bin.
  daemonTools = pkgs.buildEnv {
    name = "expressvpn-daemon-tools";
    paths = [
      pkgs.bash
      pkgs.coreutils
      pkgs.e2fsprogs
      pkgs.findutils
      pkgs.gawk
      pkgs.gnugrep
      pkgs.gnused
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

  # An empty channel stops the daemon looking for new versions. Installing
  # them from within the app never works on NixOS, so that is always off.
  updateSettings = builtins.toJSON {
    updateChannel = if cfg.checkForUpdates then "release" else "";
    betaUpdateChannel = "";
    enableAutoUpdate = false;
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
    echo "the daemon did not accept the update settings" >&2
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
        Whether the app checks ExpressVPN's servers for new versions and tells
        you about them.

        The built-in updater downloads and runs the vendor's installer, which
        cannot work on NixOS, so automatic updates are always turned off and
        this notice is off by default. Update by updating the package instead.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = !(config.services.expressvpn.enable or false);
        message = ''
          programs.expressvpn (the current ExpressVPN app) and
          services.expressvpn (the legacy 3.x command-line client from
          nixpkgs) both manage the system's firewall and DNS. Enable only one.
        '';
      }
    ];

    environment.systemPackages = [ cfg.package ];

    # The daemon runs its helper processes under these groups and uses them in
    # its firewall rules.
    users.groups.expressvpn = { };
    users.groups.expressvpnhnsd = { };

    boot.kernelModules = [ "tun" ];

    # The daemon routes with firewall marks, which the strict reverse-path
    # check does not follow: it sees the VPN server's replies arrive on the
    # physical interface, expects them on the tunnel, and drops them.
    networking.firewall.checkReversePath = lib.mkDefault "loose";

    # Leave the app's WireGuard interface alone, as the vendor installer does.
    networking.networkmanager.unmanaged = [ "interface-name:wgexpressvpn*" ];

    systemd = {
      tmpfiles.rules = [
        "d ${prefix} 0755 root root -"
        "d ${prefix}/etc 0755 root root -"
        "d ${prefix}/var 0755 root root -"
      ]
      ++ map (dir: "L+ ${prefix}/${dir} - - - - ${cfg.package}${prefix}/${dir}") [
        "bin"
        "lib"
        "plugins"
        "qml"
        "share"
      ];

      services.expressvpn-service = {
        description = "ExpressVPN daemon";
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" ];
        # The daemon hands its PATH to OpenVPN's up/down script as command-line
        # words, and OpenVPN drops everything after the 16th word. The usual
        # NixOS service PATH is long enough to push the script's own arguments
        # off the end, so use the two mounted directories instead.
        environment.PATH = lib.mkForce "/usr/bin:/bin";
        serviceConfig = {
          ExecStart = "${cfg.package}${prefix}/bin/expressvpn-daemon";
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
