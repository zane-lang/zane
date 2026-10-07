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
no TLS or crypto library. Repositories are fetched with `git` and archives
downloaded with `curl`, which every supported system ships. `zane` reads a release archive's tar format
itself, decompressing it with the zlib Crystal links, so that it checks every
entry before it writes anything (§3.1).

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
| Package name | the directory's name, converted to camelCase | the first package's directory |
| Library or application? | application | whether it starts in `lib/` or `bin/` |
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

- `zane.coda`, with `zane-version` and `version-pattern`, and an empty `deps`
  table;
- `zane-lock.coda`, holding only the reserved `zane` row;
- for an application, `bin/<name>/main.zn`, a program package with a `main`;
- for a library, `lib/<name>/<name>.zn`, a library package with one public
  example function, and `test/<name>/main.zn`, a test package whose `main`
  imports it and checks that function
  ([`packages.md` §2.1 and §7](https://github.com/zane-lang/spec/blob/main/spec/packages.md#21-a-projects-packages-live-in-lib-bin-and-test));
- `.gitignore` listing `out/`, appended to if one exists.

### 2.2 `zane check`

Runs the compiler up to and including semantic checking and stops. This is the
fast loop while editing. It checks the project's library packages together, in
a build with no root, then each program package and each test package as the
root of its own build (§5), and stops at the first that fails. It works from
any directory inside the project, as every command below does: `zane` looks
for `zane.coda` there and in each directory above.

Before calling the compiler, `zane` reads the project's packages from `lib/`,
`bin/` and `test/` and holds them to the rules of
[`packages.md` §2 and §7](https://github.com/zane-lang/spec/blob/main/spec/packages.md#2-projects-and-packages), since it is
the one listing the directories: a `.zn` file directly in one of the three, a
program package with a subdirectory of sources, a nested test package that
mirrors no subpackage, and the names a project keeps apart.

### 2.3 `zane build [PROGRAM] [--target T] [-o OUT]`

Resolves and fetches dependencies
([`dependencies.md` §13](https://github.com/zane-lang/spec/blob/main/spec/dependencies.md#13-build-flow)),
then has `zanec` compile and link every program package in `bin/`, or the one
named. Each goes to `out/<target>/<name>`, with `out/host/<name>` when no
target is given, and `-o` names the file when one program is built. The
program is optimized. `T` is a target triple, spelled as `zig cc` reads it,
such as `x86_64-windows-gnu`
([compiler `platforms.md`](https://github.com/zane-lang/compiler/blob/main/docs/design/platforms.md)),
and defaults to the host, which `zane` names the same way: `x86_64-linux-gnu`,
`aarch64-macos`, and so on. That name is the row it looks up in a
dependency's `zane-artifacts.coda`. A dependency with no artifact for `T`
stops the build with an error that names it and suggests `from source`. A
project with no program package is refused: its library packages are checked
with `check` and published with `release`.

### 2.4 `zane run [PROGRAM] [-- ARGS]`

Builds a program package for the host into `out/run/<name>`, then runs it with
`ARGS` and exits with its status. A project with several programs names the
one to run. It does not optimize, which makes the build about three times
faster; the program means the same either way, so only its speed differs from
what `build` makes.

### 2.5 `zane test [TEST] [-- ARGS]`

Builds every test package in `test/`, or the one named by its directory under
`test/`, such as `gui/opengl`, for the host into `out/test/`, and runs each
with `ARGS`, unoptimized as `run` is. Each test package is the root of its
own build, and the project's library packages are compiled with it
([`packages.md` §7.2](https://github.com/zane-lang/spec/blob/main/spec/packages.md#72-each-test-package-is-the-root-of-its-own-test-build)).
The graph is the project's `deps` and `test-deps` together
([`dependencies.md` §13](https://github.com/zane-lang/spec/blob/main/spec/dependencies.md#13-build-flow)).
Run on one test package, `test` exits with its status. Run on all, it names
each as it starts, then says how many passed or which failed, and exits with
1 when any did. A project with no test package is refused.

What a test does and how it reports is the test package's own business: `zane`
runs one program for each and passes on its exit status, so a testing library
in `test-deps` decides how failures are counted and shown.

### 2.6 `zane clean`

Deletes `out/`.

---

## 3. Dependency commands

These are the only commands that write `zane.coda` and `zane-lock.coda`, and
they always change the two files together
([`dependencies.md` §2.3](https://github.com/zane-lang/spec/blob/main/spec/dependencies.md#23-files-are-recorded-and-updated-by-commands)).

| Command | Does |
|---|---|
| `zane add <url> [tag] [--as key] [--from-source] [--test]` | Resolves the tag, newest when omitted, and pins its commit. The newest is the highest tag of a `v` and dot-separated numbers. The key defaults to the last part of the URL path. Fetches the library and everything it depends on for the host before writing either file, so a missing artifact shows up immediately and a library that cannot be used is never recorded. Refuses a project with no public library package. Prints the `import` lines for its public library packages. With `--test`, writes the row into `test-deps` instead of `deps`. |
| `zane remove <key>` | Removes the key, from `deps` or `test-deps`, from both files, and warns about each line of the project's packages that still imports one of its packages. |
| `zane update [key [tag]] [--accept-tag-move]` | Moves one key, or every key, to the tag named, or else the newest, and pins its commit. A tag that now points to another commit than the lock file pins has moved, and is refused with a security error without the flag. |
| `zane dev <key> <path>` / `zane dev off <key>` | Sets the key's `from` to a local project, or back to `release`. The path is given from where the command runs and written from the project's root. |
| `zane remap <url>` / `zane unremap <url>` | Adds the URL to the `remaps` list, or takes it out. Warns when no package of the graph has the URL. |
| `zane fetch [--target T …]` | Runs the build flow up to linking, for each target. For CI and offline work. |
| `zane tree [--test]` | With `--test`, prints the test build's graph, the `test-deps` rows marked. Prints the resolved graph: each package under what depends on it, with its key, tag, URL and where its code comes from. A version reached again is printed once more, marked, without what it depends on, and a version remapping displaced is marked with the one chosen in its place, whose dependencies follow beneath it. Then it lists the versions of each package linked side by side, and those remapping collapsed. |

`update` and `dev` apply to a `test-deps` key as to a `deps` key. `add`, `update`
and `dev` fetch the changed graph for the host, `test-deps` included, before
writing either file, as `add` does, so a change that leaves the project unable to build
is refused and nothing is written. `remove`, `remap` and `unremap` write without
fetching. `check`, `build`, `run` and `test` resolve and fetch the graph as §3.1 says,
and warn about each URL in `remaps` that names no package of the graph
([`dependencies.md` §2.1](https://github.com/zane-lang/spec/blob/main/spec/dependencies.md#21-manifest-zanecoda)).

### 3.1 Fetching

`check`, `build`, `run`, `test`, `fetch` and `add` each read the graph from the
project's two files and, recursively, from each dependency's own two files at
its pinned commit ([`dependencies.md` §13](https://github.com/zane-lang/spec/blob/main/spec/dependencies.md#13-build-flow)).
Only `check` stops before the objects: it needs the sources alone. The
project's `test-deps` rows join the graph for `test`, `fetch`, and the test
packages `check` checks, and never for `build` or `run`; a dependency's own
`test-deps` never join it
([`dependencies.md` §2.1](https://github.com/zane-lang/spec/blob/main/spec/dependencies.md#21-manifest-zanecoda)).

- **Sources.** Each version of each package is cloned at its tag into the
  cache, `~/.zane/packages/<normalized url>/<tag>/src/`, and refused with a
  security error unless the tag is the commit the lock file pins
  ([§4](https://github.com/zane-lang/spec/blob/main/spec/dependencies.md#4-tag-and-commit-verification)).
  A checkout already in the cache at the pinned commit is used without going
  online. The commit fixes what the checkout holds, so a tag that moved since
  cannot change it, and builds work offline once `zane fetch` has run.
- **Archives.** For a `release` dependency, `zane` reads the target's row of
  the checkout's `zane-artifacts.coda`, downloads its URL with
  `curl --proto =https --proto-redir =https`, and refuses the file unless its
  SHA-256 is the committed one
  ([§5](https://github.com/zane-lang/spec/blob/main/spec/dependencies.md#5-fetching)).
  It then unpacks the archive into `artifacts/<target>/build/`, refusing it
  whole if any entry is not a directory or regular file under `build/`.
- **Rewriting.** `zanec --rewrite` (§5) turns each object's placeholder into
  the package's stamp, into `build/<target>/`. Last, `zane` writes
  `build/<target>.coda`, recording the commit, target, archive hash and
  compiler pin (`zane-version` and the `zane` lock row's commit) the objects
  were made with. The objects are reused only while all five match;
  otherwise they are rewritten again, from the kept archive when its hash
  still matches.
- **Compiling from source.** A `source` dependency is compiled on its own
  from its checkout, into `build-from-source/<target>/package.o`, named with
  its stamp, against the versions its own lock file pins
  ([§12.1](https://github.com/zane-lang/spec/blob/main/spec/dependencies.md#121-source-compilation-is-explicit-opt-in)).
  `build-from-source/<target>.coda` records the commit, target and compiler
  pin it was compiled with, and the object is reused only while all four
  match. A path dependency is compiled the same way on every build, into the
  project's `out/deps/<target>/`, and never enters the cache
  ([§12.2](https://github.com/zane-lang/spec/blob/main/spec/dependencies.md#122-local-path-dependencies)).
- **Remapping.** For each URL in `remaps`, the versions in the graph are
  grouped by the `version-pattern` each one's manifest declares, and within
  a group by their `*` components; each group of more than one version is
  collapsed onto its best version by the pattern's priorities
  ([§15.3](https://github.com/zane-lang/spec/blob/main/spec/dependencies.md#153-selection-best-of-both)).
  A tag of another shape is kept apart quietly, and versions whose patterns
  differ are kept apart with a note (§15.4). A displaced version is neither
  compiled against nor linked: every key that named it names the chosen one,
  and `zanec --remap` (§5) moves each linked object's references to it,
  into the project's `out/remapped/<target>/`, since which versions are
  displaced is the project's choice.
- **Linking.** The compiler is given each version linked with
  `--package STAMPNAME=DIR`, each package's keys, the project's included,
  with `--import`, and every object with `--link`
  ([compiler `separate-compilation.md`](https://github.com/zane-lang/compiler/blob/main/docs/design/separate-compilation.md) C10).
  Each version is a package of its own, so versions of one package, and
  packages of one name, are linked side by side
  ([§11](https://github.com/zane-lang/spec/blob/main/spec/dependencies.md#11-multiple-version-coexistence)),
  and a key need not be its package's name.

Each part of a cache entry is made beside where it goes and renamed into place
once whole, so an interrupted fetch leaves nothing that looks ready.

---

## 4. Publishing, toolchains and the cache

| Command | Does |
|---|---|
| `zane release <tag> [--targets T…]` | Refuses a dirty tree, a tag that does not fit `version-pattern`, and any path `from` in `deps`. For a project with library packages, has `zanec` write their `!`-prefixed objects for each target, packs one archive per target, writes `zane-artifacts.coda`, commits and tags. Archives are left in `out/release/<tag>/`. |
| `zane release upload <tag>` | Uploads those exact archives to the GitHub Release, then downloads each one and checks its hash. The only GitHub-specific step; fetching needs only HTTPS. |
| `zane toolchain install [tag]` | Installs the latest published compiler release, or the tag named, into the shared toolchain directory (§4.1). Works outside a project. |
| `zane toolchain use <tag>` | Changes `zane-version` and the `zane` lock row together. |
| `zane cache list` / `path` / `clean [--stale]` | Lists each version in `~/.zane/packages` with the targets its objects are ready for and its size, prints the directory, or empties it. With `--stale`, removes only what no build uses: the parts an interrupted fetch left beside where they go, and rewritten objects without their record. |
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
its tag pointed to, which is what a project's `zane` lock row pins. Installation
downloads the selected GitHub Release archive for the CLI's host and verifies
it against that release's `SHA256SUMS`. It checks the archive's version and
record against the repository tag, then atomically publishes the complete
directory. An already installed matching release is reused; existing incomplete
or conflicting directories are preserved and reported. Installing does not
change any project's compiler pin. A directory without a record is an interrupted install
and is ignored, as is a toolchain from another `url`. A toolchain is found from
its record alone; the compiler is never asked what it is.

---

## 5. What `zane` needs from `zanec`

A library package is named by its path within its project's `lib/`, and
which packages each package may import follows from where it lies
([`packages.md` §2.2 and §4.3](https://github.com/zane-lang/spec/blob/main/spec/packages.md#43-which-packages-a-package-may-import)),
which only `zane` reads off the directories, so the contract is:

- **`--package PATH=DIR`** names a package by its path, `gui.opengl` for a
  subpackage, whose last part is the name its files declare, and
  **`--package STAMPPATH=DIR`** gives it its stamp as well: the pinned tag,
  `%`, the identity hash of its URL and `%`
  ([`dependencies.md` §6.1](https://github.com/zane-lang/spec/blob/main/spec/dependencies.md#61-placeholder-prefix-rewriting)).
  A package with a stamp is known by its stamped path, so each version of a
  project is a set of packages of its own. The first `--package` comes first:
  the program or test package being built, or the first library package of a
  library build.
- **`--import PACKAGE:KEY=PACKAGE`** gives a package each package it may
  import, by the key it imports it by, its name, each package named as
  `--package` names it. Once any `--import` is given, a package imports
  through its keys alone, so an import the rules forbid is the compiler's
  error. A build whose packages import nothing gives the first package its
  own name as its key, so the rule still holds.
- **`--kind application|library`**. An application's first package is the
  root, and one without `main` is a compile-time error
  ([`packages.md` §6.2](https://github.com/zane-lang/spec/blob/main/spec/packages.md#62-main-is-the-entry-point)).
  A library build has no root, so none of its packages reaches `@program$`.
- **`--check`**, **`--build OUT`**, **`--target T`** and **`--optimize`**.
  `T` is spelled as `zig cc` reads it; the compiler hands LLVM its normal
  form and the C compiler the triple as written.
- A stamped dependency arrives as objects of its own, so the compiler emits
  nothing it declares. **`--link FILE`** adds one of them to `--build`'s
  link.
- **`--object OUT`** writes the object of every library package of the
  project being compiled, the packages that share the first one's stamp,
  every symbol they define under the `!` placeholder, or under their stamp
  when they have one.
  `zane release` packs the first (§4), and a dependency compiled from source
  or a path is the second (§3.1).
- **`--rewrite STAMP INPUT OUTPUT`** writes the object `INPUT` with every `!`
  in its symbols replaced by `STAMP`, for ELF, Mach-O and COFF objects. It is
  the compiler's step because the symbol spelling is the compiler's, so the
  pinned compiler rewrites what that same version built.
- **`--remap FROM TO INPUT OUTPUT`** writes the object `INPUT` with every
  reference to the version stamped `FROM` moved to the version of the same
  package stamped `TO`, for remapping
  ([`dependencies.md` §15.6](https://github.com/zane-lang/spec/blob/main/spec/dependencies.md#156-mechanism-reuses-pull-time-rewriting)).

`zanec` has `--check`, `--build` and `--target` since
zane-lang/compiler#147, `--optimize` since #148, `--object` since #150,
`--link` since #151, `--rewrite` since #152 for ELF and #153 for Mach-O and
COFF, stamped `--package` names, `--import` and `--remap` since #156, and
package paths, `_`-prefixed names, rootless library builds and imports
through keys alone since #188.

`zane` passes each build its packages in this order: the first package, the
project's library packages, then every version its graph links, each with its
library packages. A program's build gives the program package the project's
top-level library packages and its dependencies' public ones; a test
package's adds those of `test-deps`, and for a nested test package the
subpackage it tests
([`packages.md` §7.3](https://github.com/zane-lang/spec/blob/main/spec/packages.md#73-a-test-package-stands-where-its-packages-user-stands)).

---

## 6. Phases

1. **Local projects.** `init`, `check`, `build`, `run`, `clean`, and the
   `zanec` flags of §5. No dependencies, so a project uses the storage
   primitives (`@primitives$`) directly, as the compiler's test fixtures do.
2. **Dependencies.** `add`, `remove`, `update`, `dev`, `remap`, `fetch`,
   `tree`, and the cache (§3, §3.1). Built.
3. **Releases.** `release` and `release upload`, and cross-compilation.
4. **Toolchains.** `toolchain install [tag]` is implemented; `toolchain use`
   remains to come.
5. **Layout and tests.** The `lib/`, `bin/` and `test/` layout with
   subpackages, programs per directory of `bin/`, `test`, the `test-deps`
   block, `add --test`, `tree --test`, and the packages `init` writes (§2.5).
   Built.

`zane` runs the first compiler it finds of: the one `ZANE_COMPILER` names, the
toolchain installed for the project's `zane-version` (§4.1), and `zanec` on
`PATH`. A compiler selected by `ZANE_COMPILER` or `PATH` is not checked against
the project's pin.
