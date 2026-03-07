#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_BUNDLE_PATH="${APP_BUNDLE_PATH:-${ROOT_DIR}/dist/Shitsurae.app}"
OUTPUT_NAME="${OUTPUT_NAME:-Shitsurae.app.tar.gz}"
OUTPUT_PATH="${OUTPUT_PATH:-${ROOT_DIR}/${OUTPUT_NAME}}"

"${ROOT_DIR}/Scripts/build-app-bundle.sh"

if [[ ! -d "${APP_BUNDLE_PATH}" ]]; then
  echo "error: app bundle not found: ${APP_BUNDLE_PATH}" >&2
  exit 1
fi

rm -f "${OUTPUT_PATH}"
tar -C "$(dirname "${APP_BUNDLE_PATH}")" -czf "${OUTPUT_PATH}" "$(basename "${APP_BUNDLE_PATH}")"

echo "Created release asset: ${OUTPUT_PATH}"
shasum -a 256 "${OUTPUT_PATH}"
