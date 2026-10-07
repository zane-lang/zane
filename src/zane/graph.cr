require "file_utils"
require "./cache"
require "./compiler"
require "./errors"
require "./home"
require "./layout"
require "./manifest"
require "./package_url"
require "./remap"
require "./target"
require "./workspace"

module Zane
  # Every package a project depends on, directly or not, read from the
  # manifests of the pinned commits (spec dependencies.md §9, §13). Each
  # version of a package is a package of its own, so versions are linked side
  # by side (§11) unless the project remaps them onto one (§15).
  class Graph
    # Where a package's code comes from (§2.1). Only the project's own
    # manifest chooses; every package reached only through another is
    # `Release`.
    enum From
      Release
      Source
      Path
    end

    # One version of one package, a project whose library packages are
    # linked. *key* is the key it was first reached by, and *entry* its
    # place in the cache, which a path dependency has none of.
    record Package, key : String, url : PackageUrl, tag : String, commit : String,
      from : From, manifest : Manifest, entry : CacheEntry?, layout : Layout do
      # What its symbols carry in place of the placeholder (§6.1).
      def stamp : String
        url.stamp(tag)
      end

      # What the compiler knows one of its library packages by: the stamp,
      # then the package's path (compiler docs/design/separate-compilation.md
      # C10).
      def id(library : Layout::Lib) : String
        "#{stamp}#{library.path}"
      end

      # The version of the package it is: its URL and tag.
      def node : String
        Graph.node(url, tag)
      end
    end

    # A dependency as a package's manifest records it: the key it imports
    # the package by, and the version it pins.
    record Edge, key : String, package : Package

    def self.node(url : PackageUrl, tag : String) : String
      "#{url.normalized} #{tag}"
    end

    # Where the project's `test-deps` edges are kept, beside its own
    # dependencies under "".
    TEST_EDGES = "#test"

    # Every version the manifests pin, each after every package it depends
    # on.
    getter packages = [] of Package

    # The URLs in the project's `remaps` that name no package of the graph,
    # which are likely stale (§2.1).
    getter stale_remaps = [] of String

    # Informational notes from resolving the graph, such as versions whose
    # patterns differ and so are not all collapsed (§15.4).
    getter notes = [] of String

    @nodes = {} of String => Package
    # Which URL each identity hash belongs to, so two never share one (§6.1).
    @hashes = {} of String => String
    # What each version depends on, as its manifest pins it; the project's
    # own dependencies are under "".
    @edges = {} of String => Array(Edge)
    # The project's own dependencies, which choose where their code comes
    # from (§2.1), by version.
    @top = {} of String => Dependency
    # Each version remapping displaced, and the version chosen in its place.
    @chosen = {} of String => Package

    # Reads the graph of *workspace*, whose packages *layout* lays out.
    # *packages* is the cache. When *test*, it is the graph of a test build,
    # which the project's `test-deps` join (spec dependencies.md §13); a
    # dependency's own `test-deps` never do.
    def initialize(@workspace : Workspace, @layout : Layout, @packages_dir : Path = Home.packages, @test : Bool = false)
      manifest = @workspace.manifest
      top = @test ? manifest.all_deps : manifest.deps
      top.each do |dep|
        @top[Graph.node(PackageUrl.parse(manifest.resolutions[dep.key].url), dep.version)] = dep
      end
      visit(manifest, "", [] of String, manifest.deps)
      visit(manifest, TEST_EDGES, [] of String, manifest.test_deps) if @test
      check_names
      @stale_remaps = manifest.remaps.reject do |url|
        normalized = PackageUrl.parse(url).normalized
        @packages.any? { |p| p.url.normalized == normalized }
      end
      remap
    end

    # The dependencies the project's manifest pins, in its order.
    def direct : Array(Edge)
      @edges[""]? || [] of Edge
    end

    # The project's `test-deps`, in its order, in the graph of a test build.
    def test_direct : Array(Edge)
      @edges[TEST_EDGES]? || [] of Edge
    end

    # The dependencies *package*'s manifest pins, in its order.
    def dependencies(package : Package) : Array(Edge)
      @edges[package.node]? || [] of Edge
    end

    # The version remapping links in place of *package*, if it displaced it.
    def chosen(package : Package) : Package?
      @chosen[package.node]?
    end

    # *package*, or the version chosen in its place.
    def resolved(package : Package) : Package
      chosen(package) || package
    end

    # Whether some version of the package at *url* is in the graph.
    def package?(url : PackageUrl) : Bool
      @packages.any? { |p| p.url.normalized == url.normalized }
    end

    # The versions a program links: those the project reaches once each
    # displaced version is replaced by its chosen one, each after every
    # package it depends on.
    def linked : Array(Package)
      @linked ||= begin
        order = [] of Package
        link(direct + test_direct, order, Set(String).new)
        order
      end
    end

    private def link(edges : Array(Edge), order : Array(Package), seen : Set(String)) : Nil
      edges.each do |edge|
        package = resolved(edge.package)
        next if seen.includes?(package.node)
        seen << package.node
        link(dependencies(package), order, seen)
        order << package
      end
    end

    @linked : Array(Package)?

    private def visit(manifest : Manifest, parent : String, chain : Array(String),
                      deps : Array(Dependency) = manifest.deps) : Nil
      edges = @edges[parent] = [] of Edge
      deps.each do |dep|
        resolution = manifest.resolutions[dep.key]
        url = PackageUrl.parse(resolution.url)
        if chain.includes?(url.normalized)
          cycle = (chain + [url.normalized]).skip_while { |u| u != url.normalized }
          raise UserError.new("the packages depend on each other in a cycle: #{cycle.join(" -> ")}")
        end
        node = Graph.node(url, dep.version)
        if seen = @nodes[node]?
          unless seen.commit.starts_with?(resolution.commit) || resolution.commit.starts_with?(seen.commit)
            raise UserError.new("#{url} #{dep.version} is pinned to both #{seen.commit} and #{resolution.commit} " \
                                "(by #{manifest.root}); one tag is one commit")
          end
          edges << Edge.new(dep.key, seen)
          next
        end
        top = @top[node]?
        package = load(top || dep, resolution, url, from(top), manifest)
        check(package)
        @nodes[node] = package
        edges << Edge.new(dep.key, package)
        visit(package.manifest, node, chain + [url.normalized])
        @packages << package
      end
    end

    # Where a version's code comes from: the project's choice for one of its
    # own dependencies, and the release for any other (§2.1).
    private def from(top : Dependency?) : From
      if top.nil? || top.release?
        From::Release
      elsif top.source?
        From::Source
      else
        From::Path
      end
    end

    private def load(dep : Dependency, resolution : Resolution, url : PackageUrl, from : From, parent : Manifest) : Package
      if from.path?
        dir = Path[dep.from].expand(@workspace.root)
        unless File.file?(dir / Manifest::FILE)
          raise UserError.new("`#{dep.key}` comes from #{dep.from}, which holds no #{Manifest::FILE}")
        end
        manifest = Manifest.load(dir)
        return Package.new(dep.key, url, dep.version, resolution.commit, from, manifest, nil, Layout.new(dir))
      end
      entry = CacheEntry.new(url, dep.version, @packages_dir)
      source = entry.source(resolution.commit)
      manifest = Manifest.load(source)
      Package.new(dep.key, url, dep.version, resolution.commit, from, manifest, entry, Layout.new(source))
    rescue error : UserError
      raise error if error.message.try(&.starts_with?("security error"))
      raise UserError.new("#{dep.key} (#{resolution.url} #{dep.version}, required by #{parent.root}): #{error.message}")
    end

    # The rules a package must keep to be part of the graph.
    private def check(package : Package) : Nil
      if package.layout.public_libs.empty?
        raise UserError.new("`#{package.key}` (#{package.url}) has no public library package, so a project has nothing to import from it")
      end
      hash = package.url.identity_hash
      if (other = @hashes[hash]?) && other != package.url.normalized
        raise UserError.new("#{other} and #{package.url} have the same identity hash, so their symbols would collide")
      end
      @hashes[hash] = package.url.normalized
    end

    # Collapses the versions of each package the project lists in `remaps`
    # that their patterns say are interchangeable (§15.3).
    private def remap : Nil
      listed = @workspace.manifest.remaps.map { |u| PackageUrl.parse(u).normalized }
      @packages.group_by(&.url.normalized).each do |url, versions|
        next unless listed.includes?(url) && versions.size > 1
        result = Remap.select(versions.map { |p| {p.tag, p.manifest.version_pattern} })
        result.chosen.each do |displaced, chosen|
          @chosen[Graph.node(versions[0].url, displaced)] = versions.find! { |p| p.tag == chosen }
        end
        if divergent = result.divergent
          patterns = divergent.map { |tag, pattern| "#{tag} declares #{pattern}" }.join(", ")
          @notes << "the versions of #{versions[0].url} declare different version-patterns (#{patterns}), " \
                    "so only those that share one are linked as one"
        end
      end
    end

    # Every name a package of one project imports must name one package
    # (dependencies.md §8): its own top-level library and program packages,
    # and the public library packages of its dependencies, and apart from
    # those, those of its `test-deps`. Each project of the graph is held to
    # it, the project itself first.
    private def check_names : Nil
      own = @layout.top_libs.map { |l| {l.name, "lib/#{l.name}/"} } +
            @layout.programs.map { |p| {p.name, "bin/#{p.name}/"} }
      distinct(own, direct, "the project reaches")
      distinct(own + publics(direct), test_direct, "the project's tests reach") if @test
      @packages.each do |p|
        distinct(p.layout.top_libs.map { |l| {l.name, "lib/#{l.name}/ of #{p.url}"} }, dependencies(p), "#{p.url} reaches")
      end
    end

    private def distinct(names : Array({String, String}), edges : Array(Edge), whose : String) : Nil
      seen = {} of String => String
      (names + publics(edges)).each do |name, where|
        if other = seen[name]?
          raise UserError.new("#{whose} two packages named `#{name}`: #{other} and #{where}; " \
                              "the packages a project imports have distinct names")
        end
        seen[name] = where
      end
    end

    private def publics(edges : Array(Edge)) : Array({String, String})
      edges.flat_map do |e|
        e.package.layout.public_libs.map { |l| {l.name, "`#{l.name}` of the dependency `#{e.key}` (#{e.package.url})"} }
      end
    end

    # The compiler's flags for the packages the project depends on: for each
    # version linked, `--package` for each of its library packages, and
    # `--import` for the keys each may import, among its own packages and
    # of its dependencies' public ones (packages.md §4.3). A key that named a
    # displaced version names its chosen one.
    def package_flags : Array(String)
      flags = [] of String
      linked.reverse_each do |p|
        p.layout.libs.each { |l| flags.push("--package", "#{p.id(l)}=#{l.dir}") }
      end
      linked.reverse_each { |p| flags.concat(project_imports(p, dependencies(p), remapped: true)) }
      flags
    end

    # The keys of *package*'s library packages: those of its own project
    # each may import, and the public ones of *edges*.
    private def project_imports(package : Package, edges : Array(Edge), remapped : Bool) : Array(String)
      package.layout.libs.flat_map do |l|
        own = package.layout.keys(l).map { |key, target| {key, package.id(target)} }
        keyed(package.id(l), own + public_keys(edges, remapped))
      end
    end

    # Each public library package of *edges*' packages, by the key it is
    # imported by, its name, and what the compiler knows it by.
    def public_keys(edges : Array(Edge), remapped : Bool = true) : Array({String, String})
      edges.flat_map do |e|
        target = remapped ? resolved(e.package) : e.package
        target.layout.public_libs.map { |l| {l.name, target.id(l)} }
      end
    end

    # `--import` flags giving the package *from* each of *keys*.
    def keyed(from : String, keys : Array({String, String})) : Array(String)
      keys.flat_map { |key, target| ["--import", "#{from}:#{key}=#{target}"] }
    end

    # The objects for *target* that a program links: each release's
    # objects, fetched, verified and rewritten (§13 steps 6 to 8), and each
    # `source` and path dependency compiled on its own with its stamp (§12).
    # When remapping displaced a version, each object's references to it
    # are moved to its chosen one (§15.6).
    def objects(target : String, compiler : Compiler) : Array(Path)
      objects = linked.flat_map do |p|
        entry = p.entry
        case p.from
        in .release?
          entry.not_nil!.objects(p.commit, target, compiler, @workspace.toolchain)
        in .source?
          [entry.not_nil!.compiled(p.commit, target, @workspace.toolchain) { |dest| compile(p, target, compiler, dest) }]
        in .path?
          dest = @workspace.out_dir / "deps" / target / p.url.identity_hash / p.tag / "package.o"
          Dir.mkdir_p(dest.parent)
          compile(p, target, compiler, dest)
          [dest]
        end
      end
      @chosen.empty? ? objects : remapped(objects, target, compiler)
    end

    # Compiles *package*'s library packages on their own into the object
    # *dest*, named with its stamp, against the versions its own manifest
    # pins (compiler docs/design/separate-compilation.md C1, C6).
    private def compile(package : Package, target : String, compiler : Compiler, dest : Path) : Nil
      closure = [] of Package
      gather(package, closure)
      args = ["--kind", "library", "--object", dest.to_s]
      args.push("--target", target) unless target == Target::HOST
      ([package] + closure).each do |p|
        p.layout.libs.each { |l| args.push("--package", "#{p.id(l)}=#{l.dir}") }
      end
      ([package] + closure).each { |p| args.concat(project_imports(p, dependencies(p), remapped: false)) }
      error = IO::Memory.new
      unless compiler.run(args, error, error) == 0
        raise UserError.new("the compiler could not build #{package.key} #{package.tag} (#{package.url}):\n#{error.to_s.strip}")
      end
    end

    # Every version *package* depends on, directly or not, as the manifests
    # pin them.
    private def gather(package : Package, closure : Array(Package)) : Nil
      dependencies(package).each do |e|
        next if closure.includes?(e.package)
        closure << e.package
        gather(e.package, closure)
      end
    end

    # *objects* with every reference to a displaced version moved to its
    # chosen one, written to the project's `out/`, since which versions are
    # displaced is the project's choice.
    private def remapped(objects : Array(Path), target : String, compiler : Compiler) : Array(Path)
      dir = @workspace.out_dir / "remapped" / target
      FileUtils.rm_rf(dir)
      Dir.mkdir_p(dir)
      pairs = @chosen.map { |node, chosen| {@nodes[node].stamp, chosen.stamp} }
      objects.map_with_index do |object, i|
        dest = dir / "#{i}-#{object.basename}"
        input = object
        # Each pass writes a file of its own, so no pass reads what it writes.
        pairs.each_with_index do |(from, to), j|
          output = j == pairs.size - 1 ? dest : dir / ".#{i}-#{j}-#{object.basename}"
          error = IO::Memory.new
          unless compiler.run(["--remap", from, to, input.to_s, output.to_s], error, error) == 0
            raise UserError.new("the compiler could not remap #{object}:\n#{error.to_s.strip}")
          end
          File.delete(input) unless input == object
          input = output
        end
        dest
      end
    end
  end
end
