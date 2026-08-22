#!/usr/bin/env bash
#
# TidyMac installer.
#
#   curl -fsSL https://raw.githubusercontent.com/orbitextechlab/TidyMac/main/install.sh | bash
#
# Downloads the latest release, checks it against the published SHA-256 sum,
# installs it into /Applications, and clears the download quarantine flag that
# would otherwise stop macOS from opening an app that is not notarized.
#
# Environment overrides:
#   TIDYMAC_VERSION   install a specific tag (e.g. v0.1.0) instead of the latest
#   TIDYMAC_PREFIX    install somewhere other than /Applications

set -euo pipefail

REPO="orbitextechlab/TidyMac"
PREFIX="${TIDYMAC_PREFIX:-/Applications}"
APP_NAME="TidyMac.app"
TARGET="$PREFIX/$APP_NAME"

bold=$'\033[1m'; dim=$'\033[2m'; red=$'\033[31m'; green=$'\033[32m'; off=$'\033[0m'
say()  { printf '%s\n' "$*"; }
step() { printf '%s==>%s %s\n' "$bold" "$off" "$*"; }
die()  { printf '%serror:%s %s\n' "$red" "$off" "$*" >&2; exit 1; }

# ---------------------------------------------------------------- preflight

[ "$(uname -s)" = "Darwin" ] || die "TidyMac is a macOS app; this is $(uname -s)."

macos_major=$(sw_vers -productVersion | cut -d. -f1)
[ "$macos_major" -ge 14 ] 2>/dev/null || \
  die "TidyMac needs macOS 14 or later; this is $(sw_vers -productVersion)."

command -v curl >/dev/null || die "curl is required."

if pgrep -xq TidyMac; then
  die "TidyMac is running. Quit it first, then run this again."
fi

# ---------------------------------------------------------------- resolve release

if [ -n "${TIDYMAC_VERSION:-}" ]; then
  api="https://api.github.com/repos/$REPO/releases/tags/$TIDYMAC_VERSION"
else
  api="https://api.github.com/repos/$REPO/releases/latest"
fi

step "Looking up the release"
release=$(curl -fsSL "$api") || die "could not reach the GitHub API."

tag=$(printf '%s' "$release" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)
[ -n "$tag" ] || die "no release found${TIDYMAC_VERSION:+ for $TIDYMAC_VERSION}."

# One URL per line, then pick the two assets we need by suffix.
urls=$(printf '%s' "$release" | grep -o '"browser_download_url": *"[^"]*"' \
       | sed 's/.*"\(https[^"]*\)"/\1/')
zip_url=$(printf '%s\n' "$urls" | grep '\.zip$' | head -1)
sums_url=$(printf '%s\n' "$urls" | grep 'SHA256SUMS\.txt$' | head -1)
[ -n "$zip_url" ] || die "release $tag has no .zip asset."

say "    $tag"

# ---------------------------------------------------------------- download

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

zip_name=$(basename "$zip_url")
step "Downloading $zip_name"
curl -fsSL --progress-bar "$zip_url" -o "$tmp/$zip_name" || die "download failed."

if [ -n "$sums_url" ]; then
  step "Verifying checksum"
  curl -fsSL "$sums_url" -o "$tmp/SHA256SUMS.txt" || die "could not fetch SHA256SUMS.txt."
  # The sums file covers the dmg too; check only what we downloaded.
  ( cd "$tmp" && grep " $zip_name\$" SHA256SUMS.txt | shasum -a 256 -c --status - ) \
    || die "checksum mismatch — refusing to install $zip_name."
  say "    ${green}ok${off}"
else
  say "    ${dim}no SHA256SUMS.txt in this release, skipping verification${off}"
fi

# ---------------------------------------------------------------- install

step "Unpacking"
ditto -x -k "$tmp/$zip_name" "$tmp/unpacked" || die "could not unpack $zip_name."
[ -d "$tmp/unpacked/$APP_NAME" ] || die "$APP_NAME not found inside $zip_name."

# A custom prefix may not exist yet; an absent directory is not the same thing
# as one that needs root to write to.
if [ ! -d "$PREFIX" ]; then
  mkdir -p "$PREFIX" 2>/dev/null || die "$PREFIX does not exist and could not be created."
fi

# /Applications is group-writable for admins on a normal Mac, so sudo is only
# needed on machines where that has been changed.
sudo=""
if [ -e "$TARGET" ] && [ ! -w "$TARGET" ]; then sudo="sudo"; fi
if [ ! -w "$PREFIX" ]; then sudo="sudo"; fi
[ -n "$sudo" ] && say "    ${dim}$PREFIX needs elevated rights; you may be asked for your password${off}"

step "Installing to $PREFIX"
$sudo rm -rf "$TARGET"
$sudo ditto "$tmp/unpacked/$APP_NAME" "$TARGET" || die "could not install into $PREFIX."

# Release builds are ad-hoc signed rather than notarized, so macOS would report
# the freshly downloaded app as damaged until the quarantine flag is cleared.
step "Clearing the download quarantine flag"
$sudo xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null || true

version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
          "$TARGET/Contents/Info.plist" 2>/dev/null || echo "?")

say ""
say "${green}TidyMac $version installed${off} at $TARGET"
say ""
say "Open it with:  ${bold}open -a TidyMac${off}"
say ""
say "${dim}TidyMac is not notarized by Apple. This installer cleared the quarantine"
say "flag on your behalf, which is what lets macOS open it. If you would rather"
say "not take that on trust, build from source: https://github.com/$REPO${off}"
