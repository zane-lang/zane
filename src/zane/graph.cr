require "./cache"
require "./compiler"
require "./errors"
require "./home"
require "./manifest"
require "./package_url"
require "./workspace"

module Zane
  # Every package a project depends on, directly or not, read from the
  # manifests of the pinned commits (spec dependencies.md §9, §13).
  class Graph
    # Where a package's code comes from (§2.1). Only the project's own
    # manifest chooses; every package reached through another is `Release`.
    enum From
      Release
      Source
      Path
    end

    # One package of the graph. *entry* is its place in the cache, which a
    # path dependency has none of.
    record Package, key : String, name : String, url : PackageUrl, tag : String, commit : String,
      from : From, manifest : Manifest, entry : CacheEntry? do
      # The directory of its sources, which the compiler reads (§12).
      def sources : Path
        manifest.root / "src"
      end

      # The name its symbols carry in place of the placeholder. Only a
      # prebuilt package is stamped: one compiled from source is compiled
      # with the project.
      def stamp : String?
        from.release? ? url.stamp(tag) : nil
      end
    end

    # The packages, each after every package it depends on.
    getter packages = [] of Package

    @by_url = {} of String => Package
    @by_hash = {} of String => Package

    # Reads the graph of *workspace*. *packages* is the cache.
    def initialize(@workspace : Workspace, @packages_dir : Path = Home.packages)
      visit(@workspace.manifest, [] of String, top: true)
    end

    private def visit(manifest : Manifest, chain : Array(String), top : Bool) : Nil
      manifest.deps.each do |dep|
        resolution = manifest.resolutions[dep.key]
        url = PackageUrl.parse(resolution.url)
        from = if !top || dep.release?
                 From::Release
               elsif dep.source?
                 From::Source
               else
                 From::Path
               end
        if chain.includes?(url.normalized)
          cycle = (chain + [url.normalized]).skip_while { |u| u != url.normalized }
          raise UserError.new("the packages depend on each other in a cycle: #{cycle.join(" -> ")}")
        end
        if seen = @by_url[url.normalized]?
          same(seen, dep, resolution, from, manifest)
          next
        end
        package = load(dep, resolution, url, from, manifest)
        check(package)
        @by_url[url.normalized] = package
        @by_hash[url.identity_hash] = package
        visit(package.manifest, chain + [url.normalized], top: false)
        @packages << package
      end
    end

    private def load(dep : Dependency, resolution : Resolution, url : PackageUrl, from : From, parent : Manifest) : Package
      if from.path?
        dir = Path[dep.from].expand(@workspace.root)
        unless File.file?(dir / Manifest::FILE)
          raise UserError.new("`#{dep.key}` comes from #{dep.from}, which holds no #{Manifest::FILE}")
        end
        return Package.new(dep.key, "", url, dep.version, resolution.commit, from, Manifest.load(dir), nil)
          .tap { |p| named(p) }
      end
      entry = CacheEntry.new(url, dep.version, @packages_dir)
      src = entry.source(resolution.commit)
      named(Package.new(dep.key, "", url, dep.version, resolution.commit, from, Manifest.load(src), entry))
    rescue error : UserError
      raise error if error.message.try(&.starts_with?("security error"))
      raise UserError.new("#{dep.key} (#{resolution.url} #{dep.version}, required by #{parent.root}): #{error.message}")
    end

    private def named(package : Package) : Package
      package.copy_with(name: package.manifest.name)
    end

    # The rules a package must keep to be part of the graph.
    private def check(package : Package) : Nil
      if package.manifest.kind.application?
        raise UserError.new("`#{package.key}` (#{package.url}) is an application, and only a library can be a dependency")
      end
      # The compiler resolves an import by the package's name, not by the key
      # its importer gives it (compiler docs/design/separate-compilation.md §6).
      if package.name != package.key
        raise UserError.new("`#{package.key}` (#{package.url}) is the package `#{package.name}`; " \
                            "until imports resolve through keys, a dependency's key is its package's name")
      end
      if package.name == @workspace.name
        raise UserError.new("`#{package.key}` (#{package.url}) has the project's own name, `#{package.name}`")
      end
      if other = @by_hash[package.url.identity_hash]?
        raise UserError.new("#{other.url} and #{package.url} have the same identity hash, so their symbols would collide")
      end
      if other = @by_url.values.find { |p| p.name == package.name }
        raise UserError.new("#{other.url} and #{package.url} are both packages named `#{package.name}`; " \
                            "a program cannot hold two packages of one name yet")
      end
    end

    # A package reached a second time must be the version it was the first
    # time, from the same place: a program holds one version of each package
    # for now (compiler docs/design/separate-compilation.md §6).
    private def same(seen : Package, dep : Dependency, resolution : Resolution, from : From, manifest : Manifest) : Nil
      if seen.tag != dep.version || seen.commit != resolution.commit
        raise UserError.new("#{seen.url} is needed at both #{seen.tag} and #{dep.version} (by #{manifest.root}); " \
                            "a program cannot hold two versions of one package yet")
      end
      if seen.from != from
        raise UserError.new("#{seen.url} is both compiled from #{seen.from.to_s.downcase} and linked prebuilt; " \
                            "a program holds one copy of each package")
      end
    end

    # The compiler's flags for the packages: `--package` for each and
    # `--stamp` for each prebuilt one, after the project's own `--package`.
    def package_flags : Array(String)
      flags = [] of String
      @packages.reverse_each { |p| flags.push("--package", "#{p.name}=#{p.sources}") }
      @packages.reverse_each do |p|
        if stamp = p.stamp
          flags.push("--stamp", "#{p.name}=#{stamp}")
        end
      end
      flags
    end

    # The prebuilt objects for *target*, fetched, verified and rewritten as
    # they need to be (§13 steps 6 to 8).
    def objects(target : String, compiler : Compiler) : Array(Path)
      @packages.flat_map do |p|
        entry = p.entry
        next [] of Path unless p.from.release? && entry
        entry.objects(p.commit, target, compiler, @workspace.toolchain)
      end
    end
  end
end
