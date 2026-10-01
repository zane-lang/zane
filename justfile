# Recipes for building and testing `zane`. Run them inside `devbox shell`, or
# with `devbox run -- just <recipe>`.

build_dir := justfile_directory() / "build"
path_sep := if os_family() == "windows" { ";" } else { ":" }

# coda's C API is linked from build/, ahead of Crystal's own libraries.
export CRYSTAL_LIBRARY_PATH := build_dir + path_sep + `crystal env CRYSTAL_LIBRARY_PATH`

# A release links everything in, so the binary needs nothing installed beside
# it. Only musl links fully statically, which is why Linux releases are built
# on Alpine; macOS links the system libraries dynamically.
static := if os() == "linux" { "--static" } else { "" }

default:
	@just --list

# Builds a development binary at build/zane.
build: coda
	crystal build src/zane.cr -o build/zane

# Builds the binary that is published: optimised, without debug information.
release: coda
	crystal build src/zane.cr -o build/zane --release --no-debug {{ static }}

test: coda
	crystal spec

fmt:
	crystal tool format src spec

fmt-check:
	crystal tool format --check src spec

clean:
	rm -rf build

# coda's C API as a static library, built from the submodule at vendor/coda.
# It takes a few seconds, so it is skipped while the library is newer than
# every coda source, and the sources it is built from still exist.
[unix]
coda: _submodule
	#!/bin/sh
	set -e
	lib=build/libcoda_ffi.a
	if [ -f "$lib" ] && [ -f vendor/coda/ffi/coda_ffi_safe.cpp ] && [ -f vendor/coda/ffi/coda_ffi.cpp ] && [ -z "$(find vendor/coda/src vendor/coda/ffi -newer "$lib" -type f)" ]; then exit 0; fi
	mkdir -p build
	c++ -O2 -fPIC -std=c++17 -Ivendor/coda/src -Ivendor/coda/ffi -c vendor/coda/ffi/coda_ffi_safe.cpp -o build/coda_ffi.o
	rm -f "$lib"
	ar rcs "$lib" build/coda_ffi.o

# The same with MSVC, which must be on PATH (a Developer shell).
[windows]
coda: _submodule
	#!/bin/sh
	set -e
	lib=build/coda_ffi.lib
	if [ -f "$lib" ] && [ -f vendor/coda/ffi/coda_ffi_safe.cpp ] && [ -f vendor/coda/ffi/coda_ffi.cpp ] && [ -z "$(find vendor/coda/src vendor/coda/ffi -newer "$lib" -type f)" ]; then exit 0; fi
	mkdir -p build
	cl -nologo -O2 -std:c++17 -EHsc -Ivendor/coda/src -Ivendor/coda/ffi -c vendor/coda/ffi/coda_ffi_safe.cpp -Fo:build/coda_ffi.obj
	lib -nologo -out:"$lib" build/coda_ffi.obj

_submodule:
	@test -f vendor/coda/ffi/coda_ffi.h || (echo "vendor/coda is empty: run git submodule update --init" >&2; exit 1)
