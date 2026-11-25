# linear-cli

A Nix flake for [schpet/linear-cli](https://github.com/schpet/linear-cli), the
`linear` command for the [Linear](https://linear.app) issue tracker.

Upstream publishes a prebuilt binary for each platform on its GitHub releases.
This flake packages that binary for Linux and macOS. CI keeps the pin current.

```nix
{
  inputs.linear-cli.url = "github:danielbodart/linear-cli";
}
```

## Install

### NixOS or nix-darwin

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    linear-cli.url = "github:danielbodart/linear-cli";
  };

  outputs = { nixpkgs, linear-cli, ... }: {
    nixosConfigurations.yourhost = nixpkgs.lib.nixosSystem {
      modules = [
        ({ pkgs, ... }: {
          nixpkgs.overlays = [ linear-cli.overlays.default ];
          environment.systemPackages = [ pkgs.linear-cli ];
        })
      ];
    };
  };
}
```

You can also use the package without the overlay:

```nix
environment.systemPackages = [ inputs.linear-cli.packages.${pkgs.system}.default ];
```

### Home Manager, or any other profile

```nix
home.packages = [ inputs.linear-cli.packages.${pkgs.system}.default ];
```

### Try it without installing

```bash
nix run github:danielbodart/linear-cli -- --help
```

The binary is `linear`. The package includes bash, fish and zsh completions.

## Log in

1. Make a personal API key in Linear, at [linear.app/settings/account/security](https://linear.app/settings/account/security), under **Personal API keys**.
2. Run `linear auth login` and paste the key.

On Linux, the CLI keeps the key in the desktop keyring through `secret-tool`.
The package puts `secret-tool` on the CLI's PATH, after your own.
On macOS, the CLI uses the Keychain.

`LINEAR_API_KEY` overrides a stored key. The CLI also reads `LINEAR_API_KEY`
from a `.env` file in the current directory. Set `LINEAR_IGNORE_ENV_FILE=1` to
stop this.

## Platforms

- `x86_64-linux`
- `aarch64-linux`
- `aarch64-darwin`

Upstream also publishes builds for Intel macOS and Windows. This flake does
not package them. nixpkgs 26.11 drops `x86_64-darwin`, so CI could not build
or test that build for long.

## Provenance

Upstream builds its releases with [cargo-dist](https://opensource.axo.dev/cargo-dist/).
A release has no PGP signature and no GitHub artifact attestation.
It has these items:

- one `.tar.xz` per platform;
- a `.sha256` file for each tarball, and a `sha256.sum` for all of them;
- `dist-manifest.json`, which describes the release.

GitHub adds one more item: the `digest` of each asset in the releases API.
GitHub calculates it when the asset is uploaded. The publisher does not write it.

The trust chain is **TLS to GitHub, then the release's sums and GitHub's
digest, then the bytes.** This does not protect you if upstream's release job
or the maintainer's GitHub account is compromised. It is weaker than
[claude-desktop](https://github.com/danielbodart/claude-desktop)'s chain to a
pinned PGP key.

`scripts/update.sh` does these checks before it writes a hash:

| Check | What it catches |
| --- | --- |
| The release is GitHub's latest: not a draft, not a pre-release, tagged `v<major>.<minor>.<patch>` | Alphas and release candidates |
| The release is not older than the pin | A deleted release, or an old one marked latest |
| `dist-manifest.json` names the same tag as stable | A manifest from a different release |
| Each URL is `https://github.com/schpet/linear-cli/releases/download/v<version>/linear-<triple>.tar.xz` | An asset from another repository or tag |
| GitHub's digest, the `.sha256` file and the `sha256.sum` line agree | Sums that disagree with each other |
| The downloaded bytes match all three | A changed, truncated or tampered download |
| The tarball holds exactly `linear` and its four documentation files | A different archive under the same name |

Then the script writes the hash to `sources.json` as an SRI hash.
Nix checks that hash again at build time.

CI runs the script again for each pull request and push.
It downloads all three tarballs.
It fails if `sources.json` does not agree with the release at the same version.

## Network and self-update

These findings come from the 3.1.0 source.

- **Network.** The CLI sends GraphQL requests to `https://api.linear.app/graphql`.
  It uploads attachments with a PUT to the signed URL that the `fileUpload`
  mutation returns. Linear chooses that host.
  It downloads attachments and images from the URLs in issues. It adds the API
  key to a download only for `https://uploads.linear.app`.
  It has no telemetry, analytics or update check.
- **Subprocesses.** It runs `git` and `jj` for the branch commands, and `gh`
  for the pull request commands. It runs `xdg-open` or `open` for `--web`.
  It runs `secret-tool` or `security` for the keyring.
- **Self-update.** The binary has no update command. Upstream's shell
  installer adds a separate `linear-update` program (axoupdater).
  This flake does not package the `-update` assets.
  The installed version changes only when you update your flake lock.

## Pinning

Each release has the tag `v<version>`, which is upstream's own tag.
For example, `github:danielbodart/linear-cli/v3.1.0` pins 3.1.0.

The flake tracks stable releases only.
It does not package pre-releases such as `4.0.0-alpha.5`.

Updates to this repository do not change a pinned tag.
`nix flake update` is the only thing that changes your version.

## Update cadence

- **Hourly** (`upstream.yml`, minute 17): the job reads upstream's latest stable
  release. If the version changed, it does these steps:
  1. It writes a new `sources.json`.
  2. It builds the package and runs `linear --version` on all three systems.
  3. If all three pass, it commits to `trunk`, tags `v<version>` and makes a GitHub release.

  The job pushes to `trunk` directly. A pull request made with the default
  token does not start workflows, so an auto-merged one would land without a build.
- **Weekly**, Sunday 21:23 UTC (`update.yml`): the job updates `flake.lock`.
  It builds and runs the package in the same way before it lands.
  This is not a release, so it gets no tag.
- If the hourly job fails, it opens an issue with the label `auto-failure`.
  It adds a comment for each later failure. The first green run closes the issue.

## Binary cache

CI pushes all three systems to `https://danielbodart.cachix.org`.

The flake offers the cache through `nixConfig`.
Nix uses it only for a trusted user.
On NixOS, put the cache in your own configuration:

```nix
nix.settings = {
  substituters = [ "https://danielbodart.cachix.org" ];
  trusted-public-keys = [
    "danielbodart.cachix.org-1:751qv4GxLFJCThWMEw1WL6kUqY0DpF6oqPqsLKnnEwU="
  ];
};
```

A local build is also fast. It downloads a 5 MB tarball and patches one file.
It does not compile anything.

## What is packaged

- `bin/linear`: the binary from the tarball.
  - On Linux, `autoPatchelfHook` sets its ELF interpreter and finds `libgcc_s`.
  - On Linux, a wrapper adds `secret-tool` from libsecret to the end of PATH.
- Completions for bash, fish and zsh. The binary makes them at build time.
- `share/doc/linear-cli`: upstream's README, CHANGELOG, LICENSE and
  THIRD_PARTY_LICENSES.

The build runs `linear --version` as its install check.
That needs no network and no login.

## Development

```bash
nix develop                   # curl, jq, tar, xz, shellcheck, nixfmt
nix flake check               # build the package, run shellcheck, check the pin
./scripts/update.sh           # write sources.json again (downloads all three tarballs)
./scripts/update.sh --check   # exit non-zero if a newer stable release exists
./scripts/update.sh --force   # download and write again, also when current
```

## License

The packaging in this repository is MIT.
The Linear CLI is ISC, copyright its authors.
This repository does not redistribute upstream's binaries.
It records where to get them and their hashes.
