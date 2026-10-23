require "./compiler_release"
require "./errors"
require "./home"

module Zane
  # The `zanec` a project is built with, which `zane` runs as a separate
  # program (docs/design/cli.md §5).
  class Compiler
    EXECUTABLE = {% if flag?(:win32) %} "zanec.exe" {% else %} "zanec" {% end %}

    # The first compiler release that builds in tiers (compiler
    # docs/design/tiers.md): `--build OUT --tiered` and `--tier-up OUT`.
    TIERED_SINCE = {0, 18}

    # The first compiler release that says whether a build has a root with
    # `--root` and `--no-root`; an earlier one says it with `--kind`.
    ROOT_SINCE = {0, 19}

    getter path : String

    # Whether `run` and `test` build in tiers with this compiler (§2.4).
    getter? tiered : Bool

    # Whether this compiler takes `--root` and `--no-root` (§5).
    getter? rooted : Bool

    def initialize(@path : String, @tiered : Bool = true, @rooted : Bool = true)
    end

    # Whether the compiler release *tag* builds in tiers.
    def self.tiered?(tag : String) : Bool
      since?(tag, TIERED_SINCE)
    end

    # Whether the compiler release *tag* takes `--root` and `--no-root`.
    def self.rooted?(tag : String) : Bool
      since?(tag, ROOT_SINCE)
    end

    private def self.since?(tag : String, release : {Int32, Int32}) : Bool
      version = CompilerRelease.version(tag)
      !version.nil? && (version <=> release) >= 0
    end

    # The flag that says whether a build has a root package: a program's or
    # a test's build has one, a library build has none (spec packages.md
    # §6.1).
    def root_flags(root : Bool) : Array(String)
      if @rooted
        [root ? "--root" : "--no-root"]
      else
        ["--kind", root ? "application" : "library"]
      end
    end

    # The compiler for a project built by *zane_version*, from the first of:
    # `ZANE_COMPILER`, the toolchain installed for that version (§4.1), and
    # `zanec` on `PATH`.
    def self.locate(zane_version : String, toolchains : Path = Home.toolchains) : Compiler
      if path = ENV["ZANE_COMPILER"]?.presence
        return new(path) if File.file?(path)
        raise UserError.new("ZANE_COMPILER names #{path}, which is not a file")
      end
      installed = toolchains / zane_version / "bin" / EXECUTABLE
      if CompilerRelease.installed(toolchains).has_key?(zane_version) && File.file?(installed)
        return new(installed.to_s, tiered?(zane_version), rooted?(zane_version))
      end
      if found = Process.find_executable("zanec")
        return new(found)
      end
      raise UserError.new(
        "the project is built by the compiler #{zane_version}, which is not installed, " \
        "and no zanec is on PATH; set ZANE_COMPILER to the compiler to use")
    end

    # Runs the compiler, its output going to *output* and *error*, and
    # returns its exit status.
    def run(args : Array(String), output : IO, error : IO) : Int32
      Compiler.launch(@path, args, output: output, error: error)
    end

    # Starts the compiler on *args* without waiting for it, and with nothing
    # of what it writes shown: a build in the background, which the caller
    # stops when it is no longer wanted.
    def start(args : Array(String)) : Process
      Process.new(@path, args, output: Process::Redirect::Close, error: Process::Redirect::Close)
    rescue error : IO::Error
      raise UserError.new("cannot run #{@path}: #{error.message}")
    end

    # Runs the program at *path* to its end and returns its exit code, or
    # raises a UserError when it cannot be started at all.
    def self.launch(path : String, args : Array(String), **options) : Int32
      exit_code(Process.run(path, args, **options))
    rescue error : IO::Error
      raise UserError.new("cannot run #{path}: #{error.message}")
    end

    # A finished process's status as an exit code; one a signal ended is
    # 128 plus the signal's number, as a shell reports it.
    def self.exit_code(status : Process::Status) : Int32
      {% if flag?(:win32) %}
        status.exit_code
      {% else %}
        status.signal_exit? ? 128 + status.exit_signal.value : status.exit_code
      {% end %}
    end
  end
end
