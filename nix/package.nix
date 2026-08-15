{
  lib,
  stdenvNoCC,
  fetchurl,
  version,
  sha256,
  # The `prebuilt` flake input's store path: normally the empty ./nix/dev-app
  # placeholder, but `bench try` overrides it to a dir holding a locally-built
  # Perch.app when feel-testing a source branch (see flake.nix / nix/dev-app).
  prebuilt,
}:

# Package Perch.app so the rice (and anyone) can install it through Nix instead
# of Homebrew — perch's handle in the flake-lock chain.
#
# Normally we fetch the CI-built release ZIP rather than compiling: perch is an
# Xcode project, and macOS 26 refuses to let a session-less `_nixbld` user apply
# SwiftPM's manifest sandbox, so a from-source Nix build dies at package
# resolution (pounce dodges this only by being plain `swiftc` with zero
# packages). The ZIP is already Developer-ID signed + Apple notarized, which is
# exactly what a stable permissions grant wants — so unpack it verbatim and let
# the rice place it at a fixed path (no re-sign dance).
#
# The one exception is `bench try` feel-testing a source branch: it builds the
# app in your login session (where xcodebuild works) and overrides `prebuilt` to
# that build, so we wrap that .app instead of the release. Same packaging.

let
  # bench points `prebuilt` at a dir containing a freshly-built Perch.app; the
  # placeholder has none, so we fall back to the release ZIP.
  useDev = builtins.pathExists "${prebuilt}/Perch.app";
in

stdenvNoCC.mkDerivation {
  pname = "perch";
  # Tag the dev build so its store path (and the rice's install marker) differ
  # from the release — activation then re-copies when you flip between them.
  version = if useDev then "${version}-dev" else version;

  src =
    if useDev then
      prebuilt
    else
      fetchurl {
        url = "https://github.com/hausfold/perch/releases/download/v${version}/perch-v${version}-macos.zip";
        inherit sha256;
      };

  # `ditto` is the macOS-correct copy/unarchive: the release ZIP is written by
  # `ditto -c -k` and carries the code signature + stapled notarization ticket as
  # bundle contents + xattrs; a locally-built .app carries its own signature.
  # Plain `unzip`/`cp` can drop those; ditto preserves them so the app verifies.
  # The release archive holds Perch.app at top level (built with --keepParent).
  unpackPhase = ''
    runHook preUnpack
    if [ -d "$src/Perch.app" ]; then
      /usr/bin/ditto "$src/Perch.app" ./Perch.app   # dev build injected by bench
    else
      /usr/bin/ditto -x -k "$src" .                 # release ZIP
    fi
    runHook postUnpack
  '';

  dontConfigure = true;
  dontBuild = true;

  # `bin/perch` is a symlink, never a copy: the tool is signed and notarized as
  # part of the bundle (ADR 0008), and a copy outside it would be nested code
  # torn out of the seal it was signed under. It is `perch-cli` in the bundle
  # because a `Contents/MacOS/perch` would overwrite `Contents/MacOS/Perch` on a
  # case-insensitive volume — which is every stock Mac.
  installPhase = ''
    runHook preInstall
    mkdir -p $out/Applications
    /usr/bin/ditto Perch.app $out/Applications/Perch.app
    # Guarded because the pin lags the source: releases cut before the tool
    # existed have no such binary, and a dangling bin/perch would be worse than
    # no bin/perch at all.
    if [ -x "$out/Applications/Perch.app/Contents/MacOS/perch-cli" ]; then
      mkdir -p $out/bin
      ln -s $out/Applications/Perch.app/Contents/MacOS/perch-cli $out/bin/perch
    fi
    runHook postInstall
  '';

  # Don't let Nix strip or re-sign the signed bundle — any rewrite invalidates
  # the signature the permissions grant depends on.
  dontFixup = true;

  meta = {
    description = "Native macOS notch file shelf";
    homepage = "https://github.com/hausfold/perch";
    # Safe to declare again now that perch is MIT (ADR 0009). It was left out
    # while the repo was FSL-1.1-ALv2: nixpkgs has no FSL license, and anything
    # that isn't a free license flips the package unfree, which breaks the
    # rice's install for anyone without allowUnfree.
    license = lib.licenses.mit;
    platforms = lib.platforms.darwin;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
