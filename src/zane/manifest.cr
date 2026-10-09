require "./coda"
require "./compiler_release"
require "./errors"
require "./project"

module Zane
  # One `deps` row of a manifest, or a `test-deps` row when *test* (spec
  # dependencies.md §2.1).
  record Dependency, key : String, version : String, from : String, test : Bool = false do
    # The manifest block the row is in.
    def block : String
      test ? Manifest::TEST_DEPS : Manifest::DEPS
    end

    def release? : Bool
      from == "release"
    end

    def source? : Bool
      from == "source"
    end

    # Whether `from` names a local project instead (§12.2).
    def path? : Bool
      Manifest.path?(from)
    end
  end

  # One `resolutions` row of a lock file (§2.2).
  record Resolution, url : String, commit : String

  # A project's `zane.coda` and `zane-lock.coda`, read together and held to
  # the rules that join them (spec dependencies.md §2).
  class Manifest
    FILE = "zane.coda"
    LOCK = "zane-lock.coda"

    # The lock row that pins the compiler rather than a dependency.
    COMPILER_KEY = "zane"

    DEPS      = "deps"
    TEST_DEPS = "test-deps"

    # How much memory the fixed-size regions of nested scopes may take, in
    # the program's own thread of execution and in each spawned call's
    # (spec memory.md §3.7): a whole number of MiB or GiB. Native addresses
    # impose no language-wide cap; the runtime must reserve the range.
    FIXED_REGION         = "fixed-region"
    SPAWNED_FIXED_REGION = "spawned-fixed-region"
    REGION_SIZE          = /\A([1-9][0-9]*)(MiB|GiB)\z/

    # A commit hash, whole or abbreviated.
    COMMIT = /\A[0-9a-f]{7,64}\z/

    getter root : Path
    getter zane_version : String?
    getter version_pattern : String
    getter deps : Array(Dependency)
    # The dependencies whose packages only test packages import (packages.md
    # §7.3).
    getter test_deps : Array(Dependency)
    getter remaps : Array(String)
    getter resolutions : Hash(String, Resolution)
    # Each in bytes, or nil when the manifest leaves it to the compiler.
    getter fixed_region : Int64?
    getter spawned_fixed_region : Int64?

    def initialize(@root, @zane_version, @version_pattern, @deps, @test_deps, @remaps, @resolutions,
                   @fixed_region = nil, @spawned_fixed_region = nil)
    end

    def self.path?(from : String) : Bool
      from.starts_with?("./") || from.starts_with?("../") || from.starts_with?('/')
    end

    # Reads both files in *root*, and refuses them unless they agree.
    def self.load(root : Path) : Manifest
      path = root / FILE
      raise UserError.new("#{root} holds no #{FILE}") unless File.file?(path)
      manifest = Coda::Doc.parse_file(path) { |doc| read(root, path, doc.root) }
      manifest.check_lock(path)
      manifest
    rescue error : Coda::Error
      raise UserError.new("#{path}: #{error.message}")
    end

    private def self.read(root : Path, path : Path, doc : Coda::Block) : Manifest
      zane_version = doc.has_key?("zane-version") ? field(doc, "zane-version", path) : nil
      pattern = field(doc, "version-pattern", path)
      if error = Project.version_pattern_error(pattern)
        raise UserError.new("#{path}: `#{pattern}` is not a version pattern: #{error}")
      end
      deps = read_deps(doc, path, DEPS)
      test_deps = read_deps(doc, path, TEST_DEPS)
      if both = test_deps.find { |t| deps.any? { |d| d.key == t.key } }
        raise UserError.new("#{path}: `#{both.key}` is in both `#{DEPS}` and `#{TEST_DEPS}`")
      end
      new(root, zane_version, pattern, deps, test_deps, read_remaps(doc, path), read_lock(root),
        read_region(doc, path, FIXED_REGION), read_region(doc, path, SPAWNED_FIXED_REGION))
    end

    # A region size in bytes, or nil when the field is absent.
    private def self.read_region(doc : Coda::Block, path : Path, key : String) : Int64?
      return nil unless doc.has_key?(key)
      value = field(doc, key, path)
      match = REGION_SIZE.match(value)
      count = match.try(&.[1].to_i64?)
      unless match && count
        raise UserError.new("#{path}: `#{key}` is `#{value}`; it is a whole number of `MiB` or `GiB`, such as `256MiB`")
      end
      unit = match[2] == "GiB" ? 1_i64 << 30 : 1_i64 << 20
      if count > Int64::MAX // unit
        raise UserError.new("#{path}: `#{key}` is `#{value}`; it is too large to represent in bytes")
      end
      count * unit
    end

    private def self.field(doc : Coda::Block, key : String, path : Path) : String
      node = doc[key]? || raise UserError.new("#{path} has no `#{key}` field")
      node.as?(Coda::StringNode).try(&.value) || raise UserError.new("#{path}: `#{key}` is not a single value")
    end

    private def self.read_deps(doc : Coda::Block, path : Path, block : String) : Array(Dependency)
      deps = [] of Dependency
      node = doc[block]? || return deps
      table = node.as?(Coda::KeyedTable)
      unless table && table.columns.includes?("version") && table.columns.includes?("from")
        raise UserError.new("#{path}: `#{block}` is a table of `key`, `version` and `from`")
      end
      table.each do |key, row|
        unless Project.valid_name?(key)
          raise UserError.new("#{path}: the dependency key `#{key}` is not a package name")
        end
        if key == COMPILER_KEY
          raise UserError.new("#{path}: `#{COMPILER_KEY}` is reserved for the compiler, and is not a dependency key")
        end
        version = row["version"]? || raise UserError.new("#{path}: `#{key}` has no version")
        from = row["from"]? || raise UserError.new("#{path}: `#{key}` has no `from`")
        unless from == "release" || from == "source" || path?(from)
          raise UserError.new("#{path}: `#{key}` comes from `#{from}`; it is `release`, `source`, or a path starting with `./`, `../` or `/`")
        end
        deps << Dependency.new(key, version, from, block == TEST_DEPS)
      end
      deps
    end

    private def self.read_remaps(doc : Coda::Block, path : Path) : Array(String)
      remaps = [] of String
      node = doc["remaps"]? || return remaps
      list = node.as?(Coda::Array) || raise UserError.new("#{path}: `remaps` is a list of URLs")
      list.each do |url|
        remaps << (url.as?(Coda::StringNode).try(&.value) || raise UserError.new("#{path}: `remaps` is a list of URLs"))
      end
      remaps
    end

    private def self.read_lock(root : Path) : Hash(String, Resolution)
      path = root / LOCK
      raise UserError.new("#{root} holds #{FILE} but no #{LOCK}") unless File.file?(path)
      Coda::Doc.parse_file(path) do |doc|
        node = doc.root["resolutions"]? || raise UserError.new("#{path} has no `resolutions` table")
        table = node.as?(Coda::KeyedTable)
        unless table && table.columns.includes?("url") && table.columns.includes?("commit")
          raise UserError.new("#{path}: `resolutions` is a table of `key`, `url` and `commit`")
        end
        resolutions = {} of String => Resolution
        table.each do |key, row|
          url = row["url"]? || raise UserError.new("#{path}: `#{key}` has no url")
          commit = row["commit"]? || raise UserError.new("#{path}: `#{key}` has no commit")
          unless COMMIT.matches?(commit)
            raise UserError.new("#{path}: `#{key}` pins `#{commit}`, which is not a commit hash")
          end
          resolutions[key] = Resolution.new(url, commit)
        end
        resolutions
      end
    rescue error : Coda::Error
      raise UserError.new("#{path}: #{error.message}")
    end

    # Every `deps` and `test-deps` key and the compiler's key have exactly
    # one lock row, and the lock has no other (§2.2). Anything else is
    # refused, not guessed at.
    protected def check_lock(path : Path) : Nil
      keys = all_deps.map(&.key) << COMPILER_KEY
      missing = keys.reject { |k| @resolutions.has_key?(k) }
      extra = @resolutions.keys - keys
      return if missing.empty? && extra.empty?
      problems = [] of String
      problems << "#{LOCK} has no row for #{missing.map { |k| "`#{k}`" }.join(", ")}" unless missing.empty?
      problems << "#{LOCK} has #{extra.map { |k| "`#{k}`" }.join(", ")}, which #{FILE} does not depend on" unless extra.empty?
      raise UserError.new("#{@root}: the two files disagree: #{problems.join("; ")}")
    end

    # The manifest with *dep* locked to *resolution*: in place of the
    # dependency with its key, or after the others of its block when there
    # is none.
    def with_dependency(dep : Dependency, resolution : Resolution) : Manifest
      resolutions = @resolutions.dup
      resolutions[dep.key] = resolution
      deps, test_deps = @deps, @test_deps
      if dep.test
        test_deps = test_deps.any? { |d| d.key == dep.key } ? test_deps.map { |d| d.key == dep.key ? dep : d } : test_deps + [dep]
      else
        deps = deps.any? { |d| d.key == dep.key } ? deps.map { |d| d.key == dep.key ? dep : d } : deps + [dep]
      end
      Manifest.new(@root, @zane_version, @version_pattern, deps, test_deps, @remaps, resolutions,
        @fixed_region, @spawned_fixed_region)
    end

    # The manifest built by the compiler release *tag*, its lock row pinning
    # *commit* (§14).
    def with_compiler(tag : String, commit : String) : Manifest
      resolutions = @resolutions.dup
      resolutions[COMPILER_KEY] = Resolution.new(CompilerRelease::URL, commit)
      Manifest.new(@root, tag, @version_pattern, @deps, @test_deps, @remaps, resolutions,
        @fixed_region, @spawned_fixed_region)
    end

    # Every dependency: the `deps` rows, then the `test-deps` rows.
    def all_deps : Array(Dependency)
      @deps + @test_deps
    end

    # The dependency *key*, in either block.
    def dependency?(key : String) : Dependency?
      all_deps.find { |d| d.key == key }
    end
  end
end
