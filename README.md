<!-- markdownlint-disable-next-line MD041 -- the logo floats before the title -->
<img height="96" align="right" src="https://raw.githubusercontent.com/zane-lang/logos/main/zane/zane.svg" alt="Zane logo" />

# Zane

Zane is a systems programming language. Its compiler keeps the intent you
write down and turns strict rules into speed, so programs get deterministic
memory management with no garbage collector and no lifetime annotations.

This repository holds **`zane`**, the command you use to work with Zane: it
creates projects, fetches their dependencies, installs compilers, and builds,
runs and tests programs.

## Notice

<notice>
<!-- To be written by the maintainer: the experimental nature of the project,
     how and why AI is used in it, the current lack of beginner documentation,
     and anything else a newcomer should know first. -->
</notice>

## A taste of Zane

```zane
package hello;

import core$;

type Point = struct {
	x Int;
	y Int;
}
Point(x Int, y Int) => init{ x; y; }

/// A method: `this` is the point it is called on.
Int steps(this Point) => this.x + this.y;

Unit main() {
	console Console(@program$console);
	console!print("Hello, Zane!");

	p Point(Int(3), Int(4));
	far Bool = if(Int(5) < p:steps()) {
		console!print("far away");
	}
	far:else() {
		console!print("close by");
	}

	i Int = Int(1);
	i!to(Int(3)) {
		console!print("tick");
	}
	return Unit();
}
```

A few things that stand out:

- A variable is written name first, then its type: `x Int`, `p Point(…)`. A
  function starts with what it returns: `Int steps(…)`.
- `Int`, `Bool`, `if`, `else` and the `to` loop are ordinary code from the
  [`core`](https://github.com/zane-lang/core) package, written in Zane. The
  language itself has no `if` or `while` keyword.
- A call says what it may do to its subject: `p:steps()` only reads `p`,
  while `console!print(…)` and `i!to(…)` may change theirs.
- The console is an object handed to you by the program
  (`@program$console`), so code that has no access to it cannot print.

## Install

On **Linux x86_64** or **macOS on Apple Silicon**:

```sh
curl -fsSL https://github.com/zane-lang/zane/releases/latest/download/install.sh | sh
```

This puts `zane` in `~/.local/bin`. Add that directory to your `PATH` if it is
not there yet (`export PATH="$HOME/.local/bin:$PATH"` in `~/.bashrc` or
`~/.zshrc`).

On **Windows x86_64**, in PowerShell:

```powershell
& ([scriptblock]::Create((Invoke-RestMethod https://github.com/zane-lang/zane/releases/latest/download/install.ps1)))
```

Both installers check the download's SHA-256 and need no administrator
access; how to pick another directory or version is in
[`docs/releasing.md`](docs/releasing.md#what-the-installers-do). You can also
take the binaries from [Releases](https://github.com/zane-lang/zane/releases)
and read the scripts before running them.

Then install a compiler:

```sh
zane toolchain install
zane --version
```

Compiler releases are packaged for Linux x86_64, macOS (Apple Silicon and
Intel) and Windows x86_64. Each one brings everything it needs to build
programs for all three systems, so you install no C compiler or LLVM yourself.

## Your first project

```sh
zane init hello --yes
cd hello
zane run
```

`zane init` creates a project that pins the newest installed compiler, with a
program in `bin/hello/main.zn`; `zane run` builds it and prints
`hello world`.

To write code like the example above, add the `core` package and replace
`bin/hello/main.zn` with the example (keeping `package hello;` as its first
line):

```sh
zane add https://github.com/zane-lang/core --from-source
zane run
```

A **library** project keeps its code in `lib/` and its tests in `test/`:

```sh
zane init geometry --lib --name math --yes
cd geometry
zane test
```

## Everyday commands

| Command | What it does |
|---|---|
| `zane init [dir]` | Create a project (`--lib` for a library) |
| `zane check` | Type-check the project without building it |
| `zane build [program]` | Build programs from `bin/` into `out/` |
| `zane run [program]` | Build a program and run it |
| `zane test [test]` | Build and run the test packages in `test/` |
| `zane add <url> [tag]` | Depend on a library |
| `zane update [key [tag]]` | Move dependencies to a newer tag |
| `zane remove <key>` | Drop a dependency |
| `zane tree` | Show what the project depends on |
| `zane toolchain install [version]` | Install a compiler |
| `zane toolchain update [version]` | Move the project to another compiler |
| `zane self update [version]` | Update `zane` itself |

`zane help` lists every command. What each one does, and why, is in
[`docs/design/cli.md`](docs/design/cli.md).

### Compilers and projects

Each project pins its compiler in `zane.coda` (`zane-version`) and
`zane-lock.coda`, and `zane` runs the installed toolchain of that version for
it. Compilers are installed side by side in `~/.zane/toolchains/`, so projects
on different versions work next to each other; installing a newer compiler changes no
project until you run `zane toolchain update` in it.

To use a compiler you built yourself, point `zane` at it:

```sh
export ZANE_COMPILER=/absolute/path/to/zanec
```

```powershell
$env:ZANE_COMPILER = 'C:\path\to\zanec.exe'
```

`ZANE_COMPILER` comes before the pinned toolchain, and when that toolchain is
not installed, `zane` falls back to a `zanec` on `PATH`. Neither is checked
against the project's pin.

## Learning the language

There is no tutorial yet. The language is described in the
[specification](https://github.com/zane-lang/spec). A good order to read it
in:

1. [`foundations.md`](https://github.com/zane-lang/spec/blob/main/spec/foundations.md): the ideas the rest of the language rests on
2. [`syntax.md`](https://github.com/zane-lang/spec/blob/main/spec/syntax.md): what each construct looks like
3. [`types.md`](https://github.com/zane-lang/spec/blob/main/spec/types.md) and [`functions.md`](https://github.com/zane-lang/spec/blob/main/spec/functions.md): types, constructors and methods
4. [`memory.md`](https://github.com/zane-lang/spec/blob/main/spec/memory.md) and [`effects.md`](https://github.com/zane-lang/spec/blob/main/spec/effects.md): ownership, references, and what a call may change
5. [`packages.md`](https://github.com/zane-lang/spec/blob/main/spec/packages.md): how a project is laid out

Every spec document has a matching *design story* in
[`stories/`](https://github.com/zane-lang/spec/tree/main/stories) that tells
why the language looks the way it does. The
[`core` tests](https://github.com/zane-lang/core/tree/main/test/core) are the
largest body of working Zane code.

## The other repositories

| Repository | What it is |
|---|---|
| [`compiler`](https://github.com/zane-lang/compiler) | `zanec`, the compiler that `zane` runs |
| [`spec`](https://github.com/zane-lang/spec) | The language specification and its design stories |
| [`core`](https://github.com/zane-lang/core) | The `core` and `math` packages: numbers, text, lists, control flow |
| [`zane-nvim`](https://github.com/zane-lang/zane-nvim) | Neovim support |
| [`coda`](https://github.com/zane-lang/coda) | The configuration format of `zane.coda` and other Zane files |

## Building `zane` from source

`zane` is written in [Crystal](https://crystal-lang.org/). The toolchain comes
from [devbox](https://www.jetify.com/devbox):

```sh
git clone --recurse-submodules https://github.com/zane-lang/zane
cd zane
devbox run -- just build     # build/zane
devbox run -- just test      # the specs
```

`just` with no arguments lists every recipe. How a release is published is in
[`docs/releasing.md`](docs/releasing.md).
