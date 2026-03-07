#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION_FILE="${VERSION_FILE:-$ROOT_DIR/VERSION}"
BUMP_KIND="${1:-}"

usage() {
  cat <<'EOF' >&2
usage: ./Scripts/bump-version.sh <patch|minor|major>
EOF
  exit 1
}

if [[ -z "$BUMP_KIND" ]]; then
  usage
fi

if [[ ! -f "$VERSION_FILE" ]]; then
  echo "error: missing version file: $VERSION_FILE" >&2
  exit 1
fi

CURRENT_VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"

if [[ ! "$CURRENT_VERSION" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
  echo "error: VERSION must use semantic versioning major.minor.patch: $CURRENT_VERSION" >&2
  exit 1
fi

major="${BASH_REMATCH[1]}"
minor="${BASH_REMATCH[2]}"
patch="${BASH_REMATCH[3]}"

case "$BUMP_KIND" in
  patch)
    patch=$((patch + 1))
    ;;
  minor)
    minor=$((minor + 1))
    patch=0
    ;;
  major)
    major=$((major + 1))
    minor=0
    patch=0
    ;;
  *)
    usage
    ;;
esac

NEXT_VERSION="${major}.${minor}.${patch}"
printf '%s\n' "$NEXT_VERSION" > "$VERSION_FILE"

echo "Bumped version: $CURRENT_VERSION -> $NEXT_VERSION"
