# zane

The command a Zane programmer runs: it creates projects, manages their
dependencies, and builds and runs them with the compiler each project pins.
What it does and why is in [`docs/design/cli.md`](docs/design/cli.md).

## Building

The toolchain comes from [devbox](https://www.jetify.com/devbox):

```sh
git submodule update --init
devbox run -- just test      # the specs
devbox run -- just build     # build/zane
devbox run -- just release   # the optimised binary that is published
```

`just` with no arguments lists every recipe.
