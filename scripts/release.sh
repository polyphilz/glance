#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION_FILE="${ROOT_DIR}/VERSION"

usage() {
    cat <<'EOF'
Usage:
  ./scripts/release.sh patch
  ./scripts/release.sh minor
  ./scripts/release.sh major
  ./scripts/release.sh X.Y.Z

Bumps the repo version in VERSION and prints the next release commands.
EOF
}

die() {
    echo "error: $*" >&2
    exit 1
}

parse_version() {
    local version="$1"

    if [[ ! "$version" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
        return 1
    fi

    printf '%s %s %s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
}

bump_version() {
    local current="$1"
    local mode="$2"
    local major=""
    local minor=""
    local patch=""

    read -r major minor patch < <(parse_version "$current") || die "invalid current version: ${current}"

    case "$mode" in
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
            die "invalid bump mode: ${mode}"
            ;;
    esac

    printf '%s.%s.%s\n' "$major" "$minor" "$patch"
}

[ $# -eq 1 ] || {
    usage
    exit 1
}

[ -f "$VERSION_FILE" ] || die "missing VERSION file at ${VERSION_FILE}"

CURRENT_VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
TARGET_INPUT="$1"

case "$TARGET_INPUT" in
    patch|minor|major)
        NEXT_VERSION="$(bump_version "$CURRENT_VERSION" "$TARGET_INPUT")"
        ;;
    *)
        parse_version "$TARGET_INPUT" >/dev/null || die "version must be X.Y.Z"
        NEXT_VERSION="$TARGET_INPUT"
        ;;
esac

if [ "$NEXT_VERSION" = "$CURRENT_VERSION" ]; then
    echo "VERSION is already ${CURRENT_VERSION}"
    exit 0
fi

if command -v git >/dev/null 2>&1 && git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    if [ -n "$(git -C "$ROOT_DIR" status --short --untracked-files=no)" ]; then
        echo "warning: working tree has tracked changes; review the release commit carefully." >&2
    fi

    if git -C "$ROOT_DIR" rev-parse "v${NEXT_VERSION}" >/dev/null 2>&1; then
        die "tag v${NEXT_VERSION} already exists"
    fi
fi

printf '%s\n' "$NEXT_VERSION" > "$VERSION_FILE"

echo "Updated VERSION: ${CURRENT_VERSION} -> ${NEXT_VERSION}"
echo ""
echo "Next steps:"
echo "  git add VERSION"
echo "  git commit -m \"Release v${NEXT_VERSION}\""
echo "  git push origin main"
echo "  git tag -a v${NEXT_VERSION} -m \"v${NEXT_VERSION}\""
echo "  git push origin v${NEXT_VERSION}"
echo "  gh release create v${NEXT_VERSION} --generate-notes"
