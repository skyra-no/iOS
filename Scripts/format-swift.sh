#!/bin/bash
# Used by contributors and CI to apply/check the same pinned Swift layout rules without a global install.
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ $# -gt 1 || ($# -eq 1 && "$1" != "--lint") ]]; then
  echo "Usage: bash Scripts/format-swift.sh [--lint]" >&2
  exit 2
fi

# Keep local formatting and CI on the same release, independent of Xcode.
version=0.63.0
checksum=28c7802e11fa5ae113d903066439c6bb1be20a8ac1ad9709c42616a7e273fb0f
asset=swiftformat.zip
executable=swiftformat
case "$(uname -s)-$(uname -m)" in
  Darwin-*) ;;
  Linux-x86_64)
    asset=swiftformat_linux.zip
    executable=swiftformat_linux
    checksum=b4a3cbb8c852a0baaf9adf853e221ff1dabf921a3d8957a602e0bda3af8470f1
    ;;
  *) echo "Unsupported formatter platform" >&2; exit 1 ;;
esac
directory="$PWD/.build/tools/swiftformat/$version/$(uname -s)-$(uname -m)"
binary="$directory/$executable"

if [[ ! -x "$binary" ]]; then
  mkdir -p "$directory"
  archive=$(mktemp "$directory/download.XXXXXX")
  trap 'rm -f "$archive"' EXIT
  curl --fail --location --silent --show-error \
    "https://github.com/nicklockwood/SwiftFormat/releases/download/$version/$asset" \
    --output "$archive"
  if [[ "$(uname -s)" == Linux ]]; then
    echo "$checksum  $archive" | sha256sum --check --status
  else
    echo "$checksum  $archive" | shasum -a 256 --check --status
  fi
  unzip -oq "$archive" -d "$directory"
  chmod +x "$binary"
  rm -f "$archive"
  trap - EXIT
fi

exec "$binary" Package.swift Sources Tests --config .swiftformat --cache ignore "$@"
