<!-- markdownlint-disable-next-line MD041 -- the logo floats before the title -->
<img height="96" align="right" src="https://raw.githubusercontent.com/zane-lang/logos/main/zane/zane.svg" alt="Zane logo" />

# Zane

Zane is a systems programming language. Its strict rules give the compiler
enough information to make programs fast, and Zane programs free memory
deterministically, with no garbage collector and no lifetime annotations.

This repository holds **`zane`**, the command you use to work with Zane: it
creates projects, fetches their dependencies, installs compilers, and builds,
runs and tests programs.

> [!NOTE]
> Maintainer here: Zane is still very young and in its experimental phase. This means stuff may break a lot while its major version is zero. I am also using AI heavily to iterate quickly and test out different approaches to problems; again, because Zane is still experimental. However, this doesn't mean I'm not involved. Zane started with the idea…
>
> <details>
> <summary>Read more</summary>
>
> …of creating a language that doesn't have GC pauses, doesn't require manual management and doesn't need lifetime annotations (these goals mainly come from audio dsp). In December 2025 I started thinking more seriously about bringing it to life. So that's when I started with the language design. I didn't know much at the time, but as I researched more and more, I gathered a lot of knowledge which ultimately enabled me to make a great language. Once I had too many ideas, I couldn't really spend a lot of time writing nice documents about them. So I decided to use AI to record my ideas in the [spec repo](https://github.com/zane-lang/spec). This also meant that I could now keep the history of my decisions (which I find particularly important) as I didn't need to write them myself. I decided to spend extra time on the spec, as I wanted to have a well thought out language. I spent roughly 3/4 year designing the language, which shows how much thought went into it. The compiler was then made with substantial AI assistance too, because it meant that I had more flexibility in changing things up and I could explore different paths to the destination. Importantly, without AI I wouldn't have had the capacity to make a compiler in the first place, unless I decided to stick with an idea and never change something up, which directly goes against my philosophy.
>
> </details>

## A taste of Zane

```zane
package hello;

import core$;

type Point = struct {
	x Int;
	y Int;
}
Point(x Int, y Int) => init{ x; y; }

/// A method: `this` is the `Point` written before `:` or `!` in the call.
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

- A variable declaration puts the variable's name first and its type second:
  `x Int`, `p Point(…)`. A function declaration starts with its return type:
  `Int steps(…)`.
- `Int`, `Bool`, `if`, `else` and the `to` loop are ordinary code from the
  [`core`](https://github.com/zane-lang/std/tree/main/lib/core) package, written in Zane. The
  language itself has no `if` or `while` keyword.
- The operator in a method call shows whether the method may change its
  subject: with `:`, `p:steps()` only reads `p`; with `!`, `console!print(…)`
  and `i!to(…)` may change `console` and `i`.
- The console is an object that the program provides (`@program$console`),
  so code without access to that object cannot print.

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
access. [`docs/releasing.md`](docs/releasing.md#what-the-installers-do)
explains how to install into another directory or install another version. You can also
take the binaries from [Releases](https://github.com/zane-lang/zane/releases)
and read the scripts before running them.

Then install a compiler:

```sh
zane toolchain install
zane --version
```

Compiler releases are packaged for Linux x86_64, macOS (Apple Silicon and
Intel) and Windows x86_64. Each compiler release includes everything needed
to build programs for all three systems, so you don't install a C compiler or
LLVM yourself.

## Your first project

```sh
zane init hello --yes
cd hello
zane run
```

`zane init` creates a project that pins the newest installed compiler, with a
program in `bin/hello/main.zn`; `zane run` builds it and prints
`hello world`.

To write code like the example above, add [`std`](https://github.com/zane-lang/std),
which holds the `core` package, and replace
`bin/hello/main.zn` with the example (keeping `package hello;` as its first
line):

```sh
zane add https://github.com/zane-lang/std --from-source
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
| `zane lsp` | Run the language server an editor starts for Zane files |
| `zane toolchain install [version]` | Install a compiler |
| `zane toolchain update [version]` | Move the project to another compiler |
| `zane self update [version]` | Update `zane` itself |

`zane help` lists every command, and
[`docs/design/cli.md`](docs/design/cli.md) explains what each command does and
why.

### Compilers and projects

Each project pins its compiler version in `zane.coda` (`zane-version`) and
the compiler's commit in `zane-lock.coda` (`zane-commit`). For that project,
`zane` runs the installed toolchain of the pinned version. Compilers are installed side by side in `~/.zane/toolchains/`, so projects
on different versions work next to each other; installing a newer compiler changes no
project until you run `zane toolchain update` in it.

To use a compiler you built yourself, point `zane` at it:

```sh
export ZANE_COMPILER=/absolute/path/to/zanec
```

```powershell
$env:ZANE_COMPILER = 'C:\path\to\zanec.exe'
```

`zane` uses `ZANE_COMPILER` in preference to the pinned toolchain. When
`ZANE_COMPILER` is unset and the pinned toolchain is not installed, `zane` uses
a `zanec` found on `PATH`. `zane` checks neither of these compilers against the
project's pin.

## Learning the language

Start at <https://zane-lang.org/docs>: installing, a first project, and a tour
of the language, with every example checked against the current compiler. The
same site holds the [specification](https://zane-lang.org/spec), its
[design stories](https://zane-lang.org/stories), the
[`std` library](https://zane-lang.org/std), and the design of this command
([`docs/`](docs/README.md), also at <https://zane-lang.org/tools>), all
searchable.

## The other repositories

| Repository | Contents |
|---|---|
| [`compiler`](https://github.com/zane-lang/compiler) | `zanec`, the compiler that `zane` runs |
| [`spec`](https://github.com/zane-lang/spec) | The language specification and its design stories |
| [`std`](https://github.com/zane-lang/std) | The `core`, `math` and `regex` packages: numbers, text, lists, control flow, regular expressions |
| [`zane-nvim`](https://github.com/zane-lang/zane-nvim) | Neovim support |
| [`coda`](https://github.com/zane-lang/coda) | The configuration format of `zane.coda` and other Zane files |
| [`docs`](https://github.com/zane-lang/docs) | The Learn pages of the website |
| [`website`](https://github.com/zane-lang/website) | The website, <https://zane-lang.org>, which publishes the documentation of all of these |

## Building `zane` from source

`zane` is written in [Crystal](https://crystal-lang.org/). The toolchain comes
from [devbox](https://www.jetify.com/devbox):

```sh
git clone --recurse-submodules https://github.com/zane-lang/zane
cd zane
devbox run -- just build     # build/zane
devbox run -- just test      # the specs
```

`just` with no arguments lists every recipe.
[`docs/releasing.md`](docs/releasing.md) describes how a release is published.

## License

`zane` is under the MIT license; see [`LICENSE`](LICENSE). The compiler it
installs has its own license, in
[`zane-lang/compiler`](https://github.com/zane-lang/compiler).
