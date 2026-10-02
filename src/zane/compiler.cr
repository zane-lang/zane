require "./compiler_release"
require "./errors"
require "./home"

module Zane
  # The `zanec` a project is built with, which `zane` runs as a separate
  # program (docs/design/cli.md §5).
  class Compiler
    EXECUTABLE = {% if flag?(:win32) %} "zanec.exe" {% else %} "zanec" {% end %}

    getter path : String

    def initialize(@path : String)
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
        return new(installed.to_s)
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
