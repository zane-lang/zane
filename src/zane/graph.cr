require "file_utils"
require "./cache"
require "./compiler"
require "./compiler_release"
require "./errors"
require "./home"
require "./layout"
require "./manifest"
require "./package_url"
require "./progress"
require "./sha256"
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
      # The text its symbols carry in place of the `!` placeholder (§6.1).
      def stamp : String
        url.stamp(tag)
      end

      # The name the compiler gives one of its library packages: the stamp,
      # then the package's path (compiler docs/design/separate-compilation.md
      # C10).
      def id(library : Layout::Lib) : String
        "#{stamp}#{library.path}"
      end

      # The URL and tag that identify this version of the package.
      def node : String
        Graph.node(url, tag)
      end
    end

    # A dependency as a package's manifest records it: the key it names the
    # package by, and the version it pins. *owner* is that manifest, whose
    # `renames` rows give the names its packages import the dependency's packages
    # by (spec dependencies.md §2.1, §8).
    record Edge, key : String, package : Package, owner : Manifest do
      # The name *library* of the package is imported by along this edge,
      # or nil when the owner drops it.
      def name(library : String) : String?
        owner.import_name(key, library)
      end

      # The public library packages of *target*, by the name each is
      # imported by along this edge, the dropped packages left out.
      def publics(target : Package = package) : Array({String, Layout::Lib})
        target.layout.public_libs.compact_map { |l| name(l.name).try { |n| {n, l} } }
      end
    end

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
    # Which URL each identity hash belongs to, so no two URLs share an identity hash (§6.1).
    @hashes = {} of String => String
    # What each version depends on, as its manifest pins it; the project's
    # own dependencies are under "".
    @edges = {} of String => Array(Edge)
    # The project's own dependencies, whose `from` fields set where their
    # code comes from (§2.1), by version.
    @top = {} of String => Dependency
    # Each version remapping displaced, and the version chosen in its place.
    @chosen = {} of String => Package
    # The targets whose objects from the cache the progress display named.
    @noted = Set(String).new
    # Each release's prebuilt objects for a target, as `CacheEntry#objects`
    # gave them, nil for one compiled from source instead, by node and
    # target, so they are fetched once and the fallback is noted once.
    @prebuilt = {} of {String, String} => {Array(Path), Bool}?

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
      check_compilers
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

    # True when the graph holds some version of the package at *url*.
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
          check_renames(manifest, dep, seen)
          edges << Edge.new(dep.key, seen, manifest)
          next
        end
        top = @top[node]?
        package = load(top || dep, resolution, url, from(top), manifest)
        check(package)
        check_renames(manifest, dep, package)
        @nodes[node] = package
        edges << Edge.new(dep.key, package, manifest)
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

    # The rules of *manifest*'s `renames` rows for *dep* that need its
    # checkout (§2.1): each names a public library package it ships, and
    # they do not drop every one.
    private def check_renames(manifest : Manifest, dep : Dependency, package : Package) : Nil
      rows = manifest.renames.select { |r| r.dependency == dep.key }
      return if rows.empty?
      publics = package.layout.public_libs.map(&.name)
      where = "#{manifest.root / Manifest::FILE}"
      rows.each do |r|
        next if publics.includes?(r.package)
        raise UserError.new("#{where}: the rename of `#{r.package}` of `#{dep.key}` names a package " \
                            "#{package.url} #{package.tag} does not ship; its public library packages are #{publics.join(", ")}, " \
                            "and `zane rename off #{dep.key} #{r.package}` removes the row")
      end
      if publics.all? { |name| manifest.import_name(dep.key, name).nil? }
        raise UserError.new("#{where}: the `renames` rows drop every package of `#{dep.key}` (#{package.url}), " \
                            "so the project has nothing to import from it; remove the dependency instead")
      end
    end

    # The project's compiler builds every package of the graph, so each
    # package's `zane-version`, the oldest compiler that builds it, must be
    # of the same major and no newer (spec dependencies.md §14).
    private def check_compilers : Nil
      tag = @workspace.zane_version
      major, minor = CompilerRelease.version(tag).not_nil!
      # Each problem, and the minor that would solve it when a newer compiler
      # of the project's major would.
      problems = @packages.compact_map do |p|
        needed = p.manifest.zane_version
        what = "`#{p.key}` (#{p.url} #{p.tag})"
        unless needed
          next({"#{what} has no `zane-version`", nil})
        end
        version = CompilerRelease.version(needed)
        if version.nil?
          {"#{what} names `#{needed}` as its compiler, which is not a compiler release", nil}
        elsif version[0] != major
          {"#{what} is built by compiler major #{version[0]} (#{needed}), and the project by major #{major}", nil}
        elsif version[1] > minor
          {"#{what} needs compiler #{needed} or later", version[1]}
        end
      end
      return if problems.empty?
      fixes = problems.compact_map(&.[1])
      hint = fixes.size == problems.size ? "; `zane toolchain update v#{major}.#{fixes.max}` moves the project to a compiler that builds them" : ""
      raise UserError.new("the project is built by compiler #{tag}, which builds every package it depends on: " \
                          "#{problems.map(&.[0]).join("; ")}. A program is built by one compiler, so every package must share " \
                          "the project compiler's major and need a compiler no newer than it#{hint}")
    end

    # Collapses the versions of each package the project lists in `remaps`
    # whose patterns make them interchangeable (§15.3).
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
      apart(subpackages(@layout.libs), "", direct, "the project reaches")
      apart(subpackages(@layout.tests.select(&.nested?).map { |t| @layout.lib?(t.path).not_nil! }), "", test_direct, "the project's tests reach") if @test
      @packages.each do |p|
        distinct(p.layout.top_libs.map { |l| {l.name, "lib/#{l.name}/ of #{p.url}"} }, dependencies(p), "#{p.url} reaches")
        apart(subpackages(p.layout.libs), " of #{p.url}", dependencies(p), "#{p.url} reaches")
      end
    end

    private def subpackages(libs : Array(Layout::Lib)) : Array(Layout::Lib)
      libs.reject(&.top?)
    end

    # A subpackage's name stays apart from the names its project reaches
    # its dependencies' packages by, since the package that holds it
    # imports both, and in a test build apart from those of the project's
    # `test-deps` when a nested test package, which imports both, tests it
    # (dependencies.md §8). Two subpackages may share a package name.
    private def apart(libs : Array(Layout::Lib), of : String, edges : Array(Edge), whose : String) : Nil
      names = publics(edges).to_h
      libs.each do |l|
        next unless other = names[l.name]?
        raise UserError.new("#{whose} two packages named `#{l.name}`: the subpackage lib/#{l.path.tr(".", "/")}/#{of} and #{other}; " \
                            "a subpackage's name stays apart from the dependencies' packages, so rename its directory, " \
                            "or give the dependency's package another name with `zane rename`")
      end
    end

    private def distinct(names : Array({String, String}), edges : Array(Edge), whose : String) : Nil
      seen = {} of String => String
      (names + publics(edges)).each do |name, where|
        if other = seen[name]?
          raise UserError.new("#{whose} two packages named `#{name}`: #{other} and #{where}; " \
                              "the packages a project imports have distinct names; `zane rename`, or `zane add --rename`, " \
                              "gives a dependency's package another name in the project, or drops it")
        end
        seen[name] = where
      end
    end

    private def publics(edges : Array(Edge)) : Array({String, String})
      edges.flat_map do |e|
        e.publics.map do |name, l|
          renamed = name == l.name ? "" : ", renamed `#{name}`"
          {name, "`#{l.name}` of the dependency `#{e.key}` (#{e.package.url})#{renamed}"}
        end
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
    # each may import, and the public library packages of *edges*.
    private def project_imports(package : Package, edges : Array(Edge), remapped : Bool) : Array(String)
      package.layout.libs.flat_map do |l|
        own = package.layout.keys(l).map { |key, target| {key, package.id(target)} }
        keyed(package.id(l), own + public_keys(edges, remapped))
      end
    end

    # Each public library package of *edges*' packages, by the key it is
    # imported by, its name, and the name the compiler knows it by. A remapped
    # edge keeps the packages of the version it pins, each found in the
    # version chosen in its place.
    def public_keys(edges : Array(Edge), remapped : Bool = true) : Array({String, String})
      edges.flat_map do |e|
        target = remapped ? resolved(e.package) : e.package
        e.publics.map do |name, l|
          found = target.layout.public_libs.find { |t| t.name == l.name }
          unless found
            raise UserError.new("#{e.package.url} #{target.tag}, linked in place of #{e.package.tag}, has no public package `#{l.name}`, " \
                                "which #{e.package.tag} has; `zane unremap #{e.package.url}` links each version as it is")
          end
          {name, target.id(found)}
        end
      end
    end

    # `--import` flags giving the package *from* each of *keys*.
    def keyed(from : String, keys : Array({String, String})) : Array(String)
      keys.flat_map { |key, target| ["--import", "#{from}:#{key}=#{target}"] }
    end

    # The name the compiler gives the file of an object's C modules'
    # hashes (compiler docs/design/ffi.md F15).
    HASHES = ".c.hashes"

    # Whether *file* is a file of C module hashes, not an object.
    def self.hashes?(file : Path) : Bool
      file.basename.ends_with?(HASHES)
    end

    # Whether `objects` compiles a dependency for the program it links into,
    # for *target*: one comes from source or a path, or is a release whose
    # prebuilt objects read the build's arguments, and no remapping moves
    # what its object names.
    def compiled_for_program?(target : String, compiler : Compiler) : Bool
      @chosen.empty? && linked.any? { |p| !p.from.release? || prebuilt(p, target, compiler).nil? }
    end

    # *package*'s prebuilt objects for *target*, fetched once, or nil when
    # they read the arguments of the build that made them, which the
    # progress display notes once.
    private def prebuilt(package : Package, target : String, compiler : Compiler) : {Array(Path), Bool}?
      @prebuilt.fetch({package.node, target}) do
        found = package.entry.not_nil!.objects(package.commit, target, compiler, @workspace.toolchain)
        unless found
          Progress.current.note("#{package.key} #{package.tag}'s prebuilt objects for #{target} read the arguments of the build that made them, so it is compiled from source")
        end
        @prebuilt[{package.node, target}] = found
      end
    end

    # The compiler's flags for *target*'s objects: `--link` for each, and,
    # when *hashes*, `--c-hashes` for each file of C module hashes beside
    # them, which only an optimized build reads (F13). *write_backs* and
    # *arguments* are what `objects` takes.
    def link_flags(target : String, compiler : Compiler, hashes : Bool, write_backs : Path? = nil,
                   arguments : Array(String) = [] of String) : Array(String)
      objects(target, compiler, write_backs, arguments).flat_map do |o|
        if Graph.hashes?(o)
          hashes ? ["--c-hashes", o.to_s] : [] of String
        else
          ["--link", o.to_s]
        end
      end
    end

    # The objects for *target* that a program links: each release's
    # objects, fetched, verified and rewritten (§13 steps 6 to 8), and each
    # `source` and path dependency compiled on its own with its stamp (§12).
    # When remapping displaced a version, each object's references to it
    # are moved to its chosen one (§15.6). Beside a package's objects is
    # the file of its C modules' hashes, when its C has any, which the
    # compiler compares before it inlines the package's C (compiler
    # docs/design/ffi.md F13, F15); it carries no symbols to remap. Beside
    # it may be the compiler's marker that the package's `comptime` calls
    # read the build's arguments, which the cache keys on and which is
    # neither linked nor remapped.
    #
    # A dependency compiled for one program, *write_backs* naming the file
    # of the places it writes back into, reads every other place plainly
    # rather than as a snapshot (compiler docs/design/lowering.md §9,
    # "Snapshots"); its object is cached by that file's hash. Without one,
    # or while remapping moves what an object names, which those places do
    # not follow, it is compiled for any program.
    #
    # Each dependency is compiled with the build's *arguments*, the values
    # of `--build-argument`, since an exported lambda has the rights of
    # root-package code wherever it is declared (spec packages.md §6.1,
    # §8.4), and its `comptime` calls may read them. A cached object whose
    # calls read them is reused only for the same arguments, and a release
    # whose prebuilt objects read them, which are the publisher's, is
    # compiled from source instead. The compiler's marker of such a read is
    # not among the objects returned.
    #
    # The progress display shows each step that does work, and the versions
    # whose objects the cache already held, prebuilt or compiled, in one line.
    def objects(target : String, compiler : Compiler, write_backs : Path? = nil,
                arguments : Array(String) = [] of String) : Array(Path)
      progress = Progress.current
      cached = [] of Package
      write_backs = nil unless @chosen.empty?
      places = write_backs.try { |f| SHA256.hexdigest(File.read(f)) }
      objects = linked.flat_map do |p|
        entry = p.entry
        case p.from
        in .release?
          if found = prebuilt(p, target, compiler)
            files, hit = found
          else
            files, hit = from_source(p, target, compiler, places, write_backs, arguments)
          end
          cached << p if hit
          files
        in .source?
          files, hit = from_source(p, target, compiler, places, write_backs, arguments)
          cached << p if hit
          files
        in .path?
          dest = @workspace.out_dir / "deps" / target / p.url.identity_hash / p.tag / "package.o"
          # The directory holds only this build's files, which are all
          # linked but the marker of a read of the build's arguments.
          FileUtils.rm_rf(dest.parent)
          Dir.mkdir_p(dest.parent)
          progress.step("Compiling #{p.key} from #{p.layout.root} for #{target}")
          compile(p, target, compiler, dest, write_backs, arguments)
          progress.done("Compiled #{p.key} from #{p.layout.root} for #{target}")
          Dir.children(dest.parent).sort.map { |n| dest.parent / n }.select { |f| File.file?(f) }
        end
      end
      # A command that builds several packages, such as `test`, notes the cached versions only once.
      if !cached.empty? && @noted.add?(target)
        progress.note(Graph.from_cache(cached.map { |p| {p.key, p.tag} }, target))
      end
      objects.reject! { |f| CacheEntry.arguments?(f) }
      @chosen.empty? ? objects : remapped(objects, target, compiler)
    end

    # *package*'s object compiled from its checkout, optimized, and whether
    # the cache already held it.
    private def from_source(package : Package, target : String, compiler : Compiler, places : String?,
                            write_backs : Path?, arguments : Array(String)) : {Array(Path), Bool}
      package.entry.not_nil!.compiled(package.commit, target, @workspace.toolchain, places, arguments) do |dest|
        compile(package, target, compiler, dest, write_backs, arguments, optimize: true)
      end
    end

    # The line that names the versions whose objects for *target* came from
    # the cache: up to three by key and tag, then how many more.
    def self.from_cache(packages : Array({String, String}), target : String) : String
      shown = packages.first(3).map { |key, tag| "#{key} #{tag}" }
      shown << "#{packages.size - 3} more" if packages.size > 3
      objects = packages.size == 1 ? "1 dependency's objects" : "#{packages.size} dependencies' objects"
      "#{objects} for #{target} from the cache: #{shown.join(", ")}"
    end

    # Compiles *package*'s library packages on their own into the object
    # *dest*, named with its stamp, against the versions its own manifest
    # pins (compiler docs/design/separate-compilation.md C1, C6), for the
    # program that writes back into the places of *write_backs*, when given,
    # and started with the build's *arguments*.
    # With *optimize*, as for a `source` dependency, whose object the cache
    # keeps, the object is optimized: the code a program runs wherever it
    # calls the dependency without inlining it. A path dependency, compiled
    # again on every build, is not, so a build stays quick while it changes.
    private def compile(package : Package, target : String, compiler : Compiler, dest : Path, write_backs : Path?,
                        arguments : Array(String), optimize : Bool = false) : Nil
      closure = [] of Package
      gather(package, closure)
      args = compiler.root_flags(false) + ["--object", dest.to_s]
      arguments.each { |a| args.push("--build-argument", a) }
      args << "--optimize" if optimize
      args.push("--program-write-backs", write_backs.to_s) if write_backs
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
      progress = Progress.current
      done = Atomic(Int64).new(0)
      progress.step("Remapping displaced versions in the objects", objects.size.to_i64, "files") { done.get }
      result = objects.map_with_index do |object, i|
        done.add(1)
        next object if Graph.hashes?(object)
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
      progress.done("Remapped #{@chosen.size} displaced #{@chosen.size == 1 ? "version" : "versions"} in the objects")
      result
    end
  end
end
