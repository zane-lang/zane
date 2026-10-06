# zane

The command a Zane programmer runs: it creates projects, manages their
dependencies, and builds and runs them with the compiler each project pins.
What it does and why is in [`docs/design/cli.md`](docs/design/cli.md).

## Installing

Install the latest release on **Linux x86_64 or macOS Apple Silicon**:

```sh
curl -fsSL https://github.com/zane-lang/zane/releases/latest/download/install.sh | sh
```

The installer verifies the binary's SHA-256 and writes `~/.local/bin/zane`.
Add that directory to your shell's `PATH` if it is not there already:

```sh
export PATH="$HOME/.local/bin:$PATH"
zane --version
```

Put the `export` in `~/.bashrc` or `~/.zshrc` to keep it for new terminals.
Set `ZANE_INSTALL_DIR` to install elsewhere, or pass a tag to install a
specific version:

```sh
curl -fsSL https://github.com/zane-lang/zane/releases/latest/download/install.sh | sh -s -- v0.0
```

On **Windows x86_64**, run this in PowerShell:

```powershell
& ([scriptblock]::Create((Invoke-RestMethod https://github.com/zane-lang/zane/releases/latest/download/install.ps1)))
zane --version
```

It verifies the binary's SHA-256, installs into
`%LOCALAPPDATA%\Programs\Zane\bin`, and adds that folder to your user `Path`
and the current terminal's `Path`. Run it again to update. To choose a version,
append `-Version v0.0` to the installer command.

Both commands work after the first release is published. You can also download
the binaries and installers from [Releases](https://github.com/zane-lang/zane/releases)
and inspect the scripts before running them. No administrator access is needed.

### The compiler

The CLI does not bundle or automatically download `zanec` yet. Build the
[compiler](https://github.com/zane-lang/compiler), then put `zanec` on your
`PATH`, or point the CLI directly at it:

```sh
export ZANE_COMPILER=/absolute/path/to/zanec
```

```powershell
$env:ZANE_COMPILER = 'C:\path\to\zanec.exe'
```

This also lets you test an unreleased compiler. Then create and check a project:

```sh
zane init hello --yes
cd hello
zane check
```

`init` pins an installed compiler toolchain or a published compiler tag;
the existing compiler tag `v0.0` works. `ZANE_COMPILER` overrides the compiler
executable used to check and build it.

## Building

The toolchain comes from [devbox](https://www.jetify.com/devbox):

```sh
git submodule update --init
devbox run -- just test      # the specs
devbox run -- just build     # build/zane
devbox run -- just release   # the optimised binary that is published
```

`just` with no arguments lists every recipe.

## Publishing a CLI release

After the release workflow is on `main`, open **Actions → Release → Run
workflow**, select `main`, and enter a tag such as `v0.0` for the first release.
CLI versions are independent of compiler versions. Tags may use two or three
numeric components (`v0.0` or `v0.1.0`), without leading zeroes.

The workflow tests and builds Linux x86_64, macOS arm64 and Windows x86_64
from the exact commit selected when it starts. It embeds the tag in
`zane --version`, creates the Git tag, uploads the three binaries, both
installers and `SHA256SUMS` to a draft release, then publishes it as latest.
No source version edit, local tag, manual push, or extra token is required.
Only the publishing job has write access.

An existing tag is reused only when it points to the exact source commit and
has no release. If tag creation succeeds but release creation fails, use
**Re-run failed jobs** on the original Actions run: it keeps the original
commit and reuses the successful builds. A tag pointing elsewhere, or a draft
or published release for that tag, is refused.

If uploading fails, inspect and finish the draft, or remove the draft before
retrying the failed job. Keep its tag; do not replace a published version's
tag or assets.
