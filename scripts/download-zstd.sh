#!/usr/bin/env bash
set -euo pipefail

# Installs the zstd binary for macOS arm64 into Resources/.
# Usage: ./scripts/download-zstd.sh [version]

ZSTD_VERSION="${1:-1.5.7}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="${ROOT_DIR}/Resources"
OUTPUT_PATH="${OUTPUT_DIR}/zstd"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TMPDIR}"' EXIT

mkdir -p "${OUTPUT_DIR}"

if [[ -x "${OUTPUT_PATH}" ]]; then
  EXISTING="$("${OUTPUT_PATH}" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
  if [[ "${EXISTING}" == "${ZSTD_VERSION}" ]]; then
    echo "zstd already exists at ${OUTPUT_PATH} (version: ${EXISTING})"
    exit 0
  fi
fi

if [[ -n "${ZSTD_SOURCE:-}" ]]; then
  rm -f "${OUTPUT_PATH}"
  install -m 755 "${ZSTD_SOURCE}" "${OUTPUT_PATH}"
  if "${OUTPUT_PATH}" --version >/dev/null 2>&1; then
    echo "Copied zstd from ${ZSTD_SOURCE} to ${OUTPUT_PATH}"
    exit 0
  fi
  echo "ERROR: copied zstd does not run from ${OUTPUT_PATH}" >&2
  exit 1
fi

URL="https://github.com/facebook/zstd/releases/download/v${ZSTD_VERSION}/zstd-${ZSTD_VERSION}.tar.gz"
ARCHIVE="${TMPDIR}/zstd.tar.gz"
SOURCE_DIR="${TMPDIR}/zstd-${ZSTD_VERSION}"

echo "Downloading zstd v${ZSTD_VERSION} source..."
curl -fsSL "${URL}" -o "${ARCHIVE}"
tar -xzf "${ARCHIVE}" -C "${TMPDIR}"

echo "Building zstd v${ZSTD_VERSION}..."
make -C "${SOURCE_DIR}" -j"$(sysctl -n hw.ncpu)" zstd-release

if [[ ! -x "${SOURCE_DIR}/programs/zstd" ]]; then
  echo "ERROR: zstd binary not found after build" >&2
  exit 1
fi

rm -f "${OUTPUT_PATH}"
install -m 755 "${SOURCE_DIR}/programs/zstd" "${OUTPUT_PATH}"
echo "zstd v${ZSTD_VERSION} installed to ${OUTPUT_PATH}"
