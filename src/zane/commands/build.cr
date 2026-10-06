require "file_utils"
require "option_parser"
require "../compiler"
require "../errors"
require "../graph"
require "../home"
require "../target"
require "../workspace"

module Zane::Commands
  # What resolving the graph has to say. A URL in `remaps` that names no
  # package of the graph is likely a typo or left from a removed dependency,
  # so it is pointed out, but changes nothing (spec dependencies.md §2.1).
  def self.report(graph : Graph, error : IO) : Nil
    graph.stale_remaps.each do |url|
      error.puts "zane: warning: `remaps` lists #{url}, which is no package the project depends on; `zane unremap #{url}` removes it"
    end
    graph.notes.each { |note| error.puts "zane: note: #{note}" }
  end

  # What `check`, `build` and `run` share: finding the project and its
  # compiler, and handing the compiler the project (docs/design/cli.md §5).
  abstract class ProjectCommand
    @workspace : Workspace? = nil
    @graph : Graph? = nil
    @test_graph : Graph? = nil

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
      @workspace ||= Workspace.find(@dir).tap(&.check_sources).tap(&.check_tests)
    end

    # The packages the project depends on, their sources fetched.
    private def graph : Graph
      @graph ||= Graph.new(workspace).tap { |g| Commands.report(g, @error) }
    end

    # The packages a test build depends on: the project's `deps` and
    # `test-deps` together (spec dependencies.md §13).
    private def test_graph : Graph
      @test_graph ||= Graph.new(workspace, test: true).tap { |g| Commands.report(g, @error) unless @graph }
    end

    private def compiler : Compiler
      Compiler.locate(workspace.zane_version, @toolchains)
    end

    # The compiler's flags for the project: its kind, its own package named
    # by the manifest, and the packages it depends on.
    private def project_flags : Array(String)
      ws = workspace
      ["--kind", ws.kind.to_s, "--package", "#{ws.name}=#{ws.source_dir}"] + graph.package_flags
    end

    # The compiler's flags for the test build: the test package first, so it
    # is the root, with `main` required of it, then the library unstamped,
    # which is compiled with it (spec packages.md §7.2; compiler
    # docs/design/separate-compilation.md C1).
    private def test_flags : Array(String)
      ws = workspace
      ["--kind", "application", "--package", "#{Manifest::TEST_PACKAGE}=#{ws.test_dir}",
       "--package", "#{ws.name}=#{ws.source_dir}"] + test_graph.package_flags
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
      links = graph.objects(target || Target::HOST, compiler).flat_map { |o| ["--link", o.to_s] }
      compiler.run(args + project_flags + links, @output, @error)
    end

    # The program's file in `out/<dir>/`, named for the package, with `.exe`
    # when *target* (the host when nil) is Windows.
    private def output_in(dir : String, target : String?) : Path
      windows = Target.windows?(target || Target::HOST)
      workspace.out_dir / dir / (windows ? "#{workspace.name}.exe" : workspace.name)
    end

    abstract def run : Int32
  end

  # `zane check` (§2.2): semantics and nothing after it, for the library's
  # test build as well when it has a test package.
  class Check < ProjectCommand
    def usage : String
      "usage: zane check"
    end

    def run : Int32
      status = compiler.run(["--check"] + project_flags, @output, @error)
      return status unless status == 0 && workspace.kind.library? && workspace.tests?
      compiler.run(["--check"] + test_flags, @output, @error)
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
      Compiler.launch(path.to_s, @program_args,
        input: Process::Redirect::Inherit, output: @output, error: @error)
    end
  end

  # `zane test [-- ARGS]` (§2.5): builds the library's test build for the
  # host without optimizing, into `out/test/`, then runs it with *ARGS* and
  # exits with its status. The test package is the program, and the library
  # its dependency (spec packages.md §7.2).
  class Test < ProjectCommand
    @program_args = [] of String

    def usage : String
      "usage: zane test [-- ARGS]"
    end

    private def arguments(after : Array(String)) : Nil
      @program_args = after
    end

    def run : Int32
      ws = workspace
      if ws.kind.application?
        raise UserError.new("`#{ws.name}` is an application, which has no test package; run it with `zane run`")
      end
      unless ws.tests?
        raise UserError.new("`#{ws.name}` has no test package: put a .zn file declaring `package #{Manifest::TEST_PACKAGE}` and a `main` in #{ws.test_dir}")
      end
      path = output_in("test", nil)
      Dir.mkdir_p(path.parent)
      links = test_graph.objects(Target::HOST, compiler).flat_map { |o| ["--link", o.to_s] }
      status = compiler.run(["--build", path.to_s] + test_flags + links, @output, @error)
      return status unless status == 0
      Compiler.launch(path.to_s, @program_args,
        input: Process::Redirect::Inherit, output: @output, error: @error)
    end
  end

  # `zane clean` (§2.6).
  class Clean < ProjectCommand
    def usage : String
      "usage: zane clean"
    end

    def run : Int32
      built = Workspace.find(@dir).out_dir
      FileUtils.rm_r(built) if Dir.exists?(built)
      0
    rescue error : File::Error
      raise UserError.new("cannot remove #{error.file}: #{error.os_error.try(&.message) || error.message}")
    end
  end
end
