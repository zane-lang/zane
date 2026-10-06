#!/bin/sh
# Install the CLI from a GitHub Release. The compiler is installed separately.
set -eu

fail() { printf 'zane: %s\n' "$*" >&2; exit 1; }

main() {
    [ "$#" -le 1 ] || fail 'usage: install.sh [vMAJOR.MINOR[.PATCH]]'
    version=${1:-latest}
    install_dir=${ZANE_INSTALL_DIR:-"$HOME/.local/bin"}
    repo=https://github.com/zane-lang/zane

    case "$(uname -s)/$(uname -m)" in
        Linux/x86_64) asset=zane-linux-x86_64 ;;
        Darwin/arm64|Darwin/aarch64) asset=zane-macos-arm64 ;;
        *) fail 'supported platforms: Linux x86_64 and macOS arm64; use install.ps1 on Windows x86_64' ;;
    esac
    command -v curl >/dev/null 2>&1 || fail 'curl is required'
    if command -v sha256sum >/dev/null 2>&1; then
        hasher=sha256sum
    elif command -v shasum >/dev/null 2>&1; then
        hasher=shasum
    else
        fail 'sha256sum or shasum is required'
    fi

    if [ "$version" = latest ]; then
        # Resolve once so the binary and checksum always come from the same tag.
        url=$(curl -fsSL --proto '=https' --proto-redir '=https' \
            -o /dev/null -w '%{url_effective}' "$repo/releases/latest") \
            || fail 'cannot find the latest release; check your connection and whether a release has been published'
        case "$url" in
            "$repo/releases/tag/"*) version=${url##*/} ;;
            *) fail 'GitHub did not return a release tag' ;;
        esac
    fi
    case "$version" in *[!v0-9.]*) fail 'use a version such as v0.0 or v0.1.0' ;; esac
    printf '%s\n' "$version" | LC_ALL=C grep -Eq '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(\.(0|[1-9][0-9]*))?$' \
        || fail 'use a version such as v0.0 or v0.1.0'

    temp_dir=$(mktemp -d)
    staged=
    trap 'rm -rf "$temp_dir"; if [ -n "$staged" ]; then rm -f "$staged"; fi' 0
    trap 'exit 1' HUP INT TERM
    base="$repo/releases/download/$version"
    printf 'Downloading zane %s (%s)\n' "$version" "$asset"
    curl -fsSL --proto '=https' --proto-redir '=https' "$base/$asset" -o "$temp_dir/zane" \
        || fail 'cannot download the CLI'
    curl -fsSL --proto '=https' --proto-redir '=https' "$base/SHA256SUMS" -o "$temp_dir/SHA256SUMS" \
        || fail 'cannot download release checksums'
    expected=$(awk -v name="$asset" '$2 == name { print $1 }' "$temp_dir/SHA256SUMS")
    printf '%s\n' "$expected" | LC_ALL=C grep -Eq '^[0-9a-f]{64}$' \
        || fail 'the release has no valid checksum for this binary'
    if [ "$hasher" = sha256sum ]; then
        actual=$(sha256sum "$temp_dir/zane" | cut -d ' ' -f 1)
    else
        actual=$(shasum -a 256 "$temp_dir/zane" | cut -d ' ' -f 1)
    fi
    [ "$actual" = "$expected" ] || fail 'checksum mismatch; nothing was installed'

    mkdir -p "$install_dir"
    [ ! -d "$install_dir/zane" ] || fail "$install_dir/zane is a directory"
    # Stage beside the destination so replacing an existing CLI is atomic.
    staged=$(mktemp "$install_dir/.zane.XXXXXX")
    cat "$temp_dir/zane" > "$staged"
    chmod 755 "$staged"
    mv -f "$staged" "$install_dir/zane"
    staged=
    printf 'Installed zane %s at %s/zane\n' "$version" "$install_dir"
    case ":$PATH:" in
        *":$install_dir:"*) ;;
        *) printf 'Add this directory to your PATH: %s\n' "$install_dir" ;;
    esac
    printf 'The CLI also needs a compiler: put zanec on PATH or set ZANE_COMPILER.\n'
}

# Keep execution inside a function: piping a truncated download cannot run a
# partially downloaded installer.
main "$@"
