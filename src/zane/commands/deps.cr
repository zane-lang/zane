require "option_parser"
require "../coda"
require "../compiler"
require "../errors"
require "../git"
require "../graph"
require "../home"
require "../manifest"
require "../package_url"
require "../target"
require "../workspace"
require "./build"

module Zane::Commands
  # `zane add <url> [tag] [--as key] [--from-source]` (docs/design/cli.md §3):
  # pins a library, fetches it, and records it in both of the project's files.
  class Add
    USAGE = "usage: zane add <url> [tag] [--as KEY] [--from-source]"

    # How the files `zane` writes are indented, as `zane init` writes them.
    INDENT = "    "

    @url : String = ""
    @tag : String? = nil
    @key : String? = nil
    @from_source = false

    def initialize(args : Array(String), @output : IO, @error : IO,
                   @dir : Path = Path[Dir.current], @toolchains : Path = Home.toolchains)
      positional = [] of String
      OptionParser.parse(args.dup) do |p|
        p.banner = USAGE
        p.on("--as KEY", "The key to import the library by, instead of the last part of its URL") { |v| @key = v }
        p.on("--from-source", "Compile the library here rather than link its prebuilt objects") { @from_source = true }
        p.unknown_args { |before, after| positional.concat(before).concat(after) }
        p.invalid_option { |flag| raise UserError.new("unknown option #{flag}\n#{USAGE}") }
        p.missing_option { |flag| raise UserError.new("#{flag} needs a value\n#{USAGE}") }
      end
      raise UserError.new("add takes a URL and a tag\n#{USAGE}") unless 1 <= positional.size <= 2
      @url = positional[0]
      @tag = positional[1]?
    end

    def run : Int32
      ws = Workspace.find(@dir)
      url = PackageUrl.parse(@url)
      key = choose_key(ws, url)
      tags = Git.tags(url.url)
      tag = @tag || newest(tags, url)
      commit = tags[tag]? || raise UserError.new("#{url} has no tag #{tag}")
      if error = PackageUrl.tag_error(tag)
        raise UserError.new(error)
      end

      dep = Dependency.new(key, tag, @from_source ? "source" : "release")
      added = Workspace.new(ws.manifest.with_dependency(dep, Resolution.new(url.url, commit)))
      # The whole graph is fetched for the host before anything is written,
      # so a library that cannot be used is never recorded.
      graph = Graph.new(added)
      graph.objects(Target::HOST, Compiler.locate(ws.zane_version, @toolchains))
      write(ws.root, dep, url.url, commit)

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

    # The highest version tag: a `v` and dot-separated numbers, compared as
    # numbers.
    private def newest(tags : Hash(String, String), url : PackageUrl) : String
      versions = tags.keys.select(&.matches?(/\Av?\d+(\.\d+)*\z/))
      versions.max_by? { |t| t.lchop('v').split('.').map(&.to_i64) } ||
        raise UserError.new("#{url} has no version tags; name the tag to add")
    end

    # Adds the row to both files, each written beside itself and renamed into
    # place, so neither is left half-written.
    private def write(root : Path, dep : Dependency, url : String, commit : String) : Nil
      manifest = edit(root / Manifest::FILE) do |doc|
        deps = doc.root["deps"]?.try(&.as?(Coda::KeyedTable)) || Coda::KeyedTable.new(["version", "from"]).tap { |t| doc.root["deps"] = t }
        deps[dep.key] = Coda::Row.new.insert("version", dep.version).insert("from", dep.from)
      end
      lock = edit(root / Manifest::LOCK) do |doc|
        doc.root["resolutions"].as_keyed_table[dep.key] = Coda::Row.new.insert("url", url).insert("commit", commit)
      end
      File.rename(manifest, root / Manifest::FILE)
      File.rename(lock, root / Manifest::LOCK)
    ensure
      File.delete?(manifest) if manifest
      File.delete?(lock) if lock
    end

    private def edit(path : Path, & : Coda::Doc ->) : Path
      partial = path.parent / ".#{path.basename}.#{Random::Secure.hex(4)}"
      Coda::Doc.parse_file(path) do |doc|
        yield doc
        File.write(partial, doc.serialize(INDENT))
      end
      partial
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
end
