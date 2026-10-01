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
through the C API of [`zane-lang/coda`](https://github.com/zane-lang/coda),
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

The project is pinned to the newest compiler release, or to the one
`--zane-version` names. `init` finds it by listing the tags of
`zane-lang/compiler` with `git ls-remote`, so it needs no API access: the
highest `vMAJOR.MINOR` tag becomes `zane-version`, and the commit it points to
becomes the `zane` lock row. With no release published, `init` fails.

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
fast loop while editing.

### 2.3 `zane build [--target T] [-o OUT]`

Resolves and fetches dependencies
([`dependencies.md` §13](https://github.com/zane-lang/spec/blob/main/spec/dependencies.md#13-build-flow)),
then has `zanec` compile the project and link it. The output goes to
`out/<target>/<name>` unless `-o` says otherwise. `T` is an LLVM target triple
and defaults to the host. A dependency with no artifact for `T` stops the build
with an error that names it and suggests `from source`.

### 2.4 `zane run`

Builds for the host, then runs the program. It refuses a library.

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
| `zane toolchain install` | Installs the compiler the project's `zane-version` names, and verifies it against the `zane` lock row. |
| `zane toolchain use <tag>` | Changes `zane-version` and the `zane` lock row together. |
| `zane cache list` / `path` / `clean [--stale]` | Lists, locates or prunes `~/.zane/packages`. |
| `zane inspect cst\|sst\|decls\|tst\|cgt\|ll` | The compiler's debug views, run on the project. |

What an application's release produces is not designed yet.

---

## 5. What `zane` needs from `zanec`

The compiler today takes each package as `--package DIR` and names it after the
directory. Under the current spec a package's name is its manifest's `name`
([`packages.md` §2.1](https://github.com/zane-lang/spec/blob/main/spec/packages.md#21-the-manifest-names-the-package)),
so the contract starts with:

- **`--version`** prints the tag and commit the compiler was built from, so
  `zane` can tell whether the compiler it found is the one the project pins.
- **`--package NAME=DIR`** names a package explicitly. The first one is the
  root.
- **`--kind application|library`** for the root. An application without `main`
  is a compile-time error
  ([`packages.md` §6.2](https://github.com/zane-lang/spec/blob/main/spec/packages.md#62-main-is-the-entry-point)).
- **`--check`**, **`--build OUT`** and **`--target T`**.

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

Until phase 4, `zane` runs the `zanec` it finds through `ZANE_COMPILER` or on
`PATH`, and warns when its `--version` differs from the project's
`zane-version`.
