require "file_utils"
require "./archive"
require "./coda"
require "./compiler"
require "./errors"
require "./git"
require "./home"
require "./package_url"
require "./progress"

module Zane
  # One version of one package in the package cache (spec dependencies.md §7):
  #
  # ```text
  # <packages>/<normalized url>/<tag>/
  #   src/                      the checkout of the pinned commit
  #   artifacts/<target>/
  #     archive.tar.gz          the release archive, verified
  #     build/                  its objects, as published
  #   build/<target>/           those objects, rewritten
  #   build/<target>.coda       what they were rewritten from, and with
  #   build-from-source/<target>/package.o
  #                             the object compiled from src/ (§12.1), and
  #                             what the compiler writes beside it: the
  #                             objects of its C holding assembly and the
  #                             file of its C modules' hashes
  #   build-from-source/<target>.coda
  #                             what it was compiled from, and with
  # ```
  #
  # Each part is made beside where it goes and renamed into place once it is
  # whole, so one that exists is complete.
  class CacheEntry
    # Where the artifact manifest lies in a library's checkout (§3.1).
    ARTIFACTS = "zane-artifacts.coda"

    # A hash in the artifact manifest: 64 lowercase hex digits.
    HASH = /\A[0-9a-f]{64}\z/

    getter url : PackageUrl
    getter tag : String
    getter dir : Path

    def initialize(@url : PackageUrl, @tag : String, packages : Path = Home.packages)
      if error = PackageUrl.tag_error(@tag)
        raise UserError.new("#{@url}: #{error}")
      end
      @dir = packages.join(@url.normalized.split('/')) / @tag
    end

    # How the progress display names the version: the last part of its URL
    # and its tag, such as `json v1.2`.
    def name : String
      "#{@url.basename} #{@tag}"
    end

    # The checkout of *commit*, which *tag* must point to. It is fetched when
    # the cache has none, or has another commit for the tag; a checkout already
    # at *commit* is used as it is, without going online, since the commit is
    # what fixes its content.
    def source(commit : String) : Path
      src = @dir / "src"
      if Dir.exists?(src)
        head = Git.head(src)
        return src if head.starts_with?(commit) || commit.starts_with?(head)
        FileUtils.rm_rf(src)
      end
      progress = Progress.current
      progress.step("Fetching #{name} from #{@url}")
      begin
        Git.checkout(@url.url, @tag, commit, src)
      rescue error
        # Marked here, since a caller may recover and carry on.
        progress.fail
        raise error
      end
      progress.done("Fetched #{name} from #{@url} (commit #{commit[0, 12]})")
      src
    end

    # The release archive's URL and hash for *target*, from the artifact
    # manifest in the checkout *src* (§3.1).
    def artifact(src : Path, target : String) : {String, String}
      path = src / ARTIFACTS
      unless File.file?(path)
        raise UserError.new("#{@url} #{@tag} publishes no prebuilt objects: it has no #{ARTIFACTS}. " \
                            "To compile it here, set its `from` to `source`")
      end
      Coda::Doc.parse_file(path) do |doc|
        table = doc.root["artifacts"]?.try(&.as?(Coda::Table))
        unless table && {"target", "url", "sha256"}.all? { |c| table.columns.includes?(c) }
          raise UserError.new("#{path}: `artifacts` is a table of `target`, `url` and `sha256`")
        end
        found = nil
        triples = [] of String
        table.each do |row|
          triple, url, sha = row["target"]? || "", row["url"]? || "", row["sha256"]? || ""
          raise UserError.new("#{path}: `#{triple}` is not a single path component") unless PackageUrl.safe?(triple)
          raise UserError.new("#{path}: `#{triple}` is listed twice") if triples.includes?(triple)
          raise UserError.new("#{path}: the URL for `#{triple}` is not HTTPS") unless url.starts_with?("https://")
          raise UserError.new("#{path}: the hash for `#{triple}` is not 64 lowercase hex digits") unless HASH.matches?(sha)
          triples << triple
          found = {url, sha} if triple == target
        end
        found || raise NoTarget.new(
          "#{@url} #{@tag} has no prebuilt objects for #{target}; its #{ARTIFACTS} lists " \
          "#{triples.empty? ? "none" : triples.join(", ")}. To compile it here, set its `from` to `source`")
      end
    rescue error : Coda::Error
      raise UserError.new("#{path}: #{error.message}")
    end

    # A valid artifact manifest that lists no objects for the target asked
    # for, as distinct from one that is malformed.
    class NoTarget < UserError
    end

    # The rewritten objects for *target*, which a program links, and whether
    # the cache already held them. They are rewritten by *compiler* with the
    # package's stamp. The cache reuses them only while they were made from
    # the same commit and archive by the same compiler pin, *toolchain*: its
    # tag and commit (§7).
    def objects(commit : String, target : String, compiler : Compiler, toolchain : {String, String}) : {Array(Path), Bool}
      src = source(commit)
      url, sha256 = artifact(src, target)
      built = @dir / "build" / target
      record = @dir / "build" / "#{target}.coda"
      wanted = {"commit" => commit, "target" => target, "sha256" => sha256,
                "zane-version" => toolchain[0], "zane-commit" => toolchain[1]}
      return {files(built), true} if Dir.exists?(built) && read_record(record) == wanted

      originals = unpacked(target, url, sha256)
      rewrite(originals, built, compiler)
      write_record(record, wanted)
      {files(built), false}
    end

    # The object compiled from the checkout of *commit* for *target*, for a
    # dependency compiled from source (§12.1), with what the compiler wrote
    # beside it. It is kept apart from the release's objects, and reused
    # only while it was compiled from the same commit by the same compiler
    # pin, *toolchain*. The block compiles it to the path it is given. The
    # second value says whether the cache already held it.
    def compiled(commit : String, target : String, toolchain : {String, String}, & : Path ->) : {Array(Path), Bool}
      dir = @dir / "build-from-source"
      built = dir / target
      object = built / "package.o"
      record = dir / "#{target}.coda"
      wanted = {"commit" => commit, "target" => target,
                "zane-version" => toolchain[0], "zane-commit" => toolchain[1]}
      return {files(built), true} if File.file?(object) && read_record(record) == wanted

      source(commit)
      Dir.mkdir_p(dir)
      partial = dir / ".#{target}.#{Random::Secure.hex(4)}"
      Dir.mkdir(partial)
      progress = Progress.current
      progress.step("Compiling #{name} from source for #{target}")
      yield partial / object.basename
      progress.done("Compiled #{name} from source for #{target}")
      FileUtils.rm_rf(built)
      File.rename(partial, built)
      write_record(record, wanted)
      {files(built), false}
    ensure
      FileUtils.rm_rf(partial) if partial && Dir.exists?(partial)
    end

    # The verified archive's objects, as published. An archive kept from
    # before is checked again rather than downloaded.
    private def unpacked(target : String, url : String, sha256 : String) : Path
      dir = @dir / "artifacts" / target
      archive = dir / "archive.tar.gz"
      originals = dir / "build"
      progress = Progress.current
      if File.file?(archive) && Dir.exists?(originals)
        # The counters are read by the thread that draws the progress.
        hashed = Atomic(Int64).new(0)
        progress.step("Checking the kept archive of #{name}", File.size(archive)) { hashed.get }
        kept = SHA256.file(archive, ->(n : Int32) { hashed.add(n.to_i64); nil }) == sha256
        progress.done(kept ? "Kept archive of #{name} matches its SHA-256" : "Kept archive of #{name} has changed; fetching it again", amount: false)
        return originals if kept
      end
      FileUtils.rm_rf(dir)
      Archive.fetch(url, sha256, archive, "#{name} objects for #{target}")
      unpacked = Atomic(Int64).new(0)
      progress.step("Unpacking #{name}", File.size(archive)) { unpacked.get }
      files = Archive.extract(archive, dir / "unpacked", read: ->(n : Int32) { unpacked.add(n.to_i64); nil })
      progress.done("Unpacked #{name} (#{files} #{files == 1 ? "file" : "files"})", amount: false)
      File.rename(dir / "unpacked" / "build", originals)
      Dir.delete(dir / "unpacked")
      originals
    end

    # Rewrites every file under *originals* into the same place under
    # *built*: the objects, and the file of their C modules' hashes, whose
    # packages the compiler stamps as it stamps the objects (compiler
    # docs/design/ffi.md F15).
    private def rewrite(originals : Path, built : Path, compiler : Compiler) : Nil
      partial = built.parent / ".#{built.basename}.#{Random::Secure.hex(4)}"
      stamp = @url.stamp(@tag)
      originals_files = files(originals)
      rewritten = Atomic(Int64).new(0)
      progress = Progress.current
      progress.step("Rewriting #{name}'s objects", originals_files.size.to_i64, "files") { rewritten.get }
      originals_files.each do |original|
        output = partial.join(original.relative_to(originals).parts)
        Dir.mkdir_p(output.parent)
        error = IO::Memory.new
        status = compiler.run(["--rewrite", stamp, original.to_s, output.to_s], error, error)
        unless status == 0
          raise UserError.new("the compiler could not rewrite #{original}:\n#{error.to_s.strip}")
        end
        rewritten.add(1)
      end
      progress.done("Rewrote #{name}'s objects with its stamp")
      FileUtils.rm_rf(built)
      File.rename(partial, built)
    ensure
      FileUtils.rm_rf(partial) if partial && Dir.exists?(partial)
    end

    private def read_record(path : Path) : Hash(String, String)?
      return nil unless File.file?(path)
      Coda::Doc.parse_file(path) do |doc|
        doc.root.to_h { |key, node| {key, node.as?(Coda::StringNode).try(&.value) || ""} }
      end
    rescue Coda::Error
      nil
    end

    private def write_record(path : Path, fields : Hash(String, String)) : Nil
      Coda::Doc.new do |doc|
        fields.each { |key, value| doc.root[key] = value }
        partial = path.parent / ".#{path.basename}.#{Random::Secure.hex(4)}"
        File.write(partial, doc.serialize("    "))
        File.rename(partial, path)
      end
    end

    # Every regular file under *dir*, in a stable order.
    private def files(dir : Path) : Array(Path)
      found = [] of Path
      Dir.each_child(dir) do |entry|
        path = dir / entry
        info = File.info(path, follow_symlinks: false)
        if info.directory?
          found.concat(files(path))
        elsif info.file?
          found << path
        end
      end
      found.sort!
    end
  end
end
