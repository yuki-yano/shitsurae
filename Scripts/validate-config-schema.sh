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

npx --yes ajv-cli@5.0.0 compile -s "$schema" --spec=draft2020

# Preserve each sample path in diagnostics while validating all converted
# samples in one invocation.
for sample in samples/xdg-config-home/shitsurae/*.yaml samples/xdg-config-home/shitsurae/virtual/*.yaml; do
  json="$workdir/${sample%.yaml}.json"
  mkdir -p "$(dirname "$json")"
  gojq --yaml-input . "$sample" > "$json"
  echo "sample: $sample"
done

npx --yes ajv-cli@5.0.0 validate -s "$schema" -d "$workdir/samples/**/*.json" --spec=draft2020
