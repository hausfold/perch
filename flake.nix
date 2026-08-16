{
  description = "Perch — a native macOS notch file shelf";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    # Injection point for feel-testing a perch SOURCE branch through `bench try`.
    # macOS 26 blocks a from-source Nix build (see nix/package.nix), so bench
    # builds Perch.app from the branch in your login session and overrides this
    # input to that built .app dir; the package then wraps your branch's app
    # instead of the release. Default: the empty ./nix/dev-app placeholder →
    # package fetches the release as normal. `flake = false`: it's a plain dir.
    prebuilt = {
      url = "path:./nix/dev-app";
      flake = false;
    };
  };

  outputs =
    { self, nixpkgs, prebuilt }:
    let
      systems = [
        "aarch64-darwin"
        "x86_64-darwin"
      ];
      forAll = nixpkgs.lib.genAttrs systems;
      pkgsFor = system: import nixpkgs { inherit system; overlays = [ self.overlays.default ]; };

      # The CI-owned release pin (version + sha256 of the notarized .zip).
      release = import ./nix/release.nix;
    in
    {
      # Consume perch from anywhere: `overlays.default` puts `perch` into pkgs.
      # The rice adds this overlay and installs pkgs.perch in place of the cask.
      overlays.default = final: prev: {
        perch = final.callPackage ./nix/package.nix {
          inherit (release) version sha256;
          prebuilt = prebuilt.outPath;
        };

        # The agent skill (ai/SKILL.md), so a consumer can install it without
        # installing perch itself — haus's AI room drops it into every agent
        # client on the machine. Deliberately its own package rather than a
        # file inside `perch`: it is pure, tiny and platform-agnostic, while
        # `perch` wraps a macOS-only notarized ZIP. See nix/skill.nix.
        perch-skill = final.callPackage ./nix/skill.nix { };
      };

      packages = forAll (
        system:
        let
          pkgs = pkgsFor system;
        in
        {
          default = pkgs.perch;
          perch = pkgs.perch;
          perch-skill = pkgs.perch-skill;
        }
      );
    };
}
