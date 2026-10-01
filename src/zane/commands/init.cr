require "option_parser"
require "../coda"
require "../compiler_release"
require "../errors"
require "../home"
require "../project"

module Zane::Commands
  # `zane init [dir]`: creates a project (docs/design/cli.md §2.1).
  class Init
    # What a newly created repository holds, which may already be in the
    # target directory.
    ALLOWED = [/\A\.git\z/, /\A\.github\z/, /\AREADME/, /\ALICENSE/, /\ACOPYING/, /\A\.gitignore\z/, /\A\.gitattributes\z/]

    # How the files `zane` writes are indented, as in the spec's examples.
    INDENT = "    "

    USAGE = "usage: zane init [dir] [--name NAME] [--lib | --app] [--version-pattern PATTERN] [--zane-version TAG] [--no-git] [--yes]"

    @dir : String = "."
    @name : String? = nil
    @kind : Project::Kind? = nil
    @version_pattern : String? = nil
    @zane_version : String? = nil
    @git = true
    @yes = false

    # *interactive* says whether questions may be asked; it is false when
    # standard input is not a terminal. *compiler_url* is where releases are
    # looked up and *toolchains* where they are installed; tests change both.
    def initialize(args : Array(String), @input : IO, @output : IO, @interactive : Bool,
                   @compiler_url : String = CompilerRelease::URL, @toolchains : Path = Home.toolchains)
      parse(args)
    end

    private def parse(args : Array(String)) : Nil
      dirs = [] of String
      OptionParser.parse(args.dup) do |p|
        p.banner = USAGE
        p.on("--name NAME", "The package name") { |v| @name = v }
        p.on("--lib", "Create a library") { @kind = Project::Kind::Library }
        p.on("--app", "Create an application") { @kind = Project::Kind::Application }
        p.on("--version-pattern PATTERN", "Which of the package's versions are interchangeable") { |v| @version_pattern = v }
        p.on("--zane-version TAG", "The compiler release to pin, instead of the newest installed or published") { |v| @zane_version = v }
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
      kind = choose_kind(ask)
      pattern = choose_version_pattern(ask)
      git = choose_git(root, ask)
      release = CompilerRelease.resolve(@zane_version, @compiler_url, @toolchains)
      if git && !Process.find_executable("git")
        raise UserError.new("git is not installed; run again with --no-git")
      end

      # Checked again, since the directory may have changed while the
      # questions were answered.
      check_target(root)
      write(root, name, kind, pattern, release)
      init_git(root) if git

      which = if @zane_version
                ""
              elsif release.installed
                ", the newest one installed"
              else
                ", the newest release"
              end
      @output.puts "Created #{kind} `#{name}` in #{root}, built by the compiler #{release.tag}#{which}."
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
        answer = question("Project name", default)
        return answer if Project.valid_name?(answer)
        @output.puts invalid_name(answer)
      end
    end

    private def invalid_name(name : String) : String
      "`#{name}` is not a package name: it starts with a lowercase letter and holds only letters and digits, like `myTool`"
    end

    private def choose_kind(ask : Bool) : Project::Kind
      if kind = @kind
        return kind
      end
      return Project::Kind::Application unless ask
      loop do
        case question("Library or application?", "application").downcase
        when "a", "app", "application" then return Project::Kind::Application
        when "l", "lib", "library"     then return Project::Kind::Library
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

    private def write(root : Path, name : String, kind : Project::Kind, pattern : String, release : CompilerRelease) : Nil
      Dir.mkdir_p(root / "src")

      Coda::Doc.new do |doc|
        manifest = doc.root
        manifest["name"] = name
        manifest["kind"] = kind.to_s
        manifest["zane-version"] = release.tag
        manifest["version-pattern"] = pattern
        manifest["deps"] = Coda::KeyedTable.new(["version", "from"])
        File.write(root / "zane.coda", doc.serialize(INDENT))
      end

      Coda::Doc.new do |doc|
        resolutions = Coda::KeyedTable.new(["url", "commit"])
        doc.root["resolutions"] = resolutions
        resolutions["zane"] = Coda::Row.new.insert("url", @compiler_url).insert("commit", release.commit)
        File.write(root / "zane-lock.coda", doc.serialize(INDENT))
      end

      if kind.application?
        File.write(root / "src" / "main.zn", application_source(name))
      else
        File.write(root / "src" / "#{name}.zn", library_source(name))
      end

      ignore = root / ".gitignore"
      existing = File.exists?(ignore) ? File.read(ignore) : ""
      unless existing.lines.any? { |l| {"out/", "out", "/out", "/out/"}.includes?(l.strip) }
        separator = existing.empty? || existing.ends_with?('\n') ? "" : "\n"
        File.write(ignore, "#{existing}#{separator}out/\n")
      end
    end

    private def application_source(name : String) : String
      <<-ZANE
        package #{name};

        @primitives$Unit main() {
        \ttext @primitives$String("hello world");
        \t@program$console!print(text);
        \treturn @primitives$Unit();
        }

        ZANE
    end

    private def library_source(name : String) : String
      <<-ZANE
        package #{name};

        alias Int = @primitives$Int

        /// Every declaration is public unless its name starts with `_`.
        Int double(n Int) => n + n

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
