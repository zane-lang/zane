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

  # One `renames` row of a manifest (spec dependencies.md §2.1): the
  # dependency *dependency*'s package *package* is imported by *name*, or by
  # no package of the project when *name* is `_`.
  record Rename, dependency : String, package : String, name : String do
    def drop? : Bool
      name == Manifest::DROP
    end
  end

  # One `resolutions` row of a lock file (§2.2).
  record Resolution, url : String, commit : String

  # A project's `zane.coda` and `zane-lock.coda`, read together and held to
  # the rules that join them (spec dependencies.md §2).
  class Manifest
    FILE = "zane.coda"
    LOCK = "zane-lock.coda"

    # The lock field that pins the commit `zane-version` resolves to (§2.2).
    COMPILER_COMMIT = "zane-commit"
    RESOLUTIONS     = "resolutions"

    # The key of the `resolutions` row that pinned the compiler in a lock
    # file written before `zane-commit` existed. Such a lock has no
    # `zane-commit` field, which is how it is told apart: it is still read,
    # and rewritten with the field whenever a command edits it.
    LEGACY_COMPILER_KEY = "zane"

    DEPS      = "deps"
    TEST_DEPS = "test-deps"
    RENAMES   = "renames"

    # The columns of a `renames` row, and the name that drops a package.
    RENAME_COLUMNS = ["dependency", "package", "name"]
    DROP           = "_"

    # How much memory the fixed-size regions of nested scopes may take, in
    # the program's own thread of execution and in each spawned call's
    # (spec memory.md §3.7): a whole number of MiB or GiB. Native addresses
    # impose no language-wide cap; the runtime must reserve the range.
    FIXED_REGION         = "fixed-region"
    SPAWNED_FIXED_REGION = "spawned-fixed-region"
    REGION_SIZE          = /\A([0-9]+)(MiB|GiB)\z/

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
    # The names the project's packages import its dependencies' packages
    # by, where they are not the packages' own (§2.1, §8).
    getter renames : Array(Rename)
    getter resolutions : Hash(String, Resolution)
    # The commit the compiler tag `zane-version` must resolve to (§2.2, §14).
    getter zane_commit : String
    # Each in bytes, or nil when the manifest leaves it to the compiler.
    getter fixed_region : Int64?
    getter spawned_fixed_region : Int64?

    def initialize(@root, @zane_version, @version_pattern, @deps, @test_deps, @remaps, @resolutions, @zane_commit,
                   @fixed_region = nil, @spawned_fixed_region = nil, @renames = [] of Rename)
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
      renames = read_renames(doc, path)
      renames.each do |r|
        if error = Manifest.rename_error(r, deps + test_deps)
          raise UserError.new("#{path}: #{error}")
        end
      end
      zane_commit, resolutions = read_lock(root)
      new(root, zane_version, pattern, deps, test_deps, read_remaps(doc, path), resolutions, zane_commit,
        read_region(doc, path, FIXED_REGION), read_region(doc, path, SPAWNED_FIXED_REGION), renames)
    end

    # A region size in bytes, or nil when the field is absent.
    private def self.read_region(doc : Coda::Block, path : Path, key : String) : Int64?
      return nil unless doc.has_key?(key)
      value = field(doc, key, path)
      match = REGION_SIZE.match(value)
      count = match.try(&.[1].to_i64?)
      unless match && count && count > 0
        raise UserError.new("#{path}: `#{key}` is `#{value}`; it is a positive whole number of `MiB` or `GiB`, such as `256MiB`")
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

    private def self.read_renames(doc : Coda::Block, path : Path) : Array(Rename)
      renames = [] of Rename
      node = doc[RENAMES]? || return renames
      table = node.as?(Coda::Table)
      unless table && table.columns == RENAME_COLUMNS
        raise UserError.new("#{path}: `#{RENAMES}` is a table of `dependency`, `package` and `name`")
      end
      table.each do |row|
        rename = Rename.new(row["dependency"], row["package"], row["name"])
        if renames.any? { |r| r.dependency == rename.dependency && r.package == rename.package }
          raise UserError.new("#{path}: `#{RENAMES}` has two rows for the package `#{rename.package}` of `#{rename.dependency}`")
        end
        renames << rename
      end
      renames
    end

    # Why *rename* breaks the rules of a `renames` row that need only the
    # manifest (§2.1), or nil: the package of a dependency it has, under a
    # package name of its own or `_`.
    def self.rename_error(rename : Rename, deps : Array(Dependency)) : String?
      what = "the rename of `#{rename.package}` of `#{rename.dependency}`"
      if deps.none? { |d| d.key == rename.dependency }
        return "#{what} names `#{rename.dependency}`, which is not a dependency of the project"
      end
      unless Project.valid_name?(rename.package)
        return "#{what} names `#{rename.package}`, which is not a package name"
      end
      return nil if rename.drop?
      if !Project.valid_name?(rename.name) || rename.name.starts_with?('_')
        "#{what} gives it `#{rename.name}`, which is not a package name: it is camelCase, and only `_` alone, " \
        "which drops the package, begins with `_`"
      elsif rename.name == Project::TEST_PACKAGE
        "#{what} gives it `#{Project::TEST_PACKAGE}`, the name of every test package"
      elsif rename.name == rename.package
        "#{what} gives it its own name, which changes nothing"
      end
    end

    # The name the project imports *package* of the dependency *key* by:
    # its own, the one a `renames` row gives it, or nil when a row drops it.
    def import_name(key : String, package : String) : String?
      rename = @renames.find { |r| r.dependency == key && r.package == package }
      return package unless rename
      rename.drop? ? nil : rename.name
    end

    # The compiler commit and the dependency rows of the lock file in
    # *root*. A lock without `zane-commit` predates it, and its compiler
    # commit is the `zane` row's.
    private def self.read_lock(root : Path) : {String, Hash(String, Resolution)}
      path = root / LOCK
      raise UserError.new("#{root} holds #{FILE} but no #{LOCK}") unless File.file?(path)
      Coda::Doc.parse_file(path) do |doc|
        node = doc.root[RESOLUTIONS]? || raise UserError.new("#{path} has no `#{RESOLUTIONS}` table")
        table = node.as?(Coda::KeyedTable)
        unless table && table.columns.includes?("url") && table.columns.includes?("commit")
          raise UserError.new("#{path}: `#{RESOLUTIONS}` is a table of `key`, `url` and `commit`")
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
        if doc.root.has_key?(COMPILER_COMMIT)
          commit = doc.root[COMPILER_COMMIT].as?(Coda::StringNode).try(&.value) ||
                   raise UserError.new("#{path}: `#{COMPILER_COMMIT}` is not a single value")
          unless COMMIT.matches?(commit)
            raise UserError.new("#{path}: `#{COMPILER_COMMIT}` is `#{commit}`, which is not a commit hash")
          end
          {commit, resolutions}
        elsif legacy = resolutions.delete(LEGACY_COMPILER_KEY)
          {legacy.commit, resolutions}
        else
          raise UserError.new("#{path} has no `#{COMPILER_COMMIT}` field")
        end
      end
    rescue error : Coda::Error
      raise UserError.new("#{path}: #{error.message}")
    end

    # Every `deps` and `test-deps` key has exactly one lock row, and the
    # lock has no other (§2.2). Anything else is refused, not guessed at.
    protected def check_lock(path : Path) : Nil
      keys = all_deps.map(&.key)
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
      Manifest.new(@root, @zane_version, @version_pattern, deps, test_deps, @remaps, resolutions, @zane_commit,
        @fixed_region, @spawned_fixed_region, @renames)
    end

    # The manifest with *renames* as its `renames` rows.
    def with_renames(renames : Array(Rename)) : Manifest
      Manifest.new(@root, @zane_version, @version_pattern, @deps, @test_deps, @remaps, @resolutions, @zane_commit,
        @fixed_region, @spawned_fixed_region, renames)
    end

    # The manifest built by the compiler release *tag*, its lock pinning
    # *commit* (§14).
    def with_compiler(tag : String, commit : String) : Manifest
      Manifest.new(@root, tag, @version_pattern, @deps, @test_deps, @remaps, @resolutions, commit,
        @fixed_region, @spawned_fixed_region, @renames)
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
