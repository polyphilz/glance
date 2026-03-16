#!/usr/bin/env bash
# Install glance.
#
# Run directly: curl -fsSL https://raw.githubusercontent.com/polyphilz/glance/main/install.sh | bash
# Override the ref with GLANCE_REF=vX.Y.Z or GLANCE_REF=main.
#
# When run from a local checkout as ./install.sh, it keeps the dev-friendly
# symlink install behavior and points ~/.local/bin/glance at that checkout.

set -euo pipefail

GITHUB_REPO="${GLANCE_GITHUB_REPO:-polyphilz/glance}"
TARGET_DIR="${HOME}/.local/bin"
INSTALL_BASE="${HOME}/.local/share/glance"
INSTALL_TMP_DIR=""

cleanup_install_tmp_dir() {
    if [ -n "${INSTALL_TMP_DIR:-}" ]; then
        rm -rf -- "$INSTALL_TMP_DIR"
    fi
}

trap cleanup_install_tmp_dir EXIT

normalize_ref() {
    local ref="$1"

    if [[ "$ref" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        printf 'v%s' "$ref"
    else
        printf '%s' "$ref"
    fi
}

resolve_repo_ref() {
    local latest_url=""
    local latest_ref=""

    if [ -n "${GLANCE_REF:-}" ]; then
        normalize_ref "$GLANCE_REF"
        return 0
    fi

    latest_url="$(curl -fsSL --connect-timeout 5 --max-time 10 -o /dev/null -w '%{url_effective}' "https://github.com/${GITHUB_REPO}/releases/latest" 2>/dev/null || echo "")"
    latest_ref="$(printf '%s' "$latest_url" | sed -nE 's#.*/tag/([^/?]+).*#\1#p')"

    if [ -n "$latest_ref" ]; then
        printf '%s' "$latest_ref"
    else
        printf 'main'
    fi
}

archive_url_for_ref() {
    local ref="$1"

    if [ "$ref" = "main" ]; then
        printf 'https://github.com/%s/archive/refs/heads/main.tar.gz' "$GITHUB_REPO"
    else
        printf 'https://github.com/%s/archive/refs/tags/%s.tar.gz' "$GITHUB_REPO" "$ref"
    fi
}

script_dir() {
    local source="${BASH_SOURCE[0]:-$0}"

    [ -f "$source" ] || return 1
    cd "$(dirname "$source")" && pwd
}

is_local_checkout() {
    local root="$1"

    [ -f "$root/bin/glance" ] &&
    [ -d "$root/lua/glance" ] &&
    [ -f "$root/VERSION" ]
}

install_from_checkout() {
    local root="$1"

    mkdir -p "$TARGET_DIR"
    ln -sf "$root/bin/glance" "$TARGET_DIR/glance"

    echo "Installed glance -> $TARGET_DIR/glance"
    echo "Source: local checkout at $root"
    echo "Make sure $TARGET_DIR is on your PATH."
}

install_from_archive() {
    local repo_ref=""
    local archive_url=""
    local tmp_dir=""
    local unpack_dir=""
    local extracted_dir=""
    local install_dir=""

    repo_ref="$(resolve_repo_ref)"
    archive_url="$(archive_url_for_ref "$repo_ref")"
    tmp_dir="$(mktemp -d)"
    INSTALL_TMP_DIR="$tmp_dir"

    echo "Installing glance from ${repo_ref}..."
    if [ "$repo_ref" = "main" ] && [ -z "${GLANCE_REF:-}" ]; then
        echo "  No GitHub release found yet; falling back to main."
    fi

    curl -fsSL "$archive_url" -o "$tmp_dir/glance.tar.gz"
    unpack_dir="$tmp_dir/unpack"
    mkdir -p "$unpack_dir" "$INSTALL_BASE" "$TARGET_DIR"
    tar -xzf "$tmp_dir/glance.tar.gz" -C "$unpack_dir"

    extracted_dir="$(find "$unpack_dir" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
    install_dir="${INSTALL_BASE}/${repo_ref}"

    [ -n "$extracted_dir" ] || {
        echo "error: failed to locate extracted archive directory" >&2
        exit 1
    }

    rm -rf "$install_dir"
    mv "$extracted_dir" "$install_dir"
    ln -sf "$install_dir/bin/glance" "$TARGET_DIR/glance"

    echo "Installed glance -> $TARGET_DIR/glance"
    echo "Files: $install_dir"
    echo "Make sure $TARGET_DIR is on your PATH."
}

main() {
    local local_root=""

    if local_root="$(script_dir 2>/dev/null)" && is_local_checkout "$local_root"; then
        install_from_checkout "$local_root"
        return 0
    fi

    install_from_archive
}

main "$@"
