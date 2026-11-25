{
  description = "schpet's Linear CLI (linear) for Linux and macOS, pinned to its GitHub releases with every hash cross-checked against the bytes";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  };

  # Offered, not imposed. Nix applies these only for a trusted user, and
  # otherwise says it is ignoring them. See the README for setting the
  # substituter in a NixOS configuration instead, which is what most people
  # actually want.
  nixConfig = {
    extra-substituters = [ "https://danielbodart.cachix.org" ];
    extra-trusted-public-keys = [
      "danielbodart.cachix.org-1:751qv4GxLFJCThWMEw1WL6kUqY0DpF6oqPqsLKnnEwU="
    ];
  };

  outputs =
    { self, nixpkgs }:
    let
      # Upstream publishes the CLI for Linux, macOS and Windows. This flake
      # packages Linux on amd64 and arm64, and macOS on Apple silicon. Not
      # Intel macOS: nixpkgs 26.11 drops x86_64-darwin, so it could be
      # neither built nor tested here for long.
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];

      forAllSystems = nixpkgs.lib.genAttrs systems;

      pkgsFor = system: nixpkgs.legacyPackages.${system};

      overlay = final: prev: {
        linear-cli = final.callPackage ./package.nix { };
      };
    in
    {
      overlays.default = overlay;

      packages = forAllSystems (
        system:
        let
          linear-cli = (pkgsFor system).callPackage ./package.nix { };
        in
        {
          inherit linear-cli;
          default = linear-cli;
        }
      );

      apps = forAllSystems (system: {
        default = self.apps.${system}.linear-cli;
        linear-cli = {
          type = "app";
          program = nixpkgs.lib.getExe self.packages.${system}.linear-cli;
          meta.description = "Run the Linear CLI";
        };
      });

      # `nix flake check` builds these. The package build is the real test: it
      # runs `linear --version` as its installCheck, so a green build means the
      # binary starts and reports the version that was pinned.
      checks = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        {
          inherit (self.packages.${system}) linear-cli;

          # sources.json is machine-written, and everything the build trusts
          # is in it. This catches a hand edit that leaves it inconsistent
          # with itself: a URL for another version or another repository,
          # another platform's tarball under the wrong system, or a hash that
          # is not sha256.
          sources-are-consistent =
            pkgs.runCommand "linear-cli-sources-are-consistent" { nativeBuildInputs = [ pkgs.jq ]; }
              ''
                jq -e '
                  . as $s
                  | ($s.version | test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))
                    and ($s.sources | keys == ["aarch64-darwin", "aarch64-linux", "x86_64-linux"])
                    and ($s.sources | to_entries | all(
                      .value.url | startswith("https://github.com/schpet/linear-cli/releases/download/v\($s.version)/")))
                    and ($s.sources."x86_64-linux".url | endswith("/linear-x86_64-unknown-linux-gnu.tar.xz"))
                    and ($s.sources."aarch64-linux".url | endswith("/linear-aarch64-unknown-linux-gnu.tar.xz"))
                    and ($s.sources."aarch64-darwin".url | endswith("/linear-aarch64-apple-darwin.tar.xz"))
                    and ($s.sources | to_entries | all(.value.hash | test("^sha256-[A-Za-z0-9+/]{43}=$")))
                ' ${./sources.json} >/dev/null || {
                  echo "sources.json is not self-consistent" >&2
                  exit 1
                }
                touch $out
              '';

          shellcheck = pkgs.runCommand "linear-cli-shellcheck" { nativeBuildInputs = [ pkgs.shellcheck ]; } ''
            shellcheck ${./scripts/update.sh}
            touch $out
          '';
        }
      );

      devShells = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        {
          default = pkgs.mkShell {
            packages = with pkgs; [
              coreutils
              curl
              gnutar
              jq
              nixfmt
              shellcheck
              xz
            ];
          };
        }
      );

      formatter = forAllSystems (system: (pkgsFor system).nixfmt);
    };
}
