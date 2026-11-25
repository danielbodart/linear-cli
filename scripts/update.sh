#!/usr/bin/env bash
#
# Regenerate sources.json from the newest stable GitHub release of
# schpet/linear-cli.
#
# Be clear about what this does and does not establish. Upstream publishes the
# CLI with cargo-dist, with no PGP signature, no detached signature and no
# GitHub artifact attestation. What a release carries is:
#
#   * the tarballs, one per target;
#   * a .sha256 file beside each tarball, and a sha256.sum over all of them,
#     written by the same release job that built the tarballs;
#   * dist-manifest.json, cargo-dist's description of the release.
#
# GitHub adds one thing the publisher does not write: the `digest` of each
# asset in the releases API, which GitHub computes itself when the asset is
# uploaded. So the trust chain here is:
#
#   TLS to GitHub  ->  the release's own sums and GitHub's digest  ->  the bytes
#
# which is weaker than claude-desktop's chain to a pinned PGP key. What this
# script adds is a cross-check rather than a signature:
#
#   * the release must be the latest stable one: not a draft, not a
#     pre-release, tagged v<major>.<minor>.<patch>, and not older than the pin;
#   * dist-manifest.json must name the same tag, and not as a pre-release;
#   * each download URL must be this repository's, under that tag;
#   * GitHub's digest, the tarball's .sha256 and its line in sha256.sum must
#     all agree;
#   * each tarball is downloaded here and hashed, and must match all three;
#   * each tarball must hold exactly the files this package expects.
#
# Only then is the hash written down, as the SRI form Nix checks at build time.
# A compromise of upstream's own release job, or of the maintainer's GitHub
# account, is out of reach of any of this.
#
set -euo pipefail

readonly REPO="schpet/linear-cli"
readonly API="https://api.github.com/repos/$REPO"
readonly DOWNLOAD="https://github.com/$REPO/releases/download"

# Nix system -> the target triple in upstream's asset names.
readonly PLATFORMS=(
  "x86_64-linux:x86_64-unknown-linux-gnu"
  "aarch64-linux:aarch64-unknown-linux-gnu"
  "x86_64-darwin:x86_64-apple-darwin"
  "aarch64-darwin:aarch64-apple-darwin"
)

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT
readonly SOURCES_JSON="$ROOT/sources.json"

