#!/usr/bin/env bash
# Downloads the oras binary for macOS arm64 from GitHub releases.
# Usage: ./scripts/download-oras.sh [version]
# Output: places the binary at Resources/oras

set -euo pipefail

ORAS_VERSION="${1:-1.3.2}"
PLATFORM="darwin"
ARCH="arm64"
TARBALL="oras_${ORAS_VERSION}_${PLATFORM}_${ARCH}.tar.gz"
URL="https://github.com/oras-project/oras/releases/download/v${ORAS_VERSION}/${TARBALL}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
OUTPUT_DIR="${PROJECT_ROOT}/Resources"
OUTPUT_PATH="${OUTPUT_DIR}/oras"

if [[ -x "$OUTPUT_PATH" ]]; then
  EXISTING=$("$OUTPUT_PATH" version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
  if [[ "$EXISTING" == "$ORAS_VERSION" ]]; then
    echo "oras already exists at ${OUTPUT_PATH} (version: ${EXISTING})"
    exit 0
  fi
fi

mkdir -p "$OUTPUT_DIR"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

echo "Downloading oras v${ORAS_VERSION} for ${PLATFORM}/${ARCH}..."
curl -fSL --retry 3 -o "${TMPDIR}/${TARBALL}" "$URL"

echo "Extracting..."
tar -xzf "${TMPDIR}/${TARBALL}" -C "$TMPDIR"

if [[ ! -f "${TMPDIR}/oras" ]]; then
  echo "ERROR: oras binary not found in archive" >&2
  exit 1
fi

rm -f "$OUTPUT_PATH"
install -m 755 "${TMPDIR}/oras" "$OUTPUT_PATH"

echo "oras v${ORAS_VERSION} installed to ${OUTPUT_PATH}"
"$OUTPUT_PATH" version
