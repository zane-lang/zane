require "option_parser"
require "../coda"
require "../compiler_release"
require "../errors"
require "../std"
require "../progress"
require "../home"
require "../layout"
require "../manifest"
require "../project"

module Zane::Commands
  # `zane init [dir]`: creates a project (docs/design/cli.md §2.1).
  class Init
    # The packages the project starts with: a library package with a test package
    # for it, or a program package (spec packages.md §2.1).
    enum Start
      Library
      Program
    end

    # What a newly created repository holds, which may already be in the
    # target directory.
    ALLOWED = [/\A\.git\z/, /\A\.github\z/, /\AREADME/, /\ALICENSE/, /\ACOPYING/, /\A\.gitignore\z/, /\A\.gitattributes\z/]

    # How the files `zane` writes are indented, as in the spec's examples.
    INDENT = "    "

    USAGE = "usage: zane init [dir] [--name NAME] [--lib | --app] [--version-pattern PATTERN] [--zane-version TAG] [--no-std] [--no-git] [--yes]"

    @dir : String = "."
    @name : String? = nil
    @start : Start? = nil
    @version_pattern : String? = nil
    @zane_version : String? = nil
    @std = true
    @git = true
    @yes = false

    # *interactive* is true when questions may be asked, and false when
    # standard input is not a terminal. *compiler_url* is where releases are
    # looked up, *toolchains* where they are installed, *std_url* where `std`
    # is, and *packages* the package cache; tests change all four.
    def initialize(args : Array(String), @input : IO, @output : IO, @interactive : Bool,
                   @compiler_url : String = CompilerRelease::URL, @toolchains : Path = Home.toolchains,
                   @std_url : String = Std::URL, @packages : Path = Home.packages)
      parse(args)
    end

    private def parse(args : Array(String)) : Nil
      dirs = [] of String
      OptionParser.parse(args.dup) do |p|
        p.banner = USAGE
        p.on("--name NAME", "The name of the first package") { |v| @name = v }
        p.on("--lib", "Start with a library package and a test package for it") { @start = Start::Library }
        p.on("--app", "Start with a program package") { @start = Start::Program }
        p.on("--version-pattern PATTERN", "Which of the package's versions are interchangeable") { |v| @version_pattern = v }
        p.on("--zane-version TAG", "The compiler release to pin, instead of the newest installed or published") { |v| @zane_version = v }
        p.on("--no-std", "Do not depend on std, and write code that uses only the intrinsics") { @std = false }
        p.on("--no-git", "Do not create a Git repository") { @git = false }
        p.on("-y", "--yes", "Accept every default") { @yes = true }
        p.unknown_args { |before, after| dirs.concat(before).concat(after) }
        p.invalid_option { |flag| raise UserError.new("unknown option #{flag}\n#{USAGE}") }
        p.missing_option { |flag| raise UserError.new("#{flag} needs a value\n#{USAGE}") }
      end
      raise UserError.new("init takes one directory\n#{USAGE}") if dirs.size > 1
      @dir = dirs.first? || "."
    end

    def run : Nil
      root = Path[@dir].expand
      check_target(root)

      ask = @interactive && !@yes
      if ask && !confirm("Create the project in #{root}?", true)
        raise UserError.new("cancelled; nothing was written")
      end

      name = choose_name(root, ask)
      start = choose_start(ask)
      pattern = choose_version_pattern(ask)
      git = choose_git(root, ask)
      progress = Progress.current
      progress.step("Finding the compiler release to pin")
      release = CompilerRelease.resolve(@zane_version, @compiler_url, @toolchains)
      progress.done("Pinning compiler #{release.tag} (commit #{release.commit[0, 12]})")
      if git && !Process.find_executable("git")
        raise UserError.new("git is not installed; run again with --no-git")
      end
      if @std
        std = Std.pin(@std_url, @packages)
        check_std(name, release, std)
      end

      # Checked again, since the directory may have changed while the
      # questions were answered.
      check_target(root)
      write(root, name, start, pattern, release, std)
      init_git(root) if git

      which = if @zane_version
                ""
              elsif release.installed
                ", the newest one installed"
              else
                ", the newest release"
              end
      what = start.library? ? "the library package lib/#{name}/ and its test package test/#{name}/" : "the program bin/#{name}/"
      @output.puts "Created a project in #{root} with #{what}, built by the compiler #{release.tag}#{which}."
      if std
        where = std.cached ? ", the newest in the package cache, since std could not be reached" : ""
        @output.puts "It depends on std #{std.tag}#{where}, compiled from source, for the core package."
      end
    end

    # Refuses a std the project could not build with: one without the `core`
    # package the templates import, one with a package named *name*, which
    # would clash with the project's first package
    # (spec dependencies.md §8), or one that needs another compiler than
    # *release*, which builds every package of the project (§2.1).
    private def check_std(name : String, release : CompilerRelease, std : Std::Pin) : Nil
      src = Std.source(@std_url, std.tag, @packages)
      names = Layout.new(src).public_libs.map(&.name)
      unless names.includes?("core")
        raise UserError.new("std #{std.tag} has no public `core` package, which the code `init` writes imports; run again with --no-std")
      end
      if names.includes?(name)
        raise UserError.new("std #{std.tag} has a package named `#{name}`, which the project's first package cannot share; " \
                            "choose another name with --name, or run again with --no-std")
      end
      needed = Manifest.load(src).zane_version
      major, minor = CompilerRelease.version(release.tag).not_nil!
      version = needed.try { |n| CompilerRelease.version(n) }
      if needed.nil? || version.nil?
        raise UserError.new("std #{std.tag} names no compiler release as its `zane-version`; run again with --no-std")
      elsif version[0] != major
        raise UserError.new("std #{std.tag} is built by compiler major #{version[0]} (#{needed}), and this project by #{release.tag}; " \
                            "choose a compiler of major #{version[0]} with --zane-version, or run again with --no-std")
      elsif version[1] > minor
        raise UserError.new("std #{std.tag} needs compiler #{needed} or later, and this project is pinned to #{release.tag}; " \
                            "install it with `zane toolchain install #{needed}` and run again, or run again with --no-std")
      end
    end

    # The directory must hold nothing but what a new repository holds, so that
    # `zane init` run by mistake in a folder of projects writes nothing there.
    private def check_target(root : Path) : Nil
      return unless File.exists?(root)
      raise UserError.new("#{root} exists and is not a directory") unless File.directory?(root)
      others = Dir.children(root).reject { |e| ALLOWED.any?(&.matches?(e)) }.sort
      return if others.empty?
      raise UserError.new(<<-MSG.chomp)
        #{root} is not empty: it holds #{others.first(5).join(", ")}#{others.size > 5 ? " and #{others.size - 5} more" : ""}.
        To create the project in a new directory, run `zane init <name>`.
        MSG
    end

    private def choose_name(root : Path, ask : Bool) : String
      if name = @name
        return name if Project.valid_name?(name)
        raise UserError.new(invalid_name(name))
      end
      default = Project.name_from(root.basename)
      unless ask
        return default if default
        raise UserError.new("cannot make a package name from `#{root.basename}`; name it with --name")
      end
      loop do
        answer = question("Package name", default)
        return answer if Project.valid_name?(answer)
        @output.puts invalid_name(answer)
      end
    end

    private def invalid_name(name : String) : String
      "`#{name}` is not a package name: it starts with a lowercase letter and holds only letters and digits, like `myTool`"
    end

    private def choose_start(ask : Bool) : Start
      if start = @start
        return start
      end
      return Start::Program unless ask
      loop do
        case question("Library or application?", "application").downcase
        when "a", "app", "application" then return Start::Program
        when "l", "lib", "library"     then return Start::Library
        else                                @output.puts "Answer `library` or `application`."
        end
      end
    end

    private def choose_version_pattern(ask : Bool) : String
      if pattern = @version_pattern
        if error = Project.version_pattern_error(pattern)
          raise UserError.new("`#{pattern}` is not a version pattern: #{error}")
        end
        return pattern
      end
      return Project::DEFAULT_VERSION_PATTERN unless ask
      @output.puts "The version pattern says which of this package's versions can replace each other:"
      @output.puts "`*` must match, `+` prefers a higher number and `++` breaks ties. It cannot change later."
      loop do
        answer = question("Version pattern", Project::DEFAULT_VERSION_PATTERN)
        error = Project.version_pattern_error(answer)
        return answer unless error
        @output.puts "`#{answer}` is not a version pattern: #{error}"
      end
    end

    private def choose_git(root : Path, ask : Bool) : Bool
      return false if !@git || inside_git?(root)
      ask ? confirm("Initialise a Git repository?", true) : true
    end

    private def inside_git?(root : Path) : Bool
      dir = root
      until File.directory?(dir)
        dir = dir.parent
      end
      Process.run("git", ["-C", dir.to_s, "rev-parse", "--is-inside-work-tree"]).success?
    rescue File::NotFoundError
      false
    end

    # *std* is the version of `std` the project depends on, or nil under
    # `--no-std`.
    private def write(root : Path, name : String, start : Start, pattern : String, release : CompilerRelease,
                      std : Std::Pin?) : Nil
      Dir.mkdir_p(root)

      Coda::Doc.new do |doc|
        manifest = doc.root
        manifest["zane-version"] = release.tag
        manifest["version-pattern"] = pattern
        # A table takes rows only once it is in the document.
        manifest["deps"] = Coda::KeyedTable.new(["version", "from"])
        manifest["deps"].as_keyed_table[Std::KEY] = Coda::Row.new.insert("version", std.tag).insert("from", "source") if std
        File.write(root / "zane.coda", doc.serialize(INDENT))
      end

      Coda::Doc.new do |doc|
        doc.root[Manifest::COMPILER_COMMIT] = release.commit
        doc.root[Manifest::RESOLUTIONS] = Coda::KeyedTable.new(["url", "commit"])
        doc.root[Manifest::RESOLUTIONS].as_keyed_table[Std::KEY] = Coda::Row.new.insert("url", @std_url).insert("commit", std.commit) if std
        File.write(root / "zane-lock.coda", doc.serialize(INDENT))
      end

      if start.program?
        Dir.mkdir_p(root / "bin" / name)
        File.write(root / "bin" / name / "main.zn", std ? application_source(name) : intrinsic_application_source(name))
      else
        Dir.mkdir_p(root / "lib" / name)
        File.write(root / "lib" / name / "#{name}.zn", std ? library_source(name) : intrinsic_library_source(name))
        Dir.mkdir_p(root / Project::TEST_PACKAGE / name)
        File.write(root / Project::TEST_PACKAGE / name / "main.zn", std ? test_source(name) : intrinsic_test_source(name))
      end

      ignore = root / ".gitignore"
      existing = File.exists?(ignore) ? File.read(ignore) : ""
      unless existing.lines.any? { |l| {"out/", "out", "/out", "/out/"}.includes?(l.strip) }
        separator = existing.empty? || existing.ends_with?('\n') ? "" : "\n"
        existing = "#{existing}#{separator}out/\n"
        File.write(ignore, existing)
      end
      unless existing.lines.any? { |l| {"compile_commands.json", "/compile_commands.json"}.includes?(l.strip) }
        separator = existing.empty? || existing.ends_with?('\n') ? "" : "\n"
        File.write(ignore, "#{existing}#{separator}compile_commands.json\n")
      end
    end

    private def application_source(name : String) : String
      <<-ZANE
        package #{name};

        import core$;

        Unit main() {
        \tconsole Console(@program$console);
        \tconsole!print("hello world");
        \treturn Unit();
        }

        ZANE
    end

    private def library_source(name : String) : String
      <<-ZANE
        package #{name};

        import core$;

        /// Every declaration is public unless its name starts with `_`.
        Int double(n Int) => n + n;

        ZANE
    end

    # The library package's test package, which imports it as any user does
    # (spec packages.md §7); `zane test` builds and runs it, and fails when
    # its `main` aborts.
    private def test_source(name : String) : String
      <<-ZANE
        package test;

        import core$;
        import #{name};

        Unit?@primitives$String main() {
        \tif(#{name}$double(Int(21)) ~= 42) {
        \t\tabort @primitives$String("double(21) is not 42");
        \t}
        \tconsole Console(@program$console);
        \tconsole!print("ok");
        \treturn Unit();
        }

        ZANE
    end

    # The `--no-std` sources, which use only the intrinsics.
    private def intrinsic_application_source(name : String) : String
      <<-ZANE
        package #{name};

        @primitives$Unit main() {
        \ttext @primitives$String("hello world");
        \t@program$console!print(text);
        \treturn @primitives$Unit();
        }

        ZANE
    end

    private def intrinsic_library_source(name : String) : String
      <<-ZANE
        package #{name};

        /// Every declaration is public unless its name starts with `_`.
        @primitives$I64 double(n @primitives$I64) => @operators$add(n, n);

        ZANE
    end

    private def intrinsic_test_source(name : String) : String
      <<-ZANE
        package test;

        import #{name};

        alias I64 = @primitives$I64;
        alias Bool = @primitives$Bool;
        alias Unit = @primitives$Unit;
        alias String = @primitives$String;

        Unit check(ok Bool) {
        \tpassed String.escaped("ok\\n");
        \tfailed String.escaped("failed\\n");
        \t@controlflow$branch(ok, {
        \t\t@program$console!print(passed);
        \t});
        \t@controlflow$branch(@operators$not(ok), {
        \t\t@program$console!print(failed);
        \t});
        \treturn Unit();
        }

        Unit main() {
        \tcheck(@operators$equal(#{name}$double(I64(21)), I64(42)));
        \treturn Unit();
        }

        ZANE
    end

    private def init_git(root : Path) : Nil
      status = Process.run("git", ["init", "-q", root.to_s], error: Process::Redirect::Inherit)
      raise UserError.new("git init failed in #{root}") unless status.success?
    rescue File::NotFoundError
      raise UserError.new("git is not installed; run again with --no-git")
    end

    private def question(text : String, default : String?) : String
      @output.print default ? "#{text} [#{default}]: " : "#{text}: "
      @output.flush
      line = @input.gets || raise UserError.new("cancelled; nothing was written")
      answer = line.strip
      answer.empty? && default ? default : answer
    end

    private def confirm(text : String, default : Bool) : Bool
      loop do
        answer = question("#{text} #{default ? "[Y/n]" : "[y/N]"}", nil).downcase
        return default if answer.empty?
        return true if {"y", "yes"}.includes?(answer)
        return false if {"n", "no"}.includes?(answer)
      end
    end
  end
end