log() { printf '\033[0;32m==>\033[0m %s\n' "$*" >&2; }
die() { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

require_tools() {
  local missing=()
  for tool in curl jq nix sha256sum sort tar xz; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
  done
  [ ${#missing[@]} -eq 0 ] || die "missing required tools: ${missing[*]} (try: nix develop)"
}

fetch() {
  curl --fail --silent --show-error --location --retry 3 --retry-delay 2 --max-time 120 "$1"
}

# The releases API, with a token when there is one: unauthenticated calls are
# limited to 60 an hour per address, which a shared CI runner can exhaust.
api() {
  local auth=()
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    auth=(--header "Authorization: Bearer $GITHUB_TOKEN")
  fi
  curl --fail --silent --show-error --location --retry 3 --retry-delay 2 --max-time 60 \
    --header "Accept: application/vnd.github+json" "${auth[@]}" "$API/$1"
}

main() {
  local check_only=false force=false
  while [ $# -gt 0 ]; do
    case "$1" in
      --check) check_only=true; shift ;;
      --force) force=true; shift ;;
      --help)
        cat <<'USAGE'
Usage: scripts/update.sh [--check] [--force]

Rewrites sources.json from the newest stable release of schpet/linear-cli,
after downloading each tarball to confirm it matches GitHub's digest, its
.sha256 file and its line in the release's sha256.sum.

  --check   Report whether an update is available and exit non-zero if one
            is, without downloading or writing anything.
  --force   Download, verify and rewrite sources.json even when the pinned
            version is already the newest one, so that its contents can be
            compared against the release.
USAGE
        exit 0 ;;
      *) die "unknown argument: $1" ;;
    esac
  done

  require_tools

  local workdir
  workdir="$(mktemp -d)"
  # Expanded now, not at trap time: $workdir is a local that is out of scope
  # by the time the EXIT trap runs.
  # shellcheck disable=SC2064
  trap "rm -rf '$workdir'" EXIT

  # /releases/latest is GitHub's newest release that is neither a draft nor a
  # pre-release, which is what keeps 4.0.0-alpha.N and the like out. The
  # checks below say so again rather than trusting that.
  log "fetching $API/releases/latest"
  api releases/latest >"$workdir/release.json"

  local tag version
  tag="$(jq -er '.tag_name | strings' "$workdir/release.json")" || die "the release has no tag"
  jq -e '.draft == false and .prerelease == false' "$workdir/release.json" >/dev/null ||
    die "$tag: the latest release is a draft or a pre-release"
  [[ "$tag" =~ ^v([0-9]+\.[0-9]+\.[0-9]+)$ ]] ||
    die "$tag: the tag is not v<major>.<minor>.<patch>"
  version="${BASH_REMATCH[1]}"

  local current
  current="$(jq -r '.version' "$SOURCES_JSON" 2>/dev/null || echo none)"
  log "current: $current, latest: $version"

  # A release can be deleted, or a later one marked latest by hand, which
  # would make an older version the latest. That is never an update.
  if [ "$current" != none ] && [ "$current" != "$version" ] &&
    [ "$(printf '%s\n%s\n' "$current" "$version" | sort -V | tail -n1)" = "$current" ]; then
    die "the latest release, $version, is older than the pinned $current"
  fi

  if [ "$current" = "$version" ] && [ "$force" = false ]; then
    log "already up to date"
    exit 0
  fi

  if [ "$check_only" = true ]; then
    log "update available: $current -> $version"
    exit 1
  fi

  # cargo-dist's own account of the release has to agree with GitHub's.
  log "fetching dist-manifest.json"
  fetch "$DOWNLOAD/$tag/dist-manifest.json" >"$workdir/dist-manifest.json"
  jq -e --arg tag "$tag" \
    '.announcement_tag == $tag and .announcement_is_prerelease == false' \
    "$workdir/dist-manifest.json" >/dev/null ||
    die "$tag: dist-manifest.json does not describe $tag as a stable release"

  log "fetching sha256.sum"
  fetch "$DOWNLOAD/$tag/sha256.sum" >"$workdir/sha256.sum"

  local json entry system triple name url digest sidecar summed actual size sri expected listing
  json="$(jq -n --arg version "$version" '{version: $version, sources: {}}')"
  for entry in "${PLATFORMS[@]}"; do
    IFS=: read -r system triple <<<"$entry"
    name="linear-$triple.tar.xz"

    # The URL is built here, not taken from the API, and must be the one the
    # API gives. Matching the whole string is what stops an asset that points
    # at another repository or another tag getting through.
    url="$DOWNLOAD/$tag/$name"
    jq -e --arg name "$name" --arg url "$url" \
      '[.assets[] | select(.name == $name)] | length == 1 and .[0].browser_download_url == $url' \
      "$workdir/release.json" >/dev/null ||
      die "$system: the release has no single asset $name at $url"

    # Computed by GitHub on upload, so it is not the publisher's word.
    digest="$(jq -er --arg name "$name" '.assets[] | select(.name == $name) | .digest | strings' \
      "$workdir/release.json")" || die "$system: GitHub gives no digest for $name"
    [[ "$digest" =~ ^sha256:([0-9a-f]{64})$ ]] || die "$system: digest is not sha256: $digest"
    expected="${BASH_REMATCH[1]}"

    sidecar="$(fetch "$url.sha256" | cut -d' ' -f1)"
    [ "$sidecar" = "$expected" ] ||
      die "$system: $name.sha256 says $sidecar but GitHub's digest is $expected"

    summed="$(awk -v n="*$name" '$2 == n { print $1 }' "$workdir/sha256.sum")"
    [ "$summed" = "$expected" ] ||
      die "$system: sha256.sum says '$summed' for $name but GitHub's digest is $expected"

    log "downloading $url"
    fetch "$url" >"$workdir/$name"
    actual="$(sha256sum "$workdir/$name" | cut -d' ' -f1)"
    [ "$actual" = "$expected" ] ||
      die "$system: the tarball hashes to $actual but its sums say $expected"
    log "$system: sha256 matches GitHub's digest, $name.sha256 and sha256.sum"

    # A tarball with anything else in it is not the one packaged here.
    listing="$(tar -tJf "$workdir/$name" | sort)"
    [ "$listing" = "$(printf '%s\n' \
      "linear-$triple/" \
      "linear-$triple/CHANGELOG.md" \
      "linear-$triple/LICENSE" \
      "linear-$triple/README.md" \
      "linear-$triple/THIRD_PARTY_LICENSES.md" \
      "linear-$triple/linear" | sort)" ] ||
      die "$system: $name does not hold exactly the expected files: $listing"

    size="$(wc -c <"$workdir/$name" | tr -d ' ')"
    sri="$(nix hash convert --hash-algo sha256 --to sri "$actual")"
    json="$(jq \
      --arg system "$system" \
      --arg url "$url" \
      --arg hash "$sri" \
      --argjson size "$size" \
      '.sources[$system] = {url: $url, hash: $hash, size: $size}' \
      <<<"$json")"
    rm -f "$workdir/$name"
  done

  printf '%s\n' "$json" >"$SOURCES_JSON"
  log "wrote $SOURCES_JSON at $version"
}

main "$@"
