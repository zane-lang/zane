# Publishing a `zane` release

`zane` versions are independent of compiler versions. A tag has two or three
numeric components (`v0.0` or `v0.1.0`), without leading zeroes.

## Running the release

Open **Actions → Release → Run workflow**, select `main`, and enter the new
tag.

The workflow tests and builds Linux x86_64, macOS arm64 and Windows x86_64
from the exact commit selected when it starts. It embeds the tag in
`zane --version`, creates the Git tag, uploads the three binaries, both
installers and `SHA256SUMS` to a draft release, then publishes it as latest.
No source version edit, local tag, manual push, or extra token is required.
Only the publishing job has write access.

## When a step fails

An existing tag is reused only when it points to the exact source commit and
has no release. If tag creation succeeds but release creation fails, use
**Re-run failed jobs** on the original Actions run: it keeps the original
commit and reuses the successful builds. A tag pointing elsewhere, or a draft
or published release for that tag, is refused.

If uploading fails, inspect and finish the draft, or remove the draft before
retrying the failed job. Keep its tag; never replace a published version's
tag or assets.

## What the installers do

`install.sh` (Linux and macOS) verifies the binary's SHA-256 and writes
`~/.local/bin/zane`; `ZANE_INSTALL_DIR` chooses another directory, and a tag
passed as its argument (`sh -s -- v0.0`) installs that version.
`install.ps1` (Windows) verifies the binary's SHA-256, installs into
`%LOCALAPPDATA%\Programs\Zane\bin`, and adds that folder to the user `Path`
and the current terminal's; `-Version v0.0` chooses a version.
`zane self update` (`docs/design/cli.md` §4.2) replaces an installed binary
the same way.
