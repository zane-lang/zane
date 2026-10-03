require "option_parser"
require "../coda"
require "../compiler"
require "../errors"
require "../git"
require "../graph"
require "../home"
require "../manifest"
require "../package_url"
require "../project_files"
require "../target"
require "../workspace"
require "./build"

module Zane::Commands
  # What the commands that change a project's two files share
  # (docs/design/cli.md §3): their arguments, the project, and checking a
  # change can be built before it is written.
  abstract class EditCommand
    @args = [] of String
    @workspace : Workspace? = nil

    # *dir* is where the command runs from, and *toolchains* where compilers
    # are installed; tests change both.
    def initialize(args : Array(String), @output : IO, @error : IO,
                   @dir : Path = Path[Dir.current], @toolchains : Path = Home.toolchains)
      OptionParser.parse(args.dup) do |p|
        p.banner = usage
        options(p)
        p.unknown_args { |before, after| @args.concat(before).concat(after) }
        p.invalid_option { |flag| raise UserError.new("unknown option #{flag}\n#{usage}") }
        p.missing_option { |flag| raise UserError.new("#{flag} needs a value\n#{usage}") }
      end
      raise UserError.new("wrong number of arguments\n#{usage}") unless arity.includes?(@args.size)
    end

    abstract def usage : String

    # How many arguments the command takes.
    abstract def arity : Range(Int32, Int32)

    abstract def run : Int32

    private def options(p : OptionParser) : Nil
    end

    private def workspace : Workspace
      @workspace ||= Workspace.find(@dir)
    end

    # Fetches the whole graph of *manifest* for the host, so that a change
    # which leaves the project unable to build is refused before either file
    # is written.
    private def fetch(manifest : Manifest) : Graph
      graph = Graph.new(Workspace.new(manifest))
      graph.objects(Target::HOST, Compiler.locate(workspace.zane_version, @toolchains))
      Commands.warn_stale_remaps(graph, @error)
      graph
    end

    # The dependency *key*, which the project must have.
    private def dependency(key : String) : Dependency
      workspace.manifest.dependency?(key) ||
        raise UserError.new("the project does not depend on `#{key}`#{known_keys}")
    end

    private def known_keys : String
      keys = workspace.manifest.deps.map(&.key)
      keys.empty? ? "; it has no dependencies" : "; its dependencies are #{keys.join(", ")}"
    end

    # The highest version tag of *tags*: a `v` and dot-separated numbers,
    # compared as numbers.
    private def newest(tags : Hash(String, String), url : PackageUrl) : String
      versions = tags.keys.select(&.matches?(/\Av?\d+(\.\d+)*\z/))
      versions.max_by? { |t| t.lchop('v').split('.').map(&.to_i64) } ||
        raise UserError.new("#{url} has no version tags; name the tag")
    end

    # *tag* and the commit it points to now in *tags*, refused when the tag
    # cannot name a cache directory.
    private def pin(tags : Hash(String, String), url : PackageUrl, tag : String) : {String, String}
      commit = tags[tag]? || raise UserError.new("#{url} has no tag #{tag}")
      if error = PackageUrl.tag_error(tag)
        raise UserError.new(error)
      end
      {tag, commit}
    end

    # Whether two commit hashes, either of them abbreviated, are one commit.
    private def same_commit?(a : String, b : String) : Bool
      a.starts_with?(b) || b.starts_with?(a)
    end
  end

  # `zane add <url> [tag] [--as key] [--from-source]` (§3): pins a library,
  # fetches it, and records it in both of the project's files.
  class Add < EditCommand
    @key : String? = nil
    @from_source = false

    def usage : String
      "usage: zane add <url> [tag] [--as KEY] [--from-source]"
    end

    def arity : Range(Int32, Int32)
      1..2
    end

    private def options(p : OptionParser) : Nil
      p.on("--as KEY", "The key to import the library by, instead of the last part of its URL") { |v| @key = v }
      p.on("--from-source", "Compile the library here rather than link its prebuilt objects") { @from_source = true }
    end

    def run : Int32
      ws = workspace
      url = PackageUrl.parse(@args[0])
      key = choose_key(ws, url)
      tags = Git.tags(url.url)
      tag, commit = pin(tags, url, @args[1]? || newest(tags, url))

      dep = Dependency.new(key, tag, @from_source ? "source" : "release")
      # The whole graph is fetched for the host before anything is written,
      # so a library that cannot be used is never recorded.
      fetch(ws.manifest.with_dependency(dep, Resolution.new(url.url, commit)))
      ProjectFiles.change(ws.root,
        ->(doc : Coda::Doc) { ProjectFiles.deps(doc)[key] = Coda::Row.new.insert("version", tag).insert("from", dep.from); nil },
        ->(doc : Coda::Doc) { ProjectFiles.resolutions(doc)[key] = Coda::Row.new.insert("url", url.url).insert("commit", commit); nil })

      how = @from_source ? "compiled from source" : "prebuilt for #{Target::HOST}"
      @output.puts "Added #{key} #{tag} (#{url}, commit #{commit[0, 12]}), #{how}."
      @output.puts "Import it with: import #{key}"
      0
    end

    private def choose_key(ws : Workspace, url : PackageUrl) : String
      key = @key || url.basename
      unless Project.valid_name?(key)
        raise UserError.new("`#{key}` is not a package name, so it cannot be the key; choose one with --as")
      end
      if key == Manifest::COMPILER_KEY
        raise UserError.new("`#{key}` is reserved for the compiler; choose another key with --as")
      end
      if ws.manifest.dependency?(key)
        raise UserError.new("the project already depends on `#{key}`; change its version with `zane update`")
      end
      ws.manifest.deps.each do |d|
        other = PackageUrl.parse(ws.manifest.resolutions[d.key].url)
        if other.normalized == url.normalized
          raise UserError.new("the project already depends on #{url}, as `#{d.key}`")
        end
      end
      key
    end
  end

  # `zane remove <key>` (§3): drops a dependency from both files, and points
  # out the source files that still import it.
  class Remove < EditCommand
    def usage : String
      "usage: zane remove <key>"
    end

    def arity : Range(Int32, Int32)
      1..1
    end

    def run : Int32
      ws = workspace
      key = dependency(@args[0]).key
      ProjectFiles.change(ws.root,
        ->(doc : Coda::Doc) { ProjectFiles.deps(doc).delete(key); nil },
        ->(doc : Coda::Doc) { ProjectFiles.resolutions(doc).delete(key); nil })
      @output.puts "Removed #{key}."
      importers(ws, key).each do |file, line|
        @error.puts "zane: warning: #{file}:#{line} still imports #{key}"
      end
      0
    end

    # Each line of the project's sources that imports *key*, in any of the
    # import forms (spec packages.md §3.3).
    private def importers(ws : Workspace, key : String) : Array({String, Int32})
      import = /^\s*import\s+#{Regex.escape(key)}(?![A-Za-z0-9_])/
      found = [] of {String, Int32}
      return found unless Dir.exists?(ws.source_dir)
      Dir.children(ws.source_dir).sort!.each do |name|
        path = ws.source_dir / name
        next unless name.ends_with?(".zn") && File.file?(path)
        File.read_lines(path).each_with_index(1) do |line, number|
          found << {path.relative_to(ws.root).to_s, number} if import.matches?(line)
        end
      end
      found
    end
  end

  # `zane update [key [tag]] [--accept-tag-move]` (§3): moves one dependency,
  # or every one, to the tag named or the newest, and pins its commit.
  class Update < EditCommand
    @accept_tag_move = false

    def usage : String
      "usage: zane update [key [tag]] [--accept-tag-move]"
    end

    def arity : Range(Int32, Int32)
      0..2
    end

    private def options(p : OptionParser) : Nil
      p.on("--accept-tag-move", "Trust the commit a tag points to now, though the lock file pins another") { @accept_tag_move = true }
    end

    def run : Int32
      ws = workspace
      deps = @args.empty? ? ws.manifest.deps : [dependency(@args[0])]
      manifest = ws.manifest
      updates = [] of {Dependency, Dependency, Resolution}
      deps.each do |dep|
        locked = manifest.resolutions[dep.key]
        url = PackageUrl.parse(locked.url)
        tags = Git.tags(url.url)
        tag, commit = pin(tags, url, @args[1]? || newest(tags, url))
        if tag == dep.version
          next if same_commit?(commit, locked.commit)
          check_tag_move(dep, url, commit, locked)
        end
        updated = dep.copy_with(version: tag)
        resolution = Resolution.new(url.url, commit)
        updates << {dep, updated, resolution}
        manifest = manifest.with_dependency(updated, resolution)
      end
      if updates.empty?
        what = deps.size == 1 ? "#{deps[0].key} is" : "every dependency is"
        @output.puts "#{what} already at #{@args[1]? ? "that tag" : "its newest tag"}; nothing changed."
        return 0
      end

      fetch(manifest)
      ProjectFiles.change(ws.root,
        ->(doc : Coda::Doc) {
          table = ProjectFiles.deps(doc)
          updates.each { |_, d, _| table[d.key]["version"] = d.version }
          nil
        },
        ->(doc : Coda::Doc) {
          table = ProjectFiles.resolutions(doc)
          updates.each { |_, d, r| table[d.key]["url"] = r.url; table[d.key]["commit"] = r.commit }
          nil
        })
      updates.each do |old, new, resolution|
        @output.puts "Updated #{new.key} #{old.version} -> #{new.version} (commit #{resolution.commit[0, 12]})."
      end
      0
    end

    # A tag that now points to another commit than the lock pins has moved,
    # which is trusted only when asked (spec dependencies.md §2.3, §4).
    private def check_tag_move(dep : Dependency, url : PackageUrl, commit : String, locked : Resolution) : Nil
      return if @accept_tag_move
      raise UserError.new("security error: #{url} tag #{dep.version} is commit #{commit}, but the lock file pins " \
                          "#{locked.commit}. The tag has moved; to trust the new commit, run " \
                          "`zane update #{dep.key} #{dep.version} --accept-tag-move`")
    end
  end

  # `zane dev <key> <path>` and `zane dev off <key>` (§3): compiles a
  # dependency from a local project, or links its release again.
  class Dev < EditCommand
    def usage : String
      "usage: zane dev <key> <path> | zane dev off <key>"
    end

    def arity : Range(Int32, Int32)
      2..2
    end

    def run : Int32
      ws = workspace
      off = @args[0] == "off" && Project.valid_name?(@args[1])
      dep = dependency(off ? @args[1] : @args[0])
      from = off ? "release" : relative(Path[@args[1]])
      if dep.from == from
        @output.puts "#{dep.key} already comes from #{from}; nothing changed."
        return 0
      end

      updated = dep.copy_with(from: from)
      fetch(ws.manifest.with_dependency(updated, ws.manifest.resolutions[dep.key]))
      ProjectFiles.change(ws.root, ->(doc : Coda::Doc) { ProjectFiles.deps(doc)[dep.key]["from"] = from; nil })
      if off
        @output.puts "#{dep.key} now links its release, #{dep.version}."
      else
        @output.puts "#{dep.key} now compiles from #{from}, with the project; `zane dev off #{dep.key}` returns to #{dep.version}."
      end
      0
    end

    # *path*, given from where the command runs, as the manifest writes it:
    # from the project's root, starting with `./` or `../`, or absolute when
    # it was given so (spec dependencies.md §12.2).
    private def relative(path : Path) : String
      dir = path.expand(@dir)
      unless File.file?(dir / Manifest::FILE)
        raise UserError.new("#{path} holds no #{Manifest::FILE}, so it is not a project")
      end
      return dir.to_posix.to_s if path.absolute? && dir.to_posix.to_s.starts_with?('/')
      from = dir.relative_to(workspace.root).to_posix.to_s
      from.starts_with?("../") || from == ".." ? from : "./#{from}"
    end
  end

  # `zane remap <url>` and `zane unremap <url>` (§3): adds a package to the
  # project's `remaps` list, or takes it out (spec dependencies.md §15).
  class Remap < EditCommand
    def initialize(@on : Bool, args : Array(String), output : IO, error : IO,
                   dir : Path = Path[Dir.current], toolchains : Path = Home.toolchains)
      super(args, output, error, dir, toolchains)
    end

    def usage : String
      "usage: zane #{@on ? "remap" : "unremap"} <url>"
    end

    def arity : Range(Int32, Int32)
      1..1
    end

    def run : Int32
      ws = workspace
      url = PackageUrl.parse(@args[0])
      listed = ws.manifest.remaps.index { |u| PackageUrl.parse(u).normalized == url.normalized }
      if @on == !listed.nil?
        @output.puts "#{url} is #{@on ? "already" : "not"} in `remaps`; nothing changed."
        return 0
      end

      # The graph is read first, so a project that cannot resolve is left as
      # it was.
      known = !@on || Graph.new(ws).package?(url)
      ProjectFiles.change(ws.root, ->(doc : Coda::Doc) {
        if index = listed
          list = doc.root["remaps"].as_array
          list.delete_at(index)
          doc.root.delete("remaps") if list.empty?
        else
          doc.root["remaps"] = Coda::Array.new unless doc.root.has_key?("remaps")
          doc.root["remaps"].as_array << url.url
        end
        nil
      })
      @output.puts "#{@on ? "Added" : "Removed"} #{url} #{@on ? "to" : "from"} `remaps`."
      unless known
        @error.puts "zane: warning: no package the project depends on is #{url}"
      end
      0
    end
  end

  # `zane fetch [--target T ...]` (§3): everything a build needs before it
  # compiles, for each target, so that builds can then run offline.
  class Fetch < ProjectCommand
    @targets = [] of String

    def usage : String
      "usage: zane fetch [--target TRIPLE ...]"
    end

    private def options(p : OptionParser) : Nil
      p.on("--target TRIPLE", "A target to fetch for, instead of the host; may be repeated") { |v| @targets << v }
    end

    def run : Int32
      targets = @targets.empty? ? [Target::HOST] : @targets
      targets.each do |target|
        graph.objects(target, compiler)
        @output.puts "Fetched #{graph.packages.size} #{graph.packages.size == 1 ? "package" : "packages"} for #{target}."
      end
      0
    end
  end

  # `zane tree` (§3): the resolved graph, each package under what depends on
  # it, with its version and where its code comes from.
  class Tree < ProjectCommand
    def usage : String
      "usage: zane tree"
    end

    def run : Int32
      ws = workspace
      @output.puts "#{ws.name} (#{ws.kind})"
      shown = Set(String).new
      print(graph.direct, "", shown)
      0
    end

    private def print(packages : Array(Graph::Package), indent : String, shown : Set(String)) : Nil
      packages.each_with_index do |package, i|
        last = i == packages.size - 1
        again = shown.includes?(package.url.normalized)
        @output.puts "#{indent}#{last ? "└── " : "├── "}#{line(package)}#{again ? " (see above)" : ""}"
        next if again
        shown << package.url.normalized
        print(graph.dependencies(package), indent + (last ? "    " : "│   "), shown)
      end
    end

    private def line(package : Graph::Package) : String
      from = case package.from
             in .release? then "prebuilt"
             in .source?  then "from source"
             in .path?    then "from #{package.manifest.root}"
             end
      "#{package.key} #{package.tag}, #{package.url}, #{from}"
    end
  end
end
