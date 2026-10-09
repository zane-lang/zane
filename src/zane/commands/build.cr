require "file_utils"
require "option_parser"
require "../compiler"
require "../errors"
require "../graph"
require "../home"
require "../layout"
require "../project"
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

  # What `check`, `build`, `run` and `test` share: finding the project, its
  # packages and its compiler, and handing the compiler a build
  # (docs/design/cli.md §5).
  abstract class ProjectCommand
    @workspace : Workspace? = nil
    @layout : Layout? = nil
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
      positional(rest)
    end

    private def options(p : OptionParser) : Nil
    end

    # The arguments before `--`. Only `build`, `run` and `test` take one.
    private def positional(rest : Array(String)) : Nil
      raise UserError.new("unexpected argument #{rest.first}\n#{usage}") unless rest.empty?
    end

    # What follows `--`. Only `run` and `test` take anything there.
    private def arguments(after : Array(String)) : Nil
      raise UserError.new("unexpected argument #{after.first}\n#{usage}") unless after.empty?
    end

    private def workspace : Workspace
      @workspace ||= Workspace.find(@dir)
    end

    # The project's packages (spec packages.md §2).
    private def layout : Layout
      @layout ||= workspace.layout
    end

    # The packages the project depends on, their sources fetched.
    private def graph : Graph
      @graph ||= Graph.new(workspace, layout).tap { |g| Commands.report(g, @error) }
    end

    # The packages a test build depends on: the project's `deps` and
    # `test-deps` together (spec dependencies.md §13).
    private def test_graph : Graph
      @test_graph ||= Graph.new(workspace, layout, test: true).tap { |g| Commands.report(g, @error) unless @graph }
    end

    private def compiler : Compiler
      Compiler.locate(workspace.zane_version, @toolchains)
    end

    # The flags for the project's library packages, after the build's own
    # first package: each by its path, and the keys each may import, of its
    # own project and of the public packages its dependencies give it
    # (packages.md §4.3).
    private def library_flags(g : Graph) : Array(String)
      flags = layout.libs.flat_map { |l| ["--package", "#{l.path}=#{l.dir}"] }
      flags.concat(g.package_flags)
      layout.libs.each do |l|
        own = layout.keys(l).map { |key, target| {key, target.path} }
        flags.concat(g.keyed(l.path, own + g.public_keys(g.direct)))
      end
      flags
    end

    # A library build, with no root, which checks every library package.
    private def library_build : Array(String)
      first = layout.libs.first
      keyed(["--kind", "library"] + library_flags(graph), first.path, first.name)
    end

    # How much memory each thread of execution's nested scopes may take, as
    # the project's own manifest sets it, for the programs it builds (spec
    # memory.md §3.7). Only a field the manifest gives is passed, so a
    # project that sets neither builds with any compiler.
    private def region_flags : Array(String)
      flags = [] of String
      m = workspace.manifest
      m.fixed_region.try { |bytes| flags.push("--fixed-region", bytes.to_s) }
      m.spawned_fixed_region.try { |bytes| flags.push("--spawned-fixed-region", bytes.to_s) }
      flags
    end

    # A program's build: the program package first, the root, with the
    # project's top-level library packages and its dependencies' public
    # packages to import.
    private def program_build(program : Layout::Program) : Array(String)
      g = graph
      own = layout.program_keys.map { |key, target| {key, target.path} }
      flags = ["--kind", "application"] + region_flags + ["--package", "#{program.name}=#{program.dir}"] + library_flags(g) +
              g.keyed(program.name, own + g.public_keys(g.direct))
      keyed(flags, program.name, program.name)
    end

    # A test build: the test package first, the root, importing what a user
    # of the packages it tests imports, and the public packages of `deps`
    # and `test-deps` (packages.md §7.3).
    private def test_build(test : Layout::Test) : Array(String)
      g = test_graph
      own = layout.test_keys(test).map { |key, target| {key, target.path} }
      flags = ["--kind", "application"] + region_flags + ["--package", "#{Project::TEST_PACKAGE}=#{test.dir}"] + library_flags(g) +
              g.keyed(Project::TEST_PACKAGE, own + g.public_keys(g.direct + g.test_direct))
      keyed(flags, Project::TEST_PACKAGE, Project::TEST_PACKAGE)
    end

    # Once any `--import` is given, each package imports through its keys
    # alone (compiler docs/design/separate-compilation.md C10). A build
    # whose packages import nothing gives the first its own name, so it is
    # still held to its keys.
    private def keyed(flags : Array(String), id : String, name : String) : Array(String)
      flags.includes?("--import") ? flags : flags + ["--import", "#{id}:#{name}=#{id}"]
    end

    # Builds *flags* for *target*, the host when nil, into *path*, linking
    # *g*'s objects, and returns the compiler's exit status. A program means
    # the same optimized or not, so *optimize* trades only build time for
    # speed.
    private def build(flags : Array(String), g : Graph, target : String?, path : Path, optimize : Bool) : Int32
      Dir.mkdir_p(path.parent)
      args = ["--build", path.to_s]
      args.push("--target", target) if target
      args << "--optimize" if optimize
      links = g.objects(target || Target::HOST, compiler).flat_map { |o| ["--link", o.to_s] }
      compiler.run(args + flags + links, @output, @error)
    end

    # The program's file in `out/<dir>/`, named *name*, with `.exe` when
    # *target* (the host when nil) is Windows.
    private def output_in(dir : String, name : String, target : String?) : Path
      windows = Target.windows?(target || Target::HOST)
      workspace.out_dir / dir / (windows ? "#{name}.exe" : name)
    end

    # The program packages *name* picks: the one it names, or every one.
    private def programs(name : String?) : Array(Layout::Program)
      all = layout.programs
      if all.empty?
        raise UserError.new("#{workspace.title} has no program to build: a program package is a directory of bin/; check library packages with `zane check`")
      end
      return all unless name
      [all.find { |p| p.name == name } || raise UserError.new("bin/#{name}/ is no program; the programs are #{all.map(&.name).join(", ")}")]
    end

    abstract def run : Int32
  end

  # `zane check` (§2.2): semantics and nothing after it, for the library
  # packages, each program and each test package.
  class Check < ProjectCommand
    def usage : String
      "usage: zane check"
    end

    def run : Int32
      builds = [] of Array(String)
      builds << library_build unless layout.libs.empty?
      layout.programs.each { |p| builds << program_build(p) }
      layout.tests.each { |t| builds << test_build(t) }
      builds.each do |flags|
        status = compiler.run(["--check"] + flags, @output, @error)
        return status unless status == 0
      end
      0
    end
  end

  # `zane build [PROGRAM] [--target T] [-o OUT]` (§2.3): every program
  # package, or the one named.
  class Build < ProjectCommand
    @target : String? = nil
    @path : Path? = nil
    @program : String? = nil

    def usage : String
      "usage: zane build [PROGRAM] [--target TRIPLE] [-o OUT]"
    end

    private def options(p : OptionParser) : Nil
      p.on("--target TRIPLE", "The LLVM target triple to build for, instead of the host") { |v| @target = v }
      p.on("-o OUT", "Where to write the program, instead of out/<target>/<name>") { |v| @path = Path[v].expand }
    end

    private def positional(rest : Array(String)) : Nil
      raise UserError.new("build takes one program\n#{usage}") if rest.size > 1
      @program = rest.first?
    end

    def run : Int32
      chosen = programs(@program)
      if @path && chosen.size > 1
        raise UserError.new("-o names one file, and the project has #{chosen.size} programs; name the one to build")
      end
      chosen.each do |program|
        path = @path || output_in(@target || "host", program.name, @target)
        status = build(program_build(program), graph, @target, path, optimize: true)
        return status unless status == 0
        @output.puts "Built #{shown(path)}"
      end
      0
    end

    private def shown(path : Path) : String
      path.relative_to?(Path[Dir.current]).try(&.to_s) || path.to_s
    end
  end

  # `zane run [PROGRAM] [-- ARGS]` (§2.4): builds a program for the host
  # without optimizing, which is the faster build, then runs it with *ARGS*
  # and exits with its status. It builds into `out/run/`, so it never
  # replaces what `zane build` made.
  class Run < ProjectCommand
    @program_args = [] of String
    @program : String? = nil

    def usage : String
      "usage: zane run [PROGRAM] [-- ARGS]"
    end

    private def positional(rest : Array(String)) : Nil
      raise UserError.new("run takes one program\n#{usage}") if rest.size > 1
      @program = rest.first?
    end

    private def arguments(after : Array(String)) : Nil
      @program_args = after
    end

    def run : Int32
      chosen = programs(@program)
      if chosen.size > 1
        raise UserError.new("the project has #{chosen.size} programs, #{chosen.map(&.name).join(", ")}; name the one to run")
      end
      program = chosen.first
      path = output_in("run", program.name, nil)
      status = build(program_build(program), graph, nil, path, optimize: false)
      return status unless status == 0
      Compiler.launch(path.to_s, @program_args,
        input: Process::Redirect::Inherit, output: @output, error: @error)
    end
  end

  # `zane test [TEST] [-- ARGS]` (§2.5): builds each test package, or the
  # one named as its directory under `test/` names it, for the host without
  # optimizing, into `out/test/`, and runs it with *ARGS*. Each test package
  # is the root of its own build (spec packages.md §7.2). It exits with the
  # status of the one test it ran, or 1 when any of several failed.
  class Test < ProjectCommand
    @program_args = [] of String
    @test : String? = nil

    def usage : String
      "usage: zane test [TEST] [-- ARGS]"
    end

    private def positional(rest : Array(String)) : Nil
      raise UserError.new("test takes one test package\n#{usage}") if rest.size > 1
      @test = rest.first?.try(&.rchop('/'))
    end

    private def arguments(after : Array(String)) : Nil
      @program_args = after
    end

    def run : Int32
      all = layout.tests
      if all.empty?
        raise UserError.new("#{workspace.title} has no test package: a test package is a directory of test/ holding .zn files that declare `package #{Project::TEST_PACKAGE}` and a `main`")
      end
      if name = @test
        test = all.find { |t| t.label == name } ||
               raise UserError.new("test/#{name}/ is no test package; the test packages are #{all.map(&.label).join(", ")}")
        return run_test(test)
      end
      failed = [] of String
      all.each do |test|
        @output.puts "Testing test/#{test.label}/"
        failed << test.label unless run_test(test) == 0
      end
      if failed.empty?
        @output.puts "#{count(all.size)} passed."
        0
      else
        @output.puts "#{failed.size} of #{count(all.size)} failed: #{failed.join(", ")}"
        1
      end
    end

    private def run_test(test : Layout::Test) : Int32
      path = output_in("test", test.label.tr("/", "."), nil)
      status = build(test_build(test), test_graph, nil, path, optimize: false)
      return status unless status == 0
      Compiler.launch(path.to_s, @program_args,
        input: Process::Redirect::Inherit, output: @output, error: @error)
    end

    private def count(n : Int32) : String
      n == 1 ? "1 test package" : "#{n} test packages"
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
