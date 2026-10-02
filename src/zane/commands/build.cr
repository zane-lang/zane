require "file_utils"
require "option_parser"
require "../compiler"
require "../errors"
require "../home"
require "../workspace"

module Zane::Commands
  # What `check`, `build` and `run` share: finding the project and its
  # compiler, and handing the compiler the project (docs/design/cli.md §5).
  abstract class ProjectCommand
    @workspace : Workspace? = nil

    # *dir* is where the command runs from, and *toolchains* where compilers
    # are installed; tests change both.
    def initialize(args : Array(String), @output : IO, @error : IO,
                   @dir : Path = Path[Dir.current], @toolchains : Path = Home.toolchains)
      parse(args)
    end

    abstract def usage : String

    private def parse(args : Array(String)) : Nil
      rest = [] of String
      OptionParser.parse(args.dup) do |p|
        p.banner = usage
        options(p)
        p.unknown_args { |before, after| rest.concat(before); arguments(after) }
        p.invalid_option { |flag| raise UserError.new("unknown option #{flag}\n#{usage}") }
        p.missing_option { |flag| raise UserError.new("#{flag} needs a value\n#{usage}") }
      end
      raise UserError.new("unexpected argument #{rest.first}\n#{usage}") unless rest.empty?
    end

    private def options(p : OptionParser) : Nil
    end

    # What follows `--`. Only `run` takes anything there.
    private def arguments(after : Array(String)) : Nil
      raise UserError.new("unexpected argument #{after.first}\n#{usage}") unless after.empty?
    end

    private def workspace : Workspace
      @workspace ||= Workspace.find(@dir).tap(&.check_sources)
    end

    private def compiler : Compiler
      Compiler.locate(workspace.zane_version, @toolchains)
    end

    # The compiler's flags for the project: its kind, and its one package
    # named by the manifest.
    private def project_flags : Array(String)
      ws = workspace
      ["--kind", ws.kind.to_s, "--package", "#{ws.name}=#{ws.source_dir}"]
    end

    # Builds the application for *target*, the host when nil, into *path*,
    # and returns the compiler's exit status. A program means the same
    # optimized or not, so *optimize* trades only build time for speed.
    private def build(target : String?, path : Path, optimize : Bool) : Int32
      if workspace.kind.library?
        raise UserError.new("`#{workspace.name}` is a library, which is not built into a program; check it with `zane check`")
      end
      Dir.mkdir_p(path.parent)
      args = ["--build", path.to_s]
      args.push("--target", target) if target
      args << "--optimize" if optimize
      compiler.run(args + project_flags, @output, @error)
    end

    # The program's file in `out/<dir>/`, named for the package, with `.exe`
    # when *target* (the host when nil) is Windows.
    private def output_in(dir : String, target : String?) : Path
      windows = target ? target.includes?("windows") : {{ flag?(:win32) }}
      workspace.out_dir / dir / (windows ? "#{workspace.name}.exe" : workspace.name)
    end

    abstract def run : Int32
  end

  # `zane check` (§2.2): semantics and nothing after it.
  class Check < ProjectCommand
    def usage : String
      "usage: zane check"
    end

    def run : Int32
      compiler.run(["--check"] + project_flags, @output, @error)
    end
  end

  # `zane build [--target T] [-o OUT]` (§2.3).
  class Build < ProjectCommand
    @target : String? = nil
    @path : Path? = nil

    def usage : String
      "usage: zane build [--target TRIPLE] [-o OUT]"
    end

    private def options(p : OptionParser) : Nil
      p.on("--target TRIPLE", "The LLVM target triple to build for, instead of the host") { |v| @target = v }
      p.on("-o OUT", "Where to write the program, instead of out/<target>/<name>") { |v| @path = Path[v].expand }
    end

    def run : Int32
      path = @path || output_in(@target || "host", @target)
      status = build(@target, path, optimize: true)
      @output.puts "Built #{shown(path)}" if status == 0
      status
    end

    private def shown(path : Path) : String
      path.relative_to?(Path[Dir.current]).try(&.to_s) || path.to_s
    end
  end

  # `zane run [-- ARGS]` (§2.4): builds for the host without optimizing,
  # which is the faster build, then runs the program with *ARGS* and exits
  # with its status. It builds into `out/run/`, so it never replaces what
  # `zane build` made.
  class Run < ProjectCommand
    @program_args = [] of String

    def usage : String
      "usage: zane run [-- ARGS]"
    end

    private def arguments(after : Array(String)) : Nil
      @program_args = after
    end

    def run : Int32
      path = output_in("run", nil)
      status = build(nil, path, optimize: false)
      return status unless status == 0
      Compiler.exit_code(Process.run(path.to_s, @program_args,
        input: Process::Redirect::Inherit, output: @output, error: @error))
    end
  end

  # `zane clean` (§2.5).
  class Clean < ProjectCommand
    def usage : String
      "usage: zane clean"
    end

    def run : Int32
      built = Workspace.find(@dir).out_dir
      FileUtils.rm_rf(built) if Dir.exists?(built)
      0
    end
  end
end
