# The `zane` command

`zane` is the tool a Zane programmer runs. It creates projects, manages their
dependencies, and builds and runs them. It does not compile anything itself.
Each project's `zane-version` names the compiler that builds it, and `zane`
installs and runs that compiler, `zanec`
([`dependencies.md` §14](https://github.com/zane-lang/spec/blob/main/spec/dependencies.md#14-toolchain-version)).

This document lists every command, says which parts of the spec each one
carries out, and states what `zane` needs from `zanec`. The spec is the source
of truth for the files and the rules; this document cites it rather than
restating it.

---

## 1. What `zane` owns, and what it leaves to `zanec`

`zane` is not pinned by any project, so one installed copy must build projects
pinned to any compiler version. Everything whose behavior a pin has to fix
belongs to the compiler instead.

| `zane` | `zanec` (the pinned compiler) |
|---|---|
| Creating projects | Parsing, checking, lowering, code generation |
| Reading, validating and writing `zane.coda` and `zane-lock.coda` | Rewriting the `!` placeholder prefix of a library's exports |
| Resolving tags, verifying commits and archive hashes | Linking a program with the runtime it carries |
| The global package cache | Cross-compilation for `--target` |
| Installing compilers and running the pinned one | Writing a library's objects for a release |

The interface between the two is a contract (§5). A change to it is the one
kind of change that can break a project nobody touched.

`zane` is written in [Crystal](https://crystal-lang.org) for now, and is to be
ported to Zane once Zane can carry it. It reads and writes `.coda` files
through the Crystal binding of [`zane-lang/coda`](https://github.com/zane-lang/coda),
vendored as a submodule, and it hashes with its own SHA-256, so a release links
no TLS or crypto library. Downloads go through `curl` and unpacking through
`tar`, which every supported system ships.

---

## 2. Project commands

### 2.1 `zane init [dir]`

Creates a project in `dir`, or in the current directory when `dir` is omitted.
`dir` is created if it does not exist.

The target directory must be empty except for the files a newly created
repository holds: `.git/`, `.github/`, `README*`, `LICENSE*`, `COPYING*`,
`.gitignore` and `.gitattributes`. Anything else is an error, which lists what
was found and suggests `zane init <name>`. This stops `zane init` run by mistake
in a folder of projects from filling that folder with project files.

In a terminal, `init` asks these questions, showing the default for each:

| Question | Default | Written to |
|---|---|---|
| Create the project in `<absolute path>`? | yes | — |
| Project name | the directory's name, converted to camelCase | `name` |
| Library or application? | application | `kind` |
| Version pattern | `v*.+.++` | `version-pattern` |
| Initialise a Git repository? | yes, unless already inside one | — |

The name must be a valid package name
([`lexical.md` §3](https://github.com/zane-lang/spec/blob/main/spec/lexical.md)).
The version-pattern question explains the pattern in one line, because the
spec fixes it when the project is created
([`dependencies.md` §2.1](https://github.com/zane-lang/spec/blob/main/spec/dependencies.md#21-manifest-zanecoda)).

Every question has a flag: `--name`, `--lib` / `--app`, `--version-pattern`,
`--no-git`, and `--yes` to accept every default. When standard input is not a
terminal, `init` asks nothing: it uses the flags and defaults, and fails if a
default cannot be worked out.

The project is pinned to the newest compiler installed (§4.1), so `init` works
offline, or to the one `--zane-version` names when that one is installed. Its
tag becomes `zane-version`, and the commit its toolchain record names becomes
the `zane` lock row.

With no compiler installed, or not the one named, `init` looks the release up
online instead, by listing the tags of `zane-lang/compiler` with
`git ls-remote`, so it needs no API access: the highest `vMAJOR.MINOR` tag, or
the one named, becomes `zane-version`, and the commit it points to becomes the
`zane` lock row. With no release published, `init` fails. Either way, it says
which compiler it pinned and where it found it.

`init` writes nothing until every question is answered, so cancelling leaves the
directory untouched. It then writes:

- `zane.coda`, with `name`, `kind`, `zane-version` and `version-pattern`, and an
  empty `deps` table;
- `zane-lock.coda`, holding only the reserved `zane` row;
- `src/main.zn` with a `main` for an application, or `src/<name>.zn` with one
  public example function for a library;
- `.gitignore` listing `out/`, appended to if one exists.

### 2.2 `zane check`

Runs the compiler up to and including semantic checking and stops. This is the
fast loop while editing. It works from any directory inside the project, as
every command below does: `zane` looks for `zane.coda` there and in each
directory above.

### 2.3 `zane build [--target T] [-o OUT]`

Resolves and fetches dependencies
([`dependencies.md` §13](https://github.com/zane-lang/spec/blob/main/spec/dependencies.md#13-build-flow)),
then has `zanec` compile the project and link it. The output goes to
`out/<target>/<name>` unless `-o` says otherwise, with `out/host/<name>` when
no target is given. The program is optimized. `T` is an LLVM target triple and defaults to the host. A
dependency with no artifact for `T` stops the build with an error that names it
and suggests `from source`. A library is refused: it is checked with `check`
and published with `release`.

### 2.4 `zane run [-- ARGS]`

Builds for the host into `out/run/<name>`, then runs the program with `ARGS`
and exits with its status. It does not optimize, which makes the build about
three times faster; the program means the same either way, so only its speed
differs from what `build` makes. It refuses a library.

### 2.5 `zane clean`

Deletes `out/`.

---

## 3. Dependency commands

These are the only commands that write `zane.coda` and `zane-lock.coda`, and
they always change the two files together
([`dependencies.md` §2.3](https://github.com/zane-lang/spec/blob/main/spec/dependencies.md#23-files-are-recorded-and-updated-by-commands)).

| Command | Does |
|---|---|
| `zane add <url> [tag] [--as key] [--from-source]` | Resolves the tag, newest when omitted, and pins its commit. The key defaults to the last part of the URL path. Fetches the host target's archive at once, so a missing artifact shows up immediately. Refuses a package whose `kind` is `application`. Prints the `import` line to use. |
| `zane remove <key>` | Removes the key from both files, and warns about source files that still import it. |
| `zane update [key [tag]] [--accept-tag-move]` | Re-resolves one key, or every key. A tag that moved is refused without the flag. |
| `zane dev <key> <path>` / `zane dev off <key>` | Sets the key's `from` to a local path, or back to `release`. |
| `zane remap <url>` / `zane unremap <url>` | Edits the `remaps` list. |
| `zane fetch [--target T …]` | Runs the build flow up to linking, for each target. For CI and offline work. |
| `zane tree [--target T]` | Prints the resolved graph: versions linked side by side, versions collapsed by remapping, and where each package's code comes from. |

---

## 4. Publishing, toolchains and the cache

| Command | Does |
|---|---|
| `zane release <tag> [--targets T…]` | Refuses a dirty tree, a tag that does not fit `version-pattern`, and any path `from`. For a library, has `zanec` write the `!`-prefixed objects for each target, packs one archive per target, writes `zane-artifacts.coda`, commits and tags. Archives are left in `out/release/<tag>/`. |
| `zane release upload <tag>` | Uploads those exact archives to the GitHub Release, then downloads each one and checks its hash. The only GitHub-specific step; fetching needs only HTTPS. |
| `zane toolchain install` | Installs the compiler the project's `zane-version` names (§4.1), and verifies it against the `zane` lock row. |
| `zane toolchain use <tag>` | Changes `zane-version` and the `zane` lock row together. |
| `zane cache list` / `path` / `clean [--stale]` | Lists, locates or prunes `~/.zane/packages`. |
| `zane inspect cst\|sst\|decls\|tst\|cgt\|ll` | The compiler's debug views, run on the project. |

What an application's release produces is not designed yet.

### 4.1 Installed toolchains

`zane` keeps what projects share in `~/.zane`, or in the directory `ZANE_HOME`
names. Each installed compiler is a directory `toolchains/<tag>/` holding the
compiler at `bin/zanec` and its record, `toolchain.coda`:

```coda
url https://github.com/zane-lang/compiler
commit 0123456789abcdef0123456789abcdef01234567
```

`url` is the repository the compiler was built from, and `commit` the commit
its tag pointed to, which is what a project's `zane` lock row pins. Installing
writes the record last, so a directory without one is an interrupted install
and is ignored, as is a toolchain from another `url`. A toolchain is found from
its record alone; the compiler is never asked what it is.

---

## 5. What `zane` needs from `zanec`

A package's name is its manifest's `name`
([`packages.md` §2.1](https://github.com/zane-lang/spec/blob/main/spec/packages.md#21-the-manifest-names-the-package)),
which only `zane` reads, so the contract is:

- **`--package NAME=DIR`** names a package explicitly. The first one is the
  root.
- **`--kind application|library`** for the root. An application without `main`
  is a compile-time error
  ([`packages.md` §6.2](https://github.com/zane-lang/spec/blob/main/spec/packages.md#62-main-is-the-entry-point)).
- **`--check`**, **`--build OUT`**, **`--target T`** and **`--optimize`**.

`zanec` has these since zane-lang/compiler#147, and `--optimize` since #148.

A `.zn` file in a subdirectory of `src/` is an error. `zane` reports it before
calling the compiler, since it is the one listing the files.

The full contract is written down in the compiler repository, beside the flags
it describes.

---

## 6. Phases

1. **Local projects.** `init`, `check`, `build`, `run`, `clean`, and the
   `zanec` flags of §5. No dependencies, so a project uses the storage
   primitives (`@primitives$`) directly, as the compiler's test fixtures do.
2. **Dependencies.** `add`, `remove`, `update`, `dev`, `remap`, `fetch`,
   `tree`, and the cache.
3. **Releases.** `release` and `release upload`, and cross-compilation.
4. **Toolchains.** `toolchain install` and `use`, once the compiler publishes
   releases, starting with `v0.0`.

`zane` runs the first compiler it finds of: the one `ZANE_COMPILER` names, the
toolchain installed for the project's `zane-version` (§4.1), and `zanec` on
`PATH`. Until phase 4 installs toolchains, that is the first or the last, and
which version it is goes unchecked.
