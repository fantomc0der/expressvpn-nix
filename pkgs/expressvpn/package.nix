{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
  makeWrapper,
  writeShellScript,
  bash,
  brotli,
  dbus,
  fontconfig,
  freetype,
  glib,
  libcap_ng,
  libdrm,
  libglvnd,
  libice,
  libnl,
  libredirect,
  libsm,
  libx11,
  libxau,
  libxdmcp,
  libxkbcommon,
  wayland,
  xdg-utils,
  xrdb,
  zlib,
}:

let
  source = lib.importJSON ./source.json;

  # The installer carries one payload per architecture.
  payloadDir =
    {
      x86_64-linux = "x64";
      aarch64-linux = "arm64";
    }
    .${stdenv.hostPlatform.system}
      or (throw "expressvpn: unsupported system ${stdenv.hostPlatform.system}");

  # The app expects to live in /opt/expressvpn. The vendor layout is kept
  # under $out/opt/expressvpn, and the NixOS module links it into place next
  # to the writable etc and var directories.
  prefix = "/opt/expressvpn";

  redirectLib = "${libredirect}/lib/libredirect.so";

  # Stand-in for an absolute tool path compiled into the GUI. It drops the
  # redirect library from the environment first, so that nothing the GUI
  # launches (a browser, for one) inherits it.
  shim =
    name: command:
    writeShellScript "expressvpn-${name}" ''
      preload=${redirectLib}
      LD_PRELOAD=''${LD_PRELOAD//"$preload"/}
      LD_PRELOAD=''${LD_PRELOAD#:}
      if [ -z "$LD_PRELOAD" ]; then unset LD_PRELOAD; fi
      unset NIX_REDIRECTS
      ${command}
    '';

  # Absolute paths the GUI expects, and what stands in for each on NixOS.
  redirects = {
    "/usr/bin/xdg-open" = shim "xdg-open" ''exec ${xdg-utils}/bin/xdg-open "$@"'';
    "/usr/bin/xrdb" = shim "xrdb" ''exec ${lib.getExe xrdb} "$@"'';
    "/usr/bin/gsettings" = shim "gsettings" ''exec ${lib.getBin glib}/bin/gsettings "$@"'';
    # The GUI restarts the daemon with "pkexec /bin/systemctl restart ...".
    "/usr/bin/pkexec" = shim "pkexec" ''
      if [ "$1" = /bin/systemctl ]; then
        shift
        set -- /run/current-system/sw/bin/systemctl "$@"
      fi
      exec /run/wrappers/bin/pkexec "$@"
    '';
    "/bin/bash" = lib.getExe bash;
    "/usr/share/pixmaps/" = "${placeholder "out"}/share/pixmaps/";
    "/usr/share/applications/expressvpn.desktop" =
      "${placeholder "out"}/share/applications/expressvpn.desktop";
  };
in
stdenv.mkDerivation {
  pname = "expressvpn";
  inherit (source) version;

  src = fetchurl {
    inherit (source) url hash;
  };

  nativeBuildInputs = [
    autoPatchelfHook
    makeWrapper
  ];

  buildInputs = [
    bash
    brotli
    dbus
    fontconfig
    freetype
    glib
    libcap_ng
    libdrm
    libglvnd
    libice
    libnl
    libsm
    libxau
    libxdmcp
    libxkbcommon
    stdenv.cc.cc.lib
    wayland
    zlib
  ];

  # The payload is a Makeself archive: a shell header, then a gzipped tarball.
  # Extract it directly instead of running the vendor's header script.
  unpackPhase = ''
    runHook preUnpack
    skip=$(head -n 100 "$src" | sed -n 's/^skip="\([0-9]\+\)"$/\1/p')
    if [ -z "$skip" ]; then
      echo "could not find the Makeself payload offset in $src" >&2
      exit 1
    fi
    tail -n "+$((skip + 1))" "$src" | tar -xz
    runHook postUnpack
  '';

  sourceRoot = ".";

  # The vendor ships QML and platform plugins for Qt modules it does not bundle
  # (virtual keyboard, eglfs, test helpers and similar). They are never loaded,
  # so their missing Qt libraries are not an error.
  autoPatchelfIgnoreMissingDeps = [ "libQt6*.so.6" ];

  # Libraries loaded by name at runtime: the daemon opens libnl, and Qt opens
  # the bundled OpenSSL from its TLS plugin.
  appendRunpaths = [
    "${placeholder "out"}${prefix}/lib"
    (lib.makeLibraryPath [ libnl ])
  ];

  dontConfigure = true;
  dontBuild = true;
  dontStrip = true;

  installPhase = ''
    runHook preInstall

    app=$out${prefix}
    payload=${payloadDir}

    # Refuse to package a payload whose version differs from source.json.
    payloadVersion=$(head -n 1 "$payload/package.txt" | tr '+' '.')
    if [ "$payloadVersion" != "$version" ]; then
      echo "payload is version $payloadVersion, expected $version" >&2
      exit 1
    fi

    mkdir -p "$app"
    cp -r "$payload/expressvpnfiles/." "$app/"

    # OpenVPN runs this script with an empty environment, and the script uses
    # external commands before it sets PATH from its arguments. Elsewhere bash
    # falls back to a built-in PATH; bash from nixpkgs has none, so add the
    # directories the daemon's service provides.
    updown=$app/bin/openvpn-updown.sh
    if ! head -n 1 "$updown" | grep -q '^#!/bin/bash'; then
      echo "$updown is no longer a bash script; review the PATH fix" >&2
      exit 1
    fi
    sed -i '1a PATH="''${PATH:+$PATH:}/usr/bin:/bin"' "$updown"

    # The installer's helper scripts: keep the OpenGL error dialog, drop the
    # updater and uninstaller, which only make sense on a mutable system.
    install -m755 "$payload/installfiles/error-notice.sh" "$app/bin/error-notice.sh"
    substituteInPlace "$app/bin/error-notice.sh" \
      --replace-fail $'PATH="/usr/bin:/usr/sbin:/bin:/sbin"\n' ""

    install -Dm644 "$payload/installfiles/app-icon.png" \
      "$out/share/icons/hicolor/256x256/apps/expressvpn.png"
    install -Dm644 "$payload/installfiles/app-icon.png" \
      "$out/share/pixmaps/expressvpn.png"
    install -Dm644 "$app/share/LICENSE.txt" \
      "$out/share/licenses/expressvpn/LICENSE.txt"

    # Launch by name: the app copies this file into ~/.config/autostart, where
    # a store path would go stale after the next update.
    install -Dm644 "$payload/installfiles/expressvpn.desktop" \
      "$out/share/applications/expressvpn.desktop"
    substituteInPlace "$out/share/applications/expressvpn.desktop" \
      --replace-fail "${prefix}/bin/expressvpn-client" "expressvpn-client" \
      --replace-fail $'Path=${prefix}/bin/\n' ""

    # Browser extension helper manifests, in the directories browsers search.
    helper=$app/share/browser_helper_wrapper.sh
    for dir in etc/chromium/native-messaging-hosts etc/opt/chrome/native-messaging-hosts; do
      install -Dm644 "$app/share/chrome.com.expressvpn.helper.json" \
        "$out/$dir/com.expressvpn.helper.json"
      substituteInPlace "$out/$dir/com.expressvpn.helper.json" \
        --replace-fail REPLACE_PATH "$helper"
    done
    install -Dm644 "$app/share/firefox.com.expressvpn.helper.json" \
      "$out/lib/mozilla/native-messaging-hosts/com.expressvpn.helper.json"
    substituteInPlace "$out/lib/mozilla/native-messaging-hosts/com.expressvpn.helper.json" \
      --replace-fail REPLACE_PATH "$helper"

    mkdir -p "$out/bin" "$out/libexec/expressvpn"
    ln -s "$app/bin/expressvpnctl" "$out/bin/expressvpnctl"

    # The GUI opens links with whichever xdg-open is first on PATH, so the
    # stand-in goes there as well.
    ln -s ${redirects."/usr/bin/xdg-open"} "$out/libexec/expressvpn/xdg-open"
    makeWrapper "$app/bin/expressvpn-client" "$out/bin/expressvpn-client" \
      --prefix PATH : "$out/libexec/expressvpn" \
      --prefix LD_PRELOAD : "${redirectLib}" \
      --set NIX_REDIRECTS "${
        lib.concatStringsSep ":" (lib.mapAttrsToList (from: to: "${from}=${to}") redirects)
      }" \
      --set-default XLOCALEDIR "${libx11}/share/X11/locale"

    runHook postInstall
  '';

  meta = {
    description = "ExpressVPN desktop app (GUI, CLI and daemon)";
    longDescription = ''
      The official ExpressVPN app for Linux: the graphical client, the
      `expressvpnctl` command-line tool and the background daemon.

      The app expects to be installed at /opt/expressvpn and needs its root
      daemon, so this package is only useful together with the NixOS module
      from the same repository.
    '';
    homepage = "https://www.expressvpn.com";
    downloadPage = "https://www.expressvpn.com/latest#linux";
    changelog = "https://www.expressvpn.com/support/release-notes/";
    license = lib.licenses.unfree;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
    ];
    mainProgram = "expressvpn-client";
  };
}
