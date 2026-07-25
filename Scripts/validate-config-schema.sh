#!/usr/bin/env bash
# Validates the JSON Schema itself and every shipped sample config against it
# with ajv (draft 2020-12). Samples are YAML; they are converted to JSON with
# gojq before validation.
#
# Requirements: npx (ajv-cli is fetched on demand), gojq.
set -euo pipefail

cd "$(dirname "$0")/.."

schema="schemas/shitsurae-config.schema.json"
workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

npx --yes ajv-cli compile -s "$schema" --spec=draft2020

status=0
for sample in samples/xdg-config-home/shitsurae/*.yaml samples/xdg-config-home/shitsurae/virtual/*.yaml; do
  json="$workdir/$(basename "$sample").json"
  gojq --yaml-input . "$sample" > "$json"
  if npx --yes ajv-cli validate -s "$schema" -d "$json" --spec=draft2020 > /dev/null 2>&1; then
    echo "valid: $sample"
  else
    echo "INVALID: $sample" >&2
    npx --yes ajv-cli validate -s "$schema" -d "$json" --spec=draft2020 || true
    status=1
  fi
done
exit $status
