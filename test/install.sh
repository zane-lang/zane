#!/usr/bin/env bash
# Offline installer integration tests: the hash and filesystem operations are real.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/bin" "$scratch/fixtures"
export ZANE_INSTALL_DIR="$scratch/install with spaces"
export ZANE_TEST_FIXTURES="$scratch/fixtures"
export ZANE_TEST_OS=Linux ZANE_TEST_ARCH=x86_64 ZANE_TEST_FAILURE=
export ZANE_TEST_LOG="$scratch/requests"

cat > "$scratch/bin/uname" <<'SH'
#!/bin/sh
case "$1" in -s) printf '%s\n' "$ZANE_TEST_OS" ;; -m) printf '%s\n' "$ZANE_TEST_ARCH" ;; esac
SH
cat > "$scratch/bin/curl" <<'SH'
#!/bin/sh
set -eu
out=
url=
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o) out=$2; shift 2 ;;
        --proto|--proto-redir|-w) shift 2 ;;
        -*) shift ;;
        *) url=$1; shift ;;
    esac
done
printf '%s\n' "$url" >> "$ZANE_TEST_LOG"
[ -z "$ZANE_TEST_FAILURE" ] || exit 22
case "$url" in
    https://github.com/zane-lang/zane/releases/latest)
        printf 'https://github.com/zane-lang/zane/releases/tag/v0.0' ;;
    https://github.com/zane-lang/zane/releases/download/v0.0/*)
        cp "$ZANE_TEST_FIXTURES/${url##*/}" "$out" ;;
    *) exit 22 ;;
esac
SH
chmod +x "$scratch/bin/uname" "$scratch/bin/curl"
export PATH="$scratch/bin:$PATH"
printf '#!/bin/sh\nprintf "zane v0.0\\n"\n' > "$scratch/fixtures/zane-linux-x86_64"
cp "$scratch/fixtures/zane-linux-x86_64" "$scratch/fixtures/zane-macos-arm64"
if command -v sha256sum >/dev/null; then
    digest=$(sha256sum "$scratch/fixtures/zane-linux-x86_64" | cut -d ' ' -f 1)
else
    digest=$(shasum -a 256 "$scratch/fixtures/zane-linux-x86_64" | cut -d ' ' -f 1)
fi
printf '%s  zane-linux-x86_64\n%s  zane-macos-arm64\n' "$digest" "$digest" > "$scratch/fixtures/SHA256SUMS"

expect_failure() {
    if sh "$root/install.sh" "$@" > "$scratch/output" 2>&1; then
        echo "Installer unexpectedly succeeded: $*" >&2
        exit 1
    fi
    cmp "$scratch/old" "$ZANE_INSTALL_DIR/zane"
    if compgen -G "$ZANE_INSTALL_DIR/.zane.*" >/dev/null; then
        echo 'Installer left a staged binary' >&2
        exit 1
    fi
}

sh "$root/install.sh"
test "$("$ZANE_INSTALL_DIR/zane" --version)" = 'zane v0.0'
test -x "$ZANE_INSTALL_DIR/zane"
test "$(wc -l < "$ZANE_TEST_LOG" | tr -d ' ')" = 3
grep -q '/releases/download/v0.0/zane-linux-x86_64$' "$ZANE_TEST_LOG"
# The next install replaces this old file rather than writing through it.
printf 'old binary\n' > "$ZANE_INSTALL_DIR/zane"
sh "$root/install.sh" v0.0
test "$("$ZANE_INSTALL_DIR/zane")" = 'zane v0.0'
cp "$ZANE_INSTALL_DIR/zane" "$scratch/old"

printf 'corrupt\n' >> "$scratch/fixtures/zane-linux-x86_64"
expect_failure v0.0
grep -q 'checksum mismatch' "$scratch/output"
cp "$scratch/fixtures/zane-macos-arm64" "$scratch/fixtures/zane-linux-x86_64"
cp "$scratch/fixtures/SHA256SUMS" "$scratch/checksums"
printf 'invalid checksums\n' > "$scratch/fixtures/SHA256SUMS"
expect_failure v0.0
cp "$scratch/checksums" "$scratch/fixtures/SHA256SUMS"
export ZANE_TEST_FAILURE=download
expect_failure v0.0
expect_failure
export ZANE_TEST_FAILURE=
expect_failure 'v0.0; touch unwanted'
expect_failure $'v0.0\ninvalid'
expect_failure v00.0
expect_failure v0.0 extra
export ZANE_TEST_ARCH=aarch64
expect_failure v0.0
export ZANE_TEST_OS=Darwin ZANE_TEST_ARCH=arm64
sh "$root/install.sh" v0.0
test "$("$ZANE_INSTALL_DIR/zane")" = 'zane v0.0'
echo 'Unix installer integration tests passed'
