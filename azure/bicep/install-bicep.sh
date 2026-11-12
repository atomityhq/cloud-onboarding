#!/usr/bin/env bash
#
# Installs the Bicep compiler version pinned in BICEP_VERSION, and checks the download against
# the checksum pinned in BICEP_SHA256. The ARM templates are compiled with exactly this version,
# so CI, the release job and local builds all use the same compiler.
#
#   bash install-bicep.sh                         installs to ~/.local/bin
#   BICEP_INSTALL_DIR=/some/dir bash install-bicep.sh
#
# The download is about 80 MB. It shows progress in a terminal, and it gives up with a clear
# message if the speed stays below 10 KB/s for 30 seconds (BICEP_STALL_SECONDS changes that).
#
# If the download is slow or blocked, download the file yourself from
#   https://github.com/Azure/bicep/releases/tag/v<BICEP_VERSION>
# (the asset for your system: bicep-linux-x64, bicep-linux-arm64, bicep-osx-x64 or
# bicep-osx-arm64) and install that file. It is still checked against the pinned checksum:
#
#   BICEP_FILE=~/Downloads/bicep-linux-x64 bash install-bicep.sh
#
# Afterwards make sure the install directory is on your PATH.

set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
VERSION=$(tr -d '[:space:]' < "$HERE/BICEP_VERSION")
DIR=${BICEP_INSTALL_DIR:-$HOME/.local/bin}
BASE_URL=${BICEP_RELEASES_BASE:-https://github.com/Azure/bicep/releases/download}
STALL=${BICEP_STALL_SECONDS:-30}
FILE=${BICEP_FILE:-}

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "$*"; }

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "BICEP_VERSION must look like 0.33.93, got '$VERSION'."
[[ "$STALL" =~ ^[0-9]+$ && "$STALL" -ge 1 ]] || die "BICEP_STALL_SECONDS must be a whole number of seconds, got '$STALL'."

case "$(uname -s)-$(uname -m)" in
  Linux-x86_64)                asset=bicep-linux-x64 ;;
  Linux-aarch64|Linux-arm64)   asset=bicep-linux-arm64 ;;
  Darwin-x86_64)               asset=bicep-osx-x64 ;;
  Darwin-arm64)                asset=bicep-osx-arm64 ;;
  *) die "No Bicep build for $(uname -s) $(uname -m)." ;;
esac

want=$(awk -v a="$asset" '$2 == a { print $1 }' "$HERE/BICEP_SHA256")
[[ "$want" =~ ^[0-9a-f]{64}$ ]] || die "BICEP_SHA256 has no checksum for $asset."

sha256() {
  if command -v sha256sum > /dev/null 2>&1; then sha256sum "$1" | awk '{ print $1 }'
  else shasum -a 256 "$1" | awk '{ print $1 }'; fi
}

# Runs the binary and checks its version. Explains the usual reason a .NET binary cannot start.
verify_installed() {
  local out
  if ! out=$("$1" --version 2>&1); then
    if grep -qi 'icu' <<< "$out"; then
      die "The Bicep binary was downloaded and verified, but it cannot start because the ICU library is missing.
Install it (Arch and CachyOS: sudo pacman -S icu. Debian and Ubuntu: sudo apt install libicu-dev) or run
with the invariant mode, in the same shell you use for build.py:
  export DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1"
    fi
    die "The Bicep binary does not run: $out"
  fi
  grep -q "version $VERSION " <<< "$out" || die "The installed compiler is not version $VERSION: $out"
}

if [[ -x "$DIR/bicep" ]] && "$DIR/bicep" --version 2> /dev/null | grep -q "version $VERSION "; then
  info "Bicep $VERSION is already installed in $DIR."
  exit 0
fi

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

if [[ -n "$FILE" ]]; then
  [[ -f "$FILE" ]] || die "BICEP_FILE '$FILE' does not exist."
  info "Installing Bicep $VERSION from $FILE"
  cp "$FILE" "$tmp"
else
  url="$BASE_URL/v$VERSION/$asset"
  info "Downloading Bicep $VERSION ($asset, about 80 MB) from"
  info "  $url"
  progress=(-sS)
  if [[ -t 2 ]]; then progress=(--progress-bar); fi
  if ! curl -fL "${progress[@]}" --connect-timeout 20 --retry 1 \
        --speed-limit 10240 --speed-time "$STALL" -o "$tmp" "$url"; then
    die "The download failed, or it stayed below 10 KB/s for $STALL seconds.
Check your connection, or download the file yourself from
  https://github.com/Azure/bicep/releases/tag/v$VERSION
(the asset is named $asset) and install it with:
  BICEP_FILE=/path/to/$asset bash $0"
  fi
fi

got=$(sha256 "$tmp")
[[ "$got" == "$want" ]] || die "Checksum mismatch for $asset. Expected $want but got $got. Nothing was installed.
Make sure the file is $asset for Bicep v$VERSION, and that the download finished."

mkdir -p "$DIR"
chmod +x "$tmp"
mv "$tmp" "$DIR/bicep"
trap - EXIT
verify_installed "$DIR/bicep"
echo "Installed Bicep $VERSION in $DIR. Make sure $DIR is on your PATH."